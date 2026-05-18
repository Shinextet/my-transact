-- ============================================================
-- FINANCIAL TRANSACTION MANAGEMENT SYSTEM
-- Supabase PostgreSQL Schema + RLS Policies
-- ============================================================

-- STEP 1: Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- TABLE: users_profile
-- Stores extended user data beyond Supabase Auth
-- ============================================================
CREATE TABLE public.users_profile (
    id            UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    username      TEXT NOT NULL UNIQUE,
    role          TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('admin', 'user')),
    device_token  TEXT,                          -- stores current active device identifier
    device_id     TEXT,                          -- unique hardware/browser fingerprint
    last_login_at TIMESTAMPTZ,
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for fast username lookups (duplicate prevention)
CREATE UNIQUE INDEX idx_users_profile_username ON public.users_profile (LOWER(username));

-- ============================================================
-- TABLE: transactions
-- ============================================================
CREATE TABLE public.transactions (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id             UUID NOT NULL REFERENCES public.users_profile(id) ON DELETE CASCADE,
    receiver_phone      TEXT NOT NULL,
    payment_method      TEXT NOT NULL CHECK (payment_method IN ('KBZPay','CBPay','WavePay','AYAPay','OKDollar','MPitesan')),
    principal_amount    NUMERIC(15,2) NOT NULL CHECK (principal_amount > 0),
    fee_percentage      NUMERIC(5,4) NOT NULL CHECK (fee_percentage >= 0),
    service_fee_profit  NUMERIC(15,2) GENERATED ALWAYS AS (ROUND(principal_amount * fee_percentage / 100, 2)) STORED,
    total_payable       NUMERIC(15,2) GENERATED ALWAYS AS (ROUND(principal_amount + (principal_amount * fee_percentage / 100), 2)) STORED,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    notes               TEXT
);

-- Indexes for dashboard queries
CREATE INDEX idx_transactions_user_id        ON public.transactions (user_id);
CREATE INDEX idx_transactions_created_at     ON public.transactions (created_at);
CREATE INDEX idx_transactions_user_date      ON public.transactions (user_id, created_at DESC);
CREATE INDEX idx_transactions_payment_method ON public.transactions (user_id, payment_method);

-- ============================================================
-- ROW LEVEL SECURITY (RLS)
-- Critical for multi-tenant data isolation
-- ============================================================

ALTER TABLE public.users_profile  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transactions    ENABLE ROW LEVEL SECURITY;

-- ---- users_profile policies ----

-- Users can only read their own profile
CREATE POLICY "users_profile: user reads own"
    ON public.users_profile FOR SELECT
    USING (auth.uid() = id);

-- Users can update their own profile (for device_token updates)
CREATE POLICY "users_profile: user updates own"
    ON public.users_profile FOR UPDATE
    USING (auth.uid() = id);

-- Admin can read all profiles (uses service role in admin panel)
-- (Admin operations bypass RLS via service_role key — never expose this on client)

-- ---- transactions policies ----

-- Users can only SELECT their own transactions
CREATE POLICY "transactions: user reads own"
    ON public.transactions FOR SELECT
    USING (auth.uid() = user_id);

-- Users can only INSERT for themselves
CREATE POLICY "transactions: user inserts own"
    ON public.transactions FOR INSERT
    WITH CHECK (auth.uid() = user_id);

-- Users can only DELETE their own transactions
CREATE POLICY "transactions: user deletes own"
    ON public.transactions FOR DELETE
    USING (auth.uid() = user_id);

-- No UPDATE allowed (immutable ledger)
-- (Admins use service_role to bypass if needed)

-- ============================================================
-- FUNCTION: updated_at auto-trigger
-- ============================================================
CREATE OR REPLACE FUNCTION public.handle_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER users_profile_updated_at
    BEFORE UPDATE ON public.users_profile
    FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

-- ============================================================
-- FUNCTION: Admin creates user (called server-side with service_role)
-- Never call this from the client!
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_create_user(
    p_username TEXT,
    p_password TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER  -- runs as DB owner, bypasses RLS
SET search_path = public
AS $$
DECLARE
    new_user_id UUID;
BEGIN
    -- Check duplicate (case-insensitive)
    IF EXISTS (SELECT 1 FROM public.users_profile WHERE LOWER(username) = LOWER(p_username)) THEN
        RAISE EXCEPTION 'USERNAME_EXISTS: Username "%" is already taken.', p_username;
    END IF;

    -- Create auth user via Supabase Admin API (must be called from Edge Function)
    -- This function is a placeholder; actual user creation uses service_role HTTP call
    -- See admin Edge Function below

    RETURN new_user_id;
END;
$$;

-- ============================================================
-- FUNCTION: Device session enforcement
-- Call this on every login to kick other sessions
-- ============================================================
CREATE OR REPLACE FUNCTION public.register_device_session(
    p_user_id    UUID,
    p_device_id  TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    existing_device TEXT;
BEGIN
    SELECT device_id INTO existing_device
    FROM public.users_profile
    WHERE id = p_user_id;

    -- If a different device is already registered, reject
    IF existing_device IS NOT NULL AND existing_device != p_device_id THEN
        RETURN jsonb_build_object('allowed', false, 'reason', 'DEVICE_CONFLICT');
    END IF;

    -- Register this device
    UPDATE public.users_profile
    SET device_id = p_device_id, last_login_at = NOW()
    WHERE id = p_user_id;

    RETURN jsonb_build_object('allowed', true);
END;
$$;

-- ============================================================
-- FUNCTION: Force logout from all devices (Admin use)
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_reset_device(p_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE public.users_profile
    SET device_id = NULL, device_token = NULL
    WHERE id = p_user_id;
END;
$$;

-- ============================================================
-- SEED: Insert first Admin record
-- Run AFTER creating the admin user via Supabase Auth dashboard
-- Replace 'YOUR-ADMIN-AUTH-UUID' with the actual UUID from auth.users
-- ============================================================
-- INSERT INTO public.users_profile (id, username, role)
-- VALUES ('YOUR-ADMIN-AUTH-UUID', 'admin', 'admin');

# TransactPro — Implementation Guide
## Financial Transaction Management System (Myanmar)

---

## 1. ARCHITECTURE RECOMMENDATION

### ✅ Recommended: HTML/CSS/JS + Capacitor

Given your requirements, **Capacitor (Ionic)** wrapping a single HTML/CSS/JS app is the **best fit**:

| Criterion               | Capacitor + HTML | React Native | Flutter |
|-------------------------|------------------|--------------|---------|
| Single codebase → iOS+Android | ✅ | ✅ | ✅ |
| Device ID (hardware fingerprint) | ✅ via native plugin | ✅ | ✅ |
| Supabase JS SDK support | ✅ native | ⚠️ needs RN SDK | ⚠️ needs Dart SDK |
| Web-first (easy maintenance) | ✅ | ❌ | ❌ |
| Push token for session mgmt | ✅ via FCM plugin | ✅ | ✅ |
| Build complexity | Low | Medium | High |
| Team: JS devs already | ✅ | ✅ | ❌ |

**Why not React Native/Flutter?**
- Your logic is simple CRUD + dashboard math — no complex native UI needed.
- Capacitor gives you native device ID, secure storage, and push notifications with plugins.
- The single HTML file in this guide works in browser AND as a Capacitor app with zero changes.

---

## 2. CAPACITOR SETUP (iOS + Android)

```bash
# 1. Create project
npm create vite@latest txpro -- --template vanilla
cd txpro

# 2. Install Capacitor
npm install @capacitor/core @capacitor/cli
npx cap init "TransactPro" "com.txpro.app" --web-dir dist

# 3. Install native platforms
npm install @capacitor/android @capacitor/ios
npx cap add android
npx cap add ios

# 4. Install device ID plugin (for single-session enforcement)
npm install @capacitor/device
npm install @capacitor/preferences  # secure local storage

# 5. Copy app.html → dist/index.html, then:
npx cap sync

# 6. Open in IDE
npx cap open android   # opens Android Studio
npx cap open ios       # opens Xcode
```

### Getting a reliable Device ID (Capacitor)
Replace the `getDeviceId()` function in app.html with:

```javascript
import { Device } from '@capacitor/device';
import { Preferences } from '@capacitor/preferences';

async function getDeviceId() {
  // Try hardware ID first
  try {
    const info = await Device.getId();
    return info.identifier;  // UUID that survives app reinstalls on iOS
  } catch {
    // Fallback: generate and persist
    const { value } = await Preferences.get({ key: 'txpro_device_id' });
    if (value) return value;
    const id = 'dev_' + crypto.randomUUID();
    await Preferences.set({ key: 'txpro_device_id', value: id });
    return id;
  }
}
```

---

## 3. SUPABASE PROJECT SETUP (Step by Step)

### Step 1: Create Project
1. Go to https://supabase.com → New Project
2. Name: `txpro`, select region closest to Myanmar (Singapore)
3. Save the **Project URL** and **anon public key**

### Step 2: Run SQL Schema
1. Go to SQL Editor in Supabase Dashboard
2. Paste contents of `supabase_schema.sql`
3. Click Run

### Step 3: Disable Email Confirmations
Since users don't sign up themselves:
- Authentication → Settings → Email Auth
- Turn OFF "Enable email confirmations"
- Turn OFF "Secure email change"

### Step 4: Deploy Edge Functions
```bash
# Install Supabase CLI
npm install -g supabase

# Login
supabase login

# Link to your project
supabase link --project-ref YOUR_PROJECT_REF

# Deploy the admin function
supabase functions deploy admin-create-user
supabase functions deploy reset-user-password
supabase functions deploy list-users
```

### Step 5: Create First Admin
1. Supabase Dashboard → Authentication → Users → Add User
   - Email: `admin@txapp.internal`
   - Password: (strong password)
   - Auto-confirm: YES
2. Copy the UUID of the created user
3. Run in SQL Editor:
   ```sql
   INSERT INTO public.users_profile (id, username, role)
   VALUES ('PASTE-UUID-HERE', 'admin', 'admin');
   ```

### Step 6: Configure app.html
Replace in the `<script>` section:
```javascript
const SUPABASE_URL  = 'https://YOUR_PROJECT_REF.supabase.co';
const SUPABASE_ANON = 'YOUR_ANON_KEY_HERE';
```

---

## 4. EDGE FUNCTION: list-users
Create `supabase/functions/list-users/index.ts`:

```typescript
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const authHeader = req.headers.get("Authorization")!;
  const supabaseClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } }
  );

  const { data: { user } } = await supabaseClient.auth.getUser();
  if (!user) return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });

  const { data: profile } = await supabaseClient
    .from("users_profile").select("role").eq("id", user.id).single();
  if (profile?.role !== "admin") return new Response(JSON.stringify({ error: "Forbidden" }), { status: 403 });

  const supabaseAdmin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  const { data: users } = await supabaseAdmin
    .from("users_profile").select("id, username, role, device_id, last_login_at, is_active")
    .order("created_at", { ascending: false });

  return new Response(JSON.stringify({ users }), {
    headers: { ...corsHeaders, "Content-Type": "application/json" }
  });
});
```

---

## 5. SECURITY CHECKLIST

- [x] **RLS enabled** on all tables — users can only see their own data
- [x] **Service role key NEVER sent to client** — only used in Edge Functions (server-side)
- [x] **Admin registration only** — no public sign-up endpoint exposed
- [x] **Device lock** — `register_device_session()` rejects logins from different devices
- [x] **Case-insensitive username uniqueness** — `UNIQUE INDEX ON LOWER(username)`
- [x] **No self-password reset** — only Admin Edge Function can reset passwords
- [x] **Immutable ledger** — no UPDATE policy on transactions table
- [x] **Generated columns** — `service_fee_profit` and `total_payable` computed server-side (tamper-proof)

---

## 6. PRODUCTION BUILD (Capacitor)

```bash
# Build web assets
npm run build

# Sync to native projects
npx cap sync

# Android: Release build
cd android
./gradlew assembleRelease
# APK at: android/app/build/outputs/apk/release/app-release.apk

# iOS: Archive in Xcode for App Store
npx cap open ios
# Product → Archive → Distribute App
```

---

## 7. FILE STRUCTURE

```
txpro/
├── dist/
│   └── index.html          ← app.html (rename to index.html)
├── supabase/
│   ├── migrations/
│   │   └── 001_schema.sql  ← supabase_schema.sql
│   └── functions/
│       ├── admin-create-user/index.ts
│       ├── reset-user-password/index.ts
│       └── list-users/index.ts
├── android/                ← generated by Capacitor
├── ios/                    ← generated by Capacitor
├── capacitor.config.json
└── package.json
```

---

## 8. KEY LOGIC SUMMARY

### Single-Session Device Enforcement Flow:
```
Login attempt
    │
    ▼
Supabase Auth signIn (email: username@txapp.internal)
    │
    ▼
Call register_device_session(user_id, device_id)
    │
    ├─ device_id matches / null → allowed = true → proceed
    │
    └─ device_id differs → allowed = false → force sign out + show error
```

### Dashboard Calculations (client-side, real-time):
```
allTransactions (fetched once, updated via Realtime subscription)
    │
    ├─ filter by today (local date) → sum service_fee_profit → Today's Profit
    ├─ filter by this month/year   → sum service_fee_profit → Monthly Total
    ├─ filter by date range        → sum service_fee_profit → Custom Filter
    └─ group by payment_method     → sum per group          → Payment Wallets
```

### Transaction Timestamp:
The `created_at` field is set at the **exact millisecond** the Confirm button is clicked (`new Date().toISOString()`), then stored as UTC in PostgreSQL. All display uses the user's local timezone via `toLocaleString()`.

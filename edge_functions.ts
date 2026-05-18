// ============================================================
// Supabase Edge Function: admin-create-user
// Deploy to: supabase/functions/admin-create-user/index.ts
// ============================================================
// This runs server-side with the service_role key (never on client).
// Call it from the Admin Panel after verifying the admin's JWT.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    // Verify caller is an admin
    const authHeader = req.headers.get("Authorization")!;
    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user: caller } } = await supabaseClient.auth.getUser();
    if (!caller) throw new Error("Unauthorized");

    // Check admin role
    const { data: profile } = await supabaseClient
      .from("users_profile")
      .select("role")
      .eq("id", caller.id)
      .single();

    if (profile?.role !== "admin") throw new Error("Forbidden: Admins only");

    // Parse body
    const { username, password } = await req.json();
    if (!username || !password) throw new Error("username and password required");
    if (password.length < 8) throw new Error("Password must be at least 8 characters");

    // Use service_role to create the auth user
    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Check username uniqueness (case-insensitive)
    const { data: existing } = await supabaseAdmin
      .from("users_profile")
      .select("id")
      .ilike("username", username)
      .single();

    if (existing) throw new Error("USERNAME_EXISTS");

    // Create the auth user (email is synthetic: username@internal.app)
    const { data: newUser, error: createError } = await supabaseAdmin.auth.admin.createUser({
      email: `${username.toLowerCase()}@txapp.internal`,
      password,
      email_confirm: true,
      user_metadata: { username },
    });

    if (createError) throw createError;

    // Insert profile
    await supabaseAdmin.from("users_profile").insert({
      id: newUser.user!.id,
      username: username.trim(),
      role: "user",
    });

    return new Response(
      JSON.stringify({ success: true, userId: newUser.user!.id }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );
  } catch (err) {
    const isKnown = ["USERNAME_EXISTS", "Forbidden", "Unauthorized"].some(
      (s) => (err as Error).message.includes(s)
    );
    return new Response(
      JSON.stringify({ error: (err as Error).message }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: isKnown ? 400 : 500 }
    );
  }
});


// ============================================================
// Edge Function: reset-user-password
// supabase/functions/reset-user-password/index.ts
// ============================================================
// Admin calls this to reset a user's password directly.
// (No self-service reset allowed per requirements)

/*
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

serve(async (req) => {
  try {
    const authHeader = req.headers.get("Authorization")!;
    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user: caller } } = await supabaseClient.auth.getUser();
    const { data: profile } = await supabaseClient
      .from("users_profile").select("role").eq("id", caller!.id).single();
    if (profile?.role !== "admin") throw new Error("Forbidden");

    const { targetUserId, newPassword } = await req.json();

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    await supabaseAdmin.auth.admin.updateUserById(targetUserId, { password: newPassword });
    // Also clear device lock so user can log in fresh
    await supabaseAdmin.from("users_profile")
      .update({ device_id: null }).eq("id", targetUserId);

    return new Response(JSON.stringify({ success: true }), { status: 200 });
  } catch (err) {
    return new Response(JSON.stringify({ error: (err as Error).message }), { status: 400 });
  }
});
*/

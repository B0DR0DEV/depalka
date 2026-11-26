import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const authClient = createClient(SUPABASE_URL, ANON_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: cors });
}
function cleanUsername(value: unknown) {
  return String(value ?? "").trim().toLowerCase();
}
function validCredentials(username: string, password: string) {
  return /^[a-z0-9_]{3,20}$/.test(username) && password.length >= 8 && password.length <= 72;
}
function internalEmail(username: string) {
  // This address is an internal Auth identifier only. No email is collected or sent.
  return username + "@users.depost.invalid";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "method_not_allowed" }, 405);

  try {
    const body = await req.json();
    const action = String(body?.action ?? "");
    const username = cleanUsername(body?.username);
    const password = String(body?.password ?? "");

    if (!validCredentials(username, password)) {
      return reply({ error: "bad_credentials_format" }, 400);
    }

    if (action === "login") {
      const { data: mapping, error: lookupError } = await admin
        .from("depost_auth_usernames")
        .select("user_id")
        .eq("username", username)
        .maybeSingle();
      if (lookupError || !mapping?.user_id) {
        return reply({ error: "invalid_login" }, 401);
      }

      const { data: userData, error: userError } = await admin.auth.admin.getUserById(mapping.user_id);
      const email = userData?.user?.email;
      if (userError || !email) return reply({ error: "invalid_login" }, 401);

      const { data, error } = await authClient.auth.signInWithPassword({ email, password });
      if (error || !data.session) return reply({ error: "invalid_login" }, 401);
      return reply({ session: data.session });
    }

    if (action === "claim") {
      const bearer = req.headers.get("Authorization") ?? "";
      const accessToken = bearer.replace(/^Bearer\s+/i, "");
      if (!accessToken) return reply({ error: "session_required" }, 401);

      const { data: current, error: currentError } = await authClient.auth.getUser(accessToken);
      if (currentError || !current.user) return reply({ error: "session_invalid" }, 401);
      if (!current.user.is_anonymous) return reply({ error: "account_already_linked" }, 409);

      const { data: occupied, error: lookupError } = await admin
        .from("depost_auth_usernames")
        .select("user_id")
        .eq("username", username)
        .maybeSingle();
      if (lookupError) return reply({ error: "server_error" }, 500);
      if (occupied) return reply({ error: "username_taken" }, 409);

      const { error: insertError } = await admin
        .from("depost_auth_usernames")
        .insert({ username, user_id: current.user.id });
      if (insertError) {
        return reply({ error: insertError.code === "23505" ? "username_taken" : "server_error" },
          insertError.code === "23505" ? 409 : 500);
      }

      const { error: updateError } = await admin.auth.admin.updateUserById(current.user.id, {
        email: internalEmail(username),
        password,
        email_confirm: true,
      });
      if (updateError) {
        await admin.from("depost_auth_usernames").delete().eq("user_id", current.user.id);
        return reply({ error: "account_link_failed" }, 500);
      }
      return reply({ ok: true });
    }

    return reply({ error: "unknown_action" }, 400);
  } catch (_error) {
    return reply({ error: "server_error" }, 500);
  }
});

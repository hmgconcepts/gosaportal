// Supabase Edge Function: /functions/v1/ping
// FREE-TIER KEEP-ALIVE (Layer 3) — performs a REAL database write.
//
// IMPORTANT: Supabase's inactivity detector looks at actual DATABASE
// activity. A function that only returns JSON (like the old version of
// this file) does NOT reliably reset the 7-day pause timer. This version
// calls the sc_keep_alive() RPC, which updates a heartbeat row — genuine
// database activity that keeps the project awake.
//
// Deploy once:   supabase functions deploy ping --no-verify-jwt
// Then point UptimeRobot (or any free monitor / Vercel cron) at:
//   https://YOUR-PROJECT.supabase.co/functions/v1/ping
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

serve(async (_req) => {
  let db = "skipped (env not set)";
  try {
    const url = Deno.env.get("SUPABASE_URL");
    const key = Deno.env.get("SUPABASE_ANON_KEY");
    if (url && key) {
      const sb = createClient(url, key);
      const { data, error } = await sb.rpc("sc_keep_alive", { src: "edge-ping" });
      db = error
        ? "rpc error: " + error.message + " (run database/keep-alive.sql)"
        : "heartbeat written at " + data;
    }
  } catch (e) {
    db = "error: " + (e as Error).message;
  }
  return new Response(
    JSON.stringify({
      status: "alive",
      timestamp: new Date().toISOString(),
      database_heartbeat: db,
      message: "Supabase free-tier keep-alive ping",
    }),
    { headers: { "Content-Type": "application/json" } },
  );
});

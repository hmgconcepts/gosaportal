export default async function handler(req, res) {
  // School Connect keep-alive (Layer 7 — Vercel Cron). Safe to call any time.
  const url = process.env.SUPABASE_URL, key = process.env.SUPABASE_ANON_KEY;
  if (!url || !key) return res.status(500).json({ ok: false, error: 'Set SUPABASE_URL and SUPABASE_ANON_KEY in Vercel → Settings → Environment Variables.' });
  try {
    const r = await fetch(url + '/rest/v1/rpc/sc_keep_alive', {
      method: 'POST',
      headers: { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
      body: JSON.stringify({ src: 'vercel-cron' })
    });
    return res.status(200).json({ ok: r.ok, status: r.status, at: new Date().toISOString() });
  } catch (e) {
    return res.status(200).json({ ok: false, error: String(e && e.message || e) });
  }
}

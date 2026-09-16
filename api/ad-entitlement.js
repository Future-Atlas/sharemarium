const SUPABASE_URL = process.env.SUPABASE_URL || "";
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || "";

module.exports = async (req, res) => {
  res.setHeader("Cache-Control", "no-store");

  if (req.method && req.method !== "GET") {
    return res.status(405).json({ error: "method_not_allowed" });
  }

  const authorization = String(req.headers?.authorization || "");
  if (!authorization.startsWith("Bearer ")) {
    return res.status(200).json({ authenticated: false, adFree: false });
  }

  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return res.status(503).json({ error: "supabase_env_missing" });
  }

  try {
    const response = await fetch(
      `${SUPABASE_URL}/rest/v1/rpc/current_user_has_ad_free_access`,
      {
        method: "POST",
        headers: {
          apikey: SUPABASE_ANON_KEY,
          Authorization: authorization,
          "Content-Type": "application/json",
        },
        body: "{}",
      },
    );

    if (!response.ok) {
      return res.status(502).json({ error: "entitlement_lookup_failed" });
    }

    const adFree = (await response.json()) === true;
    return res.status(200).json({ authenticated: true, adFree });
  } catch {
    return res.status(502).json({ error: "entitlement_lookup_failed" });
  }
};

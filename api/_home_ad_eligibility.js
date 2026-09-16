const MIN_SUBSTANTIVE_REVIEW_CHARS = 80;

function normalizedTextLength(value) {
  const normalized = String(value || "").replace(/\s+/g, " ").trim();
  return Array.from(normalized).length;
}

function hasSubstantivePublicReview(rows) {
  if (!Array.isArray(rows)) return false;
  return rows.some(
    (row) =>
      row &&
      row.is_spoiler !== true &&
      normalizedTextLength(row.comment) >= MIN_SUBSTANTIVE_REVIEW_CHARS,
  );
}

async function fetchHomeAdEligibility({ env = process.env, request = fetch } = {}) {
  const supabaseUrl = String(env.SUPABASE_URL || "").trim();
  const anonKey = String(env.SUPABASE_ANON_KEY || "").trim();
  if (!supabaseUrl || !anonKey) {
    return { eligible: false, diagnostic: "missing_env" };
  }

  try {
    const url = new URL("/rest/v1/posts", supabaseUrl);
    url.searchParams.set("select", "id,comment,is_spoiler");
    url.searchParams.set("is_spoiler", "is.false");
    url.searchParams.set("order", "created_at.desc");
    url.searchParams.set("limit", "50");

    const response = await request(url, {
      headers: {
        apikey: anonKey,
        Authorization: `Bearer ${anonKey}`,
      },
    });

    if (!response.ok) {
      return {
        eligible: false,
        diagnostic: `posts_http_${response.status}`,
      };
    }

    const rows = await response.json();
    return {
      eligible: hasSubstantivePublicReview(rows),
      diagnostic: "ok",
    };
  } catch {
    return { eligible: false, diagnostic: "request_failed" };
  }
}

module.exports = {
  MIN_SUBSTANTIVE_REVIEW_CHARS,
  normalizedTextLength,
  hasSubstantivePublicReview,
  fetchHomeAdEligibility,
};

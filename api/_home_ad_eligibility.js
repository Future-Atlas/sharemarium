const MIN_SUBSTANTIVE_REVIEW_CHARS = 120;
const MIN_SUBSTANTIVE_PUBLIC_REVIEWS = 5;
const MIN_DISTINCT_PUBLIC_REVIEW_AUTHORS = 3;

function normalizedTextLength(value) {
  const normalized = String(value || "").replace(/\s+/g, " ").trim();
  return Array.from(normalized).length;
}

function isSubstantivePublicReview(row) {
  return (
    row &&
    row.is_spoiler !== true &&
    normalizedTextLength(row.comment) >= MIN_SUBSTANTIVE_REVIEW_CHARS
  );
}

function evaluatePublisherContent(rows) {
  if (!Array.isArray(rows)) {
    return {
      eligible: false,
      substantiveReviewCount: 0,
      distinctAuthorCount: 0,
    };
  }

  const substantiveRows = rows.filter(isSubstantivePublicReview);
  const authorIds = new Set(
    substantiveRows
      .map((row) => String(row?.profile_id || "").trim())
      .filter(Boolean),
  );

  return {
    eligible:
      substantiveRows.length >= MIN_SUBSTANTIVE_PUBLIC_REVIEWS &&
      authorIds.size >= MIN_DISTINCT_PUBLIC_REVIEW_AUTHORS,
    substantiveReviewCount: substantiveRows.length,
    distinctAuthorCount: authorIds.size,
  };
}

function hasSubstantivePublicReview(rows) {
  return evaluatePublisherContent(rows).eligible;
}

async function fetchHomeAdEligibility({ env = process.env, request = fetch } = {}) {
  const supabaseUrl = String(env.SUPABASE_URL || "").trim();
  const anonKey = String(env.SUPABASE_ANON_KEY || "").trim();
  if (!supabaseUrl || !anonKey) {
    return { eligible: false, diagnostic: "missing_env" };
  }

  try {
    const url = new URL("/rest/v1/posts", supabaseUrl);
    url.searchParams.set("select", "id,profile_id,comment,is_spoiler");
    url.searchParams.set("is_spoiler", "is.false");
    url.searchParams.set("order", "created_at.desc");
    url.searchParams.set("limit", "100");

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
    const evaluation = evaluatePublisherContent(rows);
    return {
      eligible: evaluation.eligible,
      diagnostic: `ok;reviews=${evaluation.substantiveReviewCount};authors=${evaluation.distinctAuthorCount}`,
    };
  } catch {
    return { eligible: false, diagnostic: "request_failed" };
  }
}

module.exports = {
  MIN_SUBSTANTIVE_REVIEW_CHARS,
  MIN_SUBSTANTIVE_PUBLIC_REVIEWS,
  MIN_DISTINCT_PUBLIC_REVIEW_AUTHORS,
  normalizedTextLength,
  isSubstantivePublicReview,
  evaluatePublisherContent,
  hasSubstantivePublicReview,
  fetchHomeAdEligibility,
};

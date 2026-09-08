const SITE_URL = "https://sharemarium.com";
const LASTMOD = process.env.SEO_LASTMOD || "2026-09-02";
const IS_PRODUCTION = process.env.VERCEL_ENV === "production";
const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
const MIN_INDEXABLE_REVIEW_CHARS = 80;

const FIXED_URLS = [
  { path: "/", changefreq: "daily", priority: "1.0", lastmod: LASTMOD },
  { path: "/privacy", changefreq: "monthly", priority: "0.4", lastmod: LASTMOD },
  { path: "/terms", changefreq: "monthly", priority: "0.4", lastmod: LASTMOD },
  {
    path: "/community-guidelines",
    changefreq: "monthly",
    priority: "0.4",
    lastmod: LASTMOD,
  },
  {
    path: "/infringement-policy",
    changefreq: "monthly",
    priority: "0.4",
    lastmod: LASTMOD,
  },
  {
    path: "/external-transmission",
    changefreq: "monthly",
    priority: "0.4",
    lastmod: LASTMOD,
  },
  { path: "/contact", changefreq: "monthly", priority: "0.4", lastmod: LASTMOD },
];

function xmlEscape(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

function toAbsoluteUrl(pathname) {
  const normalized = String(pathname || "/").startsWith("/")
    ? String(pathname || "/")
    : `/${String(pathname || "")}`;
  return `${SITE_URL}${normalized}`;
}

function canonicalProfilePath(profile) {
  const rawId = String(profile?.user_id || profile?.username || "").trim();
  if (!rawId) return null;
  return `/users/${encodeURIComponent(rawId)}`;
}

function hasPublicProfileContent(profile) {
  const bio = String(profile?.bio || "").trim();
  return bio.length > 0 || Number(profile?.read_count || 0) > 0;
}

function isIndexableProfile(profile) {
  return (
    profile &&
    profile.is_private !== true &&
    profile.is_suspended !== true &&
    canonicalProfilePath(profile) !== null &&
    hasPublicProfileContent(profile)
  );
}

function normalizedReviewLength(value) {
  const normalized = String(value || "").replace(/\s+/g, " ").trim();
  return Array.from(normalized).length;
}

function isIndexablePost(post) {
  return (
    post &&
    String(post.id || "").trim().length > 0 &&
    post.is_spoiler !== true &&
    normalizedReviewLength(post.comment) >= MIN_INDEXABLE_REVIEW_CHARS
  );
}

function sitemapUrl({ loc, path, changefreq, priority, lastmod }) {
  const absoluteLoc = loc || toAbsoluteUrl(path);
  const lastmodXml = lastmod
    ? `\n    <lastmod>${xmlEscape(lastmod)}</lastmod>`
    : "";
  return `  <url>\n    <loc>${xmlEscape(absoluteLoc)}</loc>${lastmodXml}\n    <changefreq>${xmlEscape(changefreq)}</changefreq>\n    <priority>${xmlEscape(priority)}</priority>\n  </url>`;
}

async function fetchPublicProfiles() {
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return { profiles: [], diagnostic: "profiles=skipped:missing_env" };
  }

  const url = new URL("/rest/v1/profiles", SUPABASE_URL);
  url.searchParams.set(
    "select",
    "id,username,user_id,bio,read_count,is_private,is_suspended",
  );
  url.searchParams.set("is_private", "is.false");
  url.searchParams.set("is_suspended", "is.false");
  url.searchParams.set("order", "created_at.desc");
  url.searchParams.set("limit", "1000");

  const response = await fetch(url, {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
    },
  });

  if (!response.ok) {
    throw new Error(`profiles_http_${response.status}`);
  }

  const profiles = await response.json();
  return {
    profiles: Array.isArray(profiles) ? profiles : [],
    diagnostic: "profiles=ok",
  };
}

async function fetchPublicPosts() {
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return { posts: [], diagnostic: "posts=skipped:missing_env" };
  }

  const url = new URL("/rest/v1/posts", SUPABASE_URL);
  url.searchParams.set("select", "id,comment,created_at,is_spoiler");
  url.searchParams.set("is_spoiler", "is.false");
  url.searchParams.set("order", "created_at.desc");
  url.searchParams.set("limit", "1000");

  const response = await fetch(url, {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
    },
  });

  if (!response.ok) {
    throw new Error(`posts_http_${response.status}`);
  }

  const posts = await response.json();
  return {
    posts: Array.isArray(posts) ? posts : [],
    diagnostic: "posts=ok",
  };
}

async function dynamicProfileUrls() {
  try {
    const { profiles, diagnostic } = await fetchPublicProfiles();
    return {
      urls: profiles.filter(isIndexableProfile).map((profile) => ({
        path: canonicalProfilePath(profile),
        changefreq: "weekly",
        priority: "0.6",
      })),
      diagnostic,
    };
  } catch (err) {
    const message = err instanceof Error ? err.message.slice(0, 80) : "unknown";
    if (!IS_PRODUCTION) {
      console.error("sitemap profile fetch failed:", message);
    }
    return {
      urls: [],
      diagnostic: IS_PRODUCTION ? "profiles=error" : `profiles=error:${message}`,
    };
  }
}

async function dynamicPostUrls() {
  try {
    const { posts, diagnostic } = await fetchPublicPosts();
    return {
      urls: posts.filter(isIndexablePost).map((post) => ({
        path: `/posts/${encodeURIComponent(String(post.id))}`,
        changefreq: "monthly",
        priority: "0.7",
        lastmod: post.created_at
          ? String(post.created_at).slice(0, 10)
          : undefined,
      })),
      diagnostic,
    };
  } catch (err) {
    const message = err instanceof Error ? err.message.slice(0, 80) : "unknown";
    if (!IS_PRODUCTION) {
      console.error("sitemap post fetch failed:", message);
    }
    return {
      urls: [],
      diagnostic: IS_PRODUCTION ? "posts=error" : `posts=error:${message}`,
    };
  }
}

function dedupeUrls(urls) {
  const byLoc = new Map();
  for (const url of urls) {
    const loc = url.loc || toAbsoluteUrl(url.path);
    if (!byLoc.has(loc)) {
      byLoc.set(loc, { ...url, loc });
    }
  }
  return [...byLoc.values()];
}

module.exports = async (_req, res) => {
  const [profiles, posts] = await Promise.all([
    dynamicProfileUrls(),
    dynamicPostUrls(),
  ]);
  const urls = dedupeUrls([
    ...FIXED_URLS,
    ...profiles.urls,
    ...posts.urls,
  ]).map(sitemapUrl);

  const xml = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.join("\n")}\n</urlset>\n`;

  res.setHeader("Content-Type", "application/xml; charset=utf-8");
  res.setHeader("X-Sitemap-Diagnostics", profiles.diagnostic);
  res.setHeader("X-Sitemap-Post-Diagnostics", posts.diagnostic);
  if (!IS_PRODUCTION) {
    res.setHeader("X-Robots-Tag", "noindex, nofollow");
  }
  res.setHeader("Cache-Control", "s-maxage=3600, stale-while-revalidate");
  return res.status(200).send(xml);
};

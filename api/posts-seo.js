const SITE_URL = "https://sharemarium.com";
const SITE_NAME = "Sharemarium";
const SUPABASE_URL = process.env.SUPABASE_URL || "";
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || "";
const POSTS_LIMIT = 50;

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function normalizeText(value) {
  return String(value ?? "").replace(/\s+/g, " ").trim();
}

function excerpt(value, maxLength = 180) {
  const text = normalizeText(value);
  if (text.length <= maxLength) return text;
  return `${text.slice(0, maxLength - 1)}…`;
}

function formatDate(value) {
  const raw = String(value || "");
  if (!raw) return "";
  const date = new Date(raw);
  if (Number.isNaN(date.getTime())) return raw.slice(0, 10);
  return new Intl.DateTimeFormat("ja-JP", {
    year: "numeric",
    month: "long",
    day: "numeric",
  }).format(date);
}

function postProfile(post) {
  if (Array.isArray(post?.profiles)) return post.profiles[0] || null;
  return post?.profiles || null;
}

function supabaseHeaders() {
  return {
    apikey: SUPABASE_ANON_KEY,
    Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
  };
}

async function fetchPosts() {
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
    throw new Error("supabase_env_missing");
  }

  const url = new URL("/rest/v1/posts", SUPABASE_URL);
  url.searchParams.set(
    "select",
    "id,profile_id,book_id,book_title,rating,comment,created_at,is_spoiler,profiles(username,user_id)",
  );
  url.searchParams.set("order", "created_at.desc");
  url.searchParams.set("limit", String(POSTS_LIMIT));

  const response = await fetch(url, { headers: supabaseHeaders() });
  if (!response.ok) throw new Error(`posts_http_${response.status}`);

  const body = await response.json();
  return Array.isArray(body) ? body : [];
}

async function fetchReplyCounts(postIds) {
  if (postIds.length === 0) return new Map();

  const url = new URL("/rest/v1/post_replies", SUPABASE_URL);
  url.searchParams.set("select", "post_id");
  url.searchParams.set("post_id", `in.(${postIds.join(",")})`);
  url.searchParams.set("limit", "5000");

  const response = await fetch(url, { headers: supabaseHeaders() });
  if (!response.ok) throw new Error(`replies_http_${response.status}`);

  const body = await response.json();
  const counts = new Map();
  if (!Array.isArray(body)) return counts;
  for (const reply of body) {
    const postId = String(reply?.post_id || "");
    if (!postId) continue;
    counts.set(postId, (counts.get(postId) || 0) + 1);
  }
  return counts;
}

function renderUnavailable(res, statusCode, message) {
  res.setHeader("Content-Type", "text/html; charset=utf-8");
  res.setHeader("X-Robots-Tag", "noindex, nofollow");
  res.setHeader("Cache-Control", "no-store");
  return res.status(statusCode).send(`<!doctype html>
<html lang="ja">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex,nofollow">
    <title>投稿一覧 | ${SITE_NAME}</title>
  </head>
  <body>
    <main style="max-width:760px;margin:48px auto;padding:0 20px;font-family:system-ui,-apple-system,sans-serif;line-height:1.7;">
      <h1>投稿一覧</h1>
      <p>${escapeHtml(message)}</p>
      <p><a href="/">Sharemariumへ戻る</a></p>
    </main>
  </body>
</html>`);
}

module.exports = async (_req, res) => {
  let posts;
  let replyCounts = new Map();
  try {
    posts = await fetchPosts();
    replyCounts = await fetchReplyCounts(
      posts.map((post) => String(post.id || "")).filter(Boolean),
    );
  } catch (err) {
    const message = err instanceof Error ? err.message : "unknown";
    const retryAfter = message === "supabase_env_missing" ? "300" : "60";
    res.setHeader("Retry-After", retryAfter);
    return renderUnavailable(
      res,
      503,
      "投稿一覧を取得できませんでした。時間をおいて再度お試しください。",
    );
  }

  const canonical = `${SITE_URL}/posts`;
  const hasPosts = posts.length > 0;
  const listItems = posts.map((post, index) => {
    const profile = postProfile(post);
    const username = normalizeText(profile?.username) || "Sharemariumユーザー";
    const bookTitle =
      normalizeText(post.book_title) || normalizeText(post.book_id) || "本";
    const postId = String(post.id || "");
    const detailUrl = `/posts/${encodeURIComponent(postId)}`;
    const date = formatDate(post.created_at);
    const ratingRaw = Number(post.rating);
    const rating = Number.isFinite(ratingRaw)
      ? Math.min(5, Math.max(0, ratingRaw))
      : null;
    const replyCount = replyCounts.get(postId) || 0;
    const body = post.is_spoiler === true
      ? "ネタバレを含む投稿です。詳細画面で内容を確認できます。"
      : excerpt(post.comment) || "レビュー本文はありません。";
    const profileId = String(profile?.user_id || post.profile_id || "");
    const profileUrl = profileId
      ? `/users/${encodeURIComponent(profileId)}`
      : "/";

    return {
      html: `<article class="post-card">
        <a class="post-link" href="${escapeHtml(detailUrl)}" aria-label="『${escapeHtml(bookTitle)}』のレビュー詳細を開く">
          <div class="post-head">
            <h2>『${escapeHtml(bookTitle)}』</h2>
            ${rating === null ? "" : `<span class="rating">★ ${escapeHtml(rating)} / 5</span>`}
          </div>
          <p class="review">${escapeHtml(body)}</p>
          <div class="meta">
            <span>投稿者: ${escapeHtml(username)}</span>
            ${date ? `<time datetime="${escapeHtml(String(post.created_at || ""))}">${escapeHtml(date)}</time>` : ""}
            <span class="reply-count">${replyCount}件の返信</span>
          </div>
        </a>
        <a class="profile-link" href="${escapeHtml(profileUrl)}">${escapeHtml(username)}さんのプロフィール</a>
      </article>`,
      item: {
        "@type": "ListItem",
        position: index + 1,
        url: `${SITE_URL}${detailUrl}`,
        name: `${bookTitle}のレビュー - ${username}`,
      },
    };
  });

  const jsonLd = {
    "@context": "https://schema.org",
    "@type": "CollectionPage",
    name: "Sharemarium 投稿一覧",
    url: canonical,
    mainEntity: {
      "@type": "ItemList",
      numberOfItems: listItems.length,
      itemListElement: listItems.map((item) => item.item),
    },
  };

  res.setHeader("Content-Type", "text/html; charset=utf-8");
  if (!hasPosts) res.setHeader("X-Robots-Tag", "noindex, follow");
  res.setHeader("Cache-Control", "s-maxage=120, stale-while-revalidate=600");

  return res.status(200).send(`<!doctype html>
<html lang="ja">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>読書レビューの投稿一覧 | ${SITE_NAME}</title>
    <meta name="description" content="Sharemariumに公開された最新の読書レビューを一覧で確認できます。気になる投稿を選ぶとレビュー詳細を読めます。">
    <meta name="robots" content="${hasPosts ? "index,follow" : "noindex,follow"}">
    <link rel="canonical" href="${canonical}">
    <meta property="og:type" content="website">
    <meta property="og:site_name" content="${SITE_NAME}">
    <meta property="og:title" content="読書レビューの投稿一覧 | ${SITE_NAME}">
    <meta property="og:description" content="Sharemariumに公開された最新の読書レビューを一覧で確認できます。">
    <meta property="og:url" content="${canonical}">
    <script type="application/ld+json">${JSON.stringify(jsonLd).replace(/</g, "\\u003c")}</script>
    <style>
      :root { color-scheme: light dark; }
      body { margin: 0; font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; line-height: 1.7; background: Canvas; color: CanvasText; }
      header, main, footer { max-width: 860px; margin: 0 auto; padding-left: 20px; padding-right: 20px; }
      header { padding-top: 24px; padding-bottom: 16px; border-bottom: 1px solid color-mix(in srgb, CanvasText 16%, transparent); }
      header a { color: inherit; font-weight: 800; text-decoration: none; }
      main { padding-top: 28px; padding-bottom: 40px; }
      h1 { margin: 0 0 8px; font-size: clamp(1.7rem, 4vw, 2.35rem); }
      .lead { margin: 0 0 24px; }
      .posts { display: grid; gap: 16px; }
      .post-card { border: 1px solid color-mix(in srgb, CanvasText 16%, transparent); border-radius: 14px; overflow: hidden; }
      .post-link { display: block; padding: 20px; color: inherit; text-decoration: none; }
      .post-link:hover { background: color-mix(in srgb, CanvasText 5%, transparent); }
      .post-head { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 8px 16px; align-items: baseline; }
      .post-head h2 { margin: 0; font-size: 1.15rem; }
      .rating { font-weight: 750; white-space: nowrap; }
      .review { margin: 12px 0; overflow-wrap: anywhere; }
      .meta { display: flex; flex-wrap: wrap; gap: 6px 16px; font-size: 0.9rem; opacity: 0.82; }
      .reply-count { font-weight: 700; }
      .profile-link { display: inline-block; padding: 0 20px 16px; color: inherit; font-size: 0.9rem; }
      .empty { padding: 24px; border: 1px dashed color-mix(in srgb, CanvasText 25%, transparent); border-radius: 12px; }
      footer { padding-top: 20px; padding-bottom: 36px; border-top: 1px solid color-mix(in srgb, CanvasText 16%, transparent); font-size: 0.9rem; }
      footer a { color: inherit; }
    </style>
  </head>
  <body>
    <header><a href="/">Sharemarium</a></header>
    <main>
      <h1>投稿一覧</h1>
      <p class="lead">Sharemariumに公開された最新の読書レビューです。気になる投稿を選ぶと詳細を確認できます。</p>
      <section class="posts" aria-label="公開レビュー一覧">
        ${listItems.length > 0 ? listItems.map((item) => item.html).join("\n") : '<p class="empty">現在、表示できる投稿がありません。</p>'}
      </section>
    </main>
    <footer><a href="/">Sharemariumへ戻る</a></footer>
  </body>
</html>`);
};

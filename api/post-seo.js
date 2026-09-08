const SITE_URL = "https://sharemarium.com";
const SITE_NAME = "Sharemarium";
const SUPABASE_URL = process.env.SUPABASE_URL || "";
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || "";
const MIN_INDEXABLE_REVIEW_CHARS = 80;
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

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

function textLength(value) {
  return Array.from(normalizeText(value)).length;
}

function firstQueryValue(value) {
  if (Array.isArray(value)) return value[0] || "";
  return String(value || "");
}

function canonicalPostUrl(postId) {
  return `${SITE_URL}/posts/${encodeURIComponent(postId)}`;
}

function canonicalProfileUrl(profile, fallbackProfileId) {
  const publicId = String(profile?.user_id || fallbackProfileId || "").trim();
  if (!publicId) return SITE_URL;
  return `${SITE_URL}/users/${encodeURIComponent(publicId)}`;
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

function shortDescription(comment, bookTitle, username) {
  const normalized = normalizeText(comment);
  if (normalized) {
    return normalized.length > 150
      ? `${normalized.slice(0, 147)}...`
      : normalized;
  }
  return `${username}さんによる「${bookTitle}」の読書レビューです。`;
}

function safeJsonLd(value) {
  return JSON.stringify(value).replace(/</g, "\\u003c");
}

function postProfile(post) {
  if (Array.isArray(post?.profiles)) return post.profiles[0] || null;
  return post?.profiles || null;
}

async function fetchPost(postId) {
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
    throw new Error("supabase_env_missing");
  }

  const url = new URL("/rest/v1/posts", SUPABASE_URL);
  url.searchParams.set(
    "select",
    "id,profile_id,book_id,book_title,rating,comment,created_at,is_spoiler,profiles(username,user_id)",
  );
  url.searchParams.set("id", `eq.${postId}`);
  url.searchParams.set("limit", "1");

  const response = await fetch(url, {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
    },
  });

  if (!response.ok) {
    throw new Error(`post_http_${response.status}`);
  }

  const body = await response.json();
  return Array.isArray(body) && body.length > 0 ? body[0] : null;
}

function renderErrorPage({ title, message, statusCode, res }) {
  res.setHeader("Content-Type", "text/html; charset=utf-8");
  res.setHeader("X-Robots-Tag", "noindex, nofollow");
  res.setHeader("Cache-Control", "no-store");
  return res.status(statusCode).send(`<!doctype html>
<html lang="ja">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex,nofollow">
    <title>${escapeHtml(title)} | ${SITE_NAME}</title>
  </head>
  <body>
    <main style="max-width:720px;margin:48px auto;padding:0 20px;font-family:system-ui,-apple-system,sans-serif;line-height:1.7;">
      <h1>${escapeHtml(title)}</h1>
      <p>${escapeHtml(message)}</p>
      <p><a href="/">Sharemariumへ戻る</a></p>
    </main>
  </body>
</html>`);
}

module.exports = async (req, res) => {
  const postId = firstQueryValue(req?.query?.post_id).trim();
  if (!UUID_RE.test(postId)) {
    return renderErrorPage({
      title: "投稿が見つかりません",
      message: "指定された投稿URLが正しくありません。",
      statusCode: 404,
      res,
    });
  }

  let post;
  try {
    post = await fetchPost(postId);
  } catch (err) {
    const message = err instanceof Error ? err.message : "unknown";
    if (message === "supabase_env_missing") {
      res.setHeader("Retry-After", "300");
      return renderErrorPage({
        title: "一時的に表示できません",
        message: "投稿情報の取得準備ができていません。時間をおいて再度お試しください。",
        statusCode: 503,
        res,
      });
    }
    res.setHeader("Retry-After", "60");
    return renderErrorPage({
      title: "一時的に表示できません",
      message: "投稿情報を取得できませんでした。時間をおいて再度お試しください。",
      statusCode: 503,
      res,
    });
  }

  if (!post) {
    return renderErrorPage({
      title: "投稿が見つかりません",
      message: "この投稿は削除されたか、現在公開されていない可能性があります。",
      statusCode: 404,
      res,
    });
  }

  const profile = postProfile(post);
  const username = normalizeText(profile?.username) || "Sharemariumユーザー";
  const bookTitle = normalizeText(post.book_title) || normalizeText(post.book_id) || "本";
  const comment = String(post.comment || "").trim();
  const ratingRaw = Number(post.rating);
  const rating = Number.isFinite(ratingRaw)
    ? Math.min(5, Math.max(0, ratingRaw))
    : null;
  const datePublished = String(post.created_at || "");
  const displayDate = formatDate(datePublished);
  const canonical = canonicalPostUrl(postId);
  const profileUrl = canonicalProfileUrl(profile, post.profile_id);
  const description = shortDescription(comment, bookTitle, username);
  const isIndexable =
    post.is_spoiler !== true && textLength(comment) >= MIN_INDEXABLE_REVIEW_CHARS;
  const robots = isIndexable ? "index,follow" : "noindex,follow";
  const title = `${bookTitle}のレビュー | ${username} | ${SITE_NAME}`;

  const reviewJsonLd = {
    "@context": "https://schema.org",
    "@type": "Review",
    url: canonical,
    datePublished: datePublished || undefined,
    author: {
      "@type": "Person",
      name: username,
      url: profileUrl,
    },
    itemReviewed: {
      "@type": "Book",
      name: bookTitle,
      isbn: normalizeText(post.book_id) || undefined,
    },
    reviewBody: normalizeText(comment),
    reviewRating:
      rating === null
        ? undefined
        : {
            "@type": "Rating",
            ratingValue: rating,
            bestRating: 5,
            worstRating: 0,
          },
  };

  const reviewBody = comment
    ? escapeHtml(comment).replace(/\r?\n/g, "<br>")
    : "レビュー本文はありません。";
  const spoilerNotice = post.is_spoiler === true
    ? '<p class="notice">この投稿にはネタバレが含まれます。</p>'
    : "";
  const ratingHtml = rating === null
    ? ""
    : `<span class="rating" aria-label="5点満点中${escapeHtml(rating)}点">★ ${escapeHtml(rating)} / 5</span>`;

  res.setHeader("Content-Type", "text/html; charset=utf-8");
  if (!isIndexable) {
    res.setHeader("X-Robots-Tag", "noindex, follow");
  }
  res.setHeader("Cache-Control", "s-maxage=300, stale-while-revalidate=3600");

  return res.status(200).send(`<!doctype html>
<html lang="ja">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>${escapeHtml(title)}</title>
    <meta name="description" content="${escapeHtml(description)}">
    <meta name="robots" content="${robots}">
    <link rel="canonical" href="${escapeHtml(canonical)}">
    <meta property="og:type" content="article">
    <meta property="og:site_name" content="${SITE_NAME}">
    <meta property="og:title" content="${escapeHtml(title)}">
    <meta property="og:description" content="${escapeHtml(description)}">
    <meta property="og:url" content="${escapeHtml(canonical)}">
    <meta name="twitter:card" content="summary">
    <script type="application/ld+json">${safeJsonLd(reviewJsonLd)}</script>
    <style>
      :root { color-scheme: light dark; }
      body { margin: 0; font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; line-height: 1.75; background: Canvas; color: CanvasText; }
      header, main, footer { max-width: 760px; margin: 0 auto; padding-left: 20px; padding-right: 20px; }
      header { padding-top: 24px; padding-bottom: 16px; border-bottom: 1px solid color-mix(in srgb, CanvasText 16%, transparent); }
      header a { font-weight: 800; text-decoration: none; color: inherit; }
      main { padding-top: 28px; padding-bottom: 36px; }
      .breadcrumb { font-size: 0.9rem; margin-bottom: 18px; }
      .breadcrumb a { color: inherit; }
      h1 { line-height: 1.35; font-size: clamp(1.55rem, 4vw, 2.2rem); margin: 0 0 12px; }
      .meta { display: flex; flex-wrap: wrap; gap: 10px 18px; align-items: center; margin-bottom: 24px; font-size: 0.95rem; }
      .meta a { color: inherit; font-weight: 650; }
      .rating { font-weight: 750; }
      article { padding: 22px; border: 1px solid color-mix(in srgb, CanvasText 16%, transparent); border-radius: 14px; }
      article p { margin: 0; white-space: normal; overflow-wrap: anywhere; }
      .notice { margin: 0 0 16px; padding: 10px 12px; border-radius: 8px; background: color-mix(in srgb, #d00303 14%, transparent); font-weight: 700; }
      .about { margin-top: 26px; font-size: 0.94rem; }
      footer { padding-top: 20px; padding-bottom: 36px; border-top: 1px solid color-mix(in srgb, CanvasText 16%, transparent); font-size: 0.9rem; }
    </style>
  </head>
  <body>
    <header><a href="/">Sharemarium</a></header>
    <main>
      <nav class="breadcrumb" aria-label="パンくず"><a href="/">Sharemarium</a> / <a href="${escapeHtml(profileUrl)}">${escapeHtml(username)}</a> / レビュー</nav>
      <h1>『${escapeHtml(bookTitle)}』のレビュー</h1>
      <div class="meta">
        <span>投稿者: <a href="${escapeHtml(profileUrl)}">${escapeHtml(username)}</a></span>
        ${ratingHtml}
        ${displayDate ? `<time datetime="${escapeHtml(datePublished)}">${escapeHtml(displayDate)}</time>` : ""}
      </div>
      ${spoilerNotice}
      <article aria-label="レビュー本文"><p>${reviewBody}</p></article>
      <p class="about">このページはSharemariumに公開された読書レビューの個別ページです。</p>
    </main>
    <footer><a href="/">Sharemariumで読書記録を見る</a></footer>
  </body>
</html>`);
};

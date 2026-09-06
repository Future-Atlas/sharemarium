// Vercel serverless function to return crawler-friendly HTML for Sharemarium.
// Policy: no Google APIs. Data source order is Rakuten first, then NDL fallback.

const { requestRakuten } = require("./_rakuten_request");

const SUPABASE_URL = process.env.SUPABASE_URL || "";
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || "";
const RAKUTEN_APP_ID = process.env.RAKUTEN_APP_ID || "";
const RAKUTEN_ACCESS_KEY = process.env.RAKUTEN_ACCESS_KEY || "";
const RAKUTEN_REFERER =
  process.env.RAKUTEN_REFERER || "https://www.sharemarium.com/";
const IS_PRODUCTION = process.env.VERCEL_ENV === "production";
const ENABLE_NDL_FALLBACK =
  String(process.env.SEO_ENABLE_NDL_FALLBACK || "false").toLowerCase() ===
  "true";

const RAKUTEN_BOOK_API =
  "https://openapi.rakuten.co.jp/services/api/BooksBook/Search/20170404";
const RAKUTEN_FOREIGN_BOOK_API =
  "https://openapi.rakuten.co.jp/services/api/BooksForeignBook/Search/20170404";
const NDL_OPENSEARCH_API = "https://ndlsearch.ndl.go.jp/api/opensearch";
const SITE_URL = "https://sharemarium.com";
const SITE_NAME = "Sharemarium";
const SITE_ALT_NAME = "シェアマリウム";
const SITE_BRAND = `${SITE_NAME}（${SITE_ALT_NAME}）`;
const SITE_TITLE = "Sharemarium（シェアマリウム） | 読書レビューSNS";
const TOP_DESCRIPTION =
  "Sharemarium（シェアマリウム）は、読んだ本を記録し、感想をみんなと共有できる読書レビューSNSです。自分用の読書記録にも、お友だちとの感想共有にも使えるSharemariumで、あなただけの本棚を作りましょう。";
const OG_IMAGE_URL = `${SITE_URL}/icons/Icon-512.png`;

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function parseJsonSafe(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function errorCodeFromText(bodyText) {
  const parsed = parseJsonSafe(bodyText);
  if (!parsed) return "unparseable";
  return (
    parsed?.errors?.errorCode ||
    parsed?.error?.code ||
    parsed?.errorCode ||
    "unknown"
  );
}

function supabaseHeaders() {
  return {
    apikey: SUPABASE_ANON_KEY,
    Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
  };
}

async function supabaseGet(pathAndQuery) {
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) return null;

  const response = await fetch(`${SUPABASE_URL}/rest/v1/${pathAndQuery}`, {
    headers: supabaseHeaders(),
  });

  const body = await response.text();
  if (!response.ok) {
    throw new Error(`Supabase request failed: ${response.status} ${body}`);
  }

  return parseJsonSafe(body) || [];
}

function rakutenEnabled() {
  return RAKUTEN_APP_ID !== "" && RAKUTEN_ACCESS_KEY !== "";
}

function rakutenBaseParams() {
  return `format=json&applicationId=${encodeURIComponent(
    RAKUTEN_APP_ID,
  )}&accessKey=${encodeURIComponent(RAKUTEN_ACCESS_KEY)}`;
}

async function rakutenFetch(url) {
  return requestRakuten(url, {
    origin: RAKUTEN_REFERER,
    userAgent: "Sharemarium-SEO-Bot/1.0 (+https://www.sharemarium.com)",
  });
}

function normalizeRakutenBooks(items, sectionTitle) {
  return (items || []).map((item) => {
    const data = item?.Item || {};
    return {
      title: data.title || "不明なタイトル",
      author: data.author || "不明な著者",
      coverUrl: data.largeImageUrl || "",
      genre: sectionTitle,
      description: data.itemCaption || "",
    };
  });
}

function decodeXmlEntities(text) {
  return String(text || "")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");
}

function extractXmlTag(block, tags) {
  for (const tag of tags) {
    const re = new RegExp(`<${tag}[^>]*>([\\s\\S]*?)<\\/${tag}>`, "i");
    const match = block.match(re);
    if (match && match[1]) {
      return decodeXmlEntities(match[1].trim());
    }
  }
  return "";
}

function normalizeNdlBooks(xmlText, sectionTitle) {
  const items = xmlText.match(/<item>[\s\S]*?<\/item>/gi) || [];
  return items.slice(0, 6).map((itemBlock) => {
    const title = extractXmlTag(itemBlock, ["title", "dc:title"]);
    const author = extractXmlTag(itemBlock, ["author", "dc:creator"]);
    const description = extractXmlTag(itemBlock, ["dc:description"]);
    return {
      title: title || "不明なタイトル",
      author: author || "不明な著者",
      coverUrl: "",
      genre: sectionTitle,
      description,
    };
  });
}

async function fetchRakutenSection(sectionTitle, diagnostics) {
  if (!rakutenEnabled()) {
    diagnostics.rakutenSectionFailures.push(`${sectionTitle}:disabled`);
    return [];
  }

  let endpoint = RAKUTEN_BOOK_API;
  let extra = "page=1&hits=6";

  if (sectionTitle === "おすすめの本") {
    extra += "&booksGenreId=001004";
  } else if (sectionTitle === "洋書") {
    endpoint = RAKUTEN_FOREIGN_BOOK_API;
    extra += "&booksGenreId=005";
  } else if (sectionTitle === "人気作品") {
    extra +=
      "&booksGenreId=001&keyword=%E3%83%99%E3%82%B9%E3%83%88%E3%82%BB%E3%83%A9%E3%83%BC";
  } else {
    return [];
  }

  const url = `${endpoint}?${rakutenBaseParams()}&${extra}`;
  const response = await rakutenFetch(url);
  const body = await response.text();
  if (!response.ok) {
    diagnostics.rakutenSectionFailures.push(
      `${sectionTitle}:${response.status}:${errorCodeFromText(body)}`,
    );
    return [];
  }

  const json = parseJsonSafe(body);
  return normalizeRakutenBooks(json?.Items, sectionTitle);
}

async function fetchNdlSection(sectionTitle, diagnostics) {
  let queryParams = "cnt=6&startPage=1&mediatype=1";

  if (sectionTitle === "おすすめの本") {
    queryParams += "&any=%E8%A9%B1%E9%A1%8C%20%E6%9C%AC";
  } else if (sectionTitle === "洋書") {
    queryParams += "&any=English";
  } else if (sectionTitle === "人気作品") {
    queryParams +=
      "&any=%E3%83%99%E3%82%B9%E3%83%88%E3%82%BB%E3%83%A9%E3%83%BC";
  } else {
    return [];
  }

  const url = `${NDL_OPENSEARCH_API}?${queryParams}`;
  const response = await fetch(url);
  const body = await response.text();
  if (!response.ok) {
    diagnostics.ndlSectionFailures.push(`${sectionTitle}:${response.status}`);
    return [];
  }

  const books = normalizeNdlBooks(body, sectionTitle);
  if (books.length === 0) {
    diagnostics.ndlSectionFailures.push(`${sectionTitle}:empty`);
  }
  return books;
}

async function fetchRakutenBookByIsbn(isbn, diagnostics) {
  if (!rakutenEnabled()) return null;
  if (!isbn) return null;

  const compact = String(isbn).replace(/[^0-9Xx]/g, "");
  if (compact.length !== 10 && compact.length !== 13) return null;

  const url = `${RAKUTEN_BOOK_API}?${rakutenBaseParams()}&isbn=${encodeURIComponent(
    compact,
  )}&hits=1&page=1`;
  const response = await rakutenFetch(url);
  const body = await response.text();
  if (!response.ok) {
    diagnostics.rakutenIsbnFailures += 1;
    return null;
  }

  const json = parseJsonSafe(body);
  const first = json?.Items?.[0]?.Item;
  if (!first) return null;

  return {
    title: first.title || compact,
    author: first.author || "不明な著者",
    coverUrl: first.largeImageUrl || "",
  };
}

async function fetchNdlBookByIsbn(isbn, diagnostics) {
  if (!isbn) return null;

  const compact = String(isbn).replace(/[^0-9Xx]/g, "");
  if (compact.length !== 10 && compact.length !== 13) return null;

  const url = `${NDL_OPENSEARCH_API}?cnt=1&startPage=1&mediatype=1&any=${encodeURIComponent(
    compact,
  )}`;
  const response = await fetch(url);
  const body = await response.text();
  if (!response.ok) {
    diagnostics.ndlIsbnFailures += 1;
    return null;
  }

  const books = normalizeNdlBooks(body, "isbn");
  if (!books.length) {
    diagnostics.ndlIsbnFailures += 1;
    return null;
  }

  return {
    title: books[0].title,
    author: books[0].author,
    coverUrl: "",
  };
}

async function resolveBookByIsbn(isbn, diagnostics) {
  const rakuten = await fetchRakutenBookByIsbn(isbn, diagnostics);
  if (rakuten) return rakuten;
  if (!ENABLE_NDL_FALLBACK) return null;
  return fetchNdlBookByIsbn(isbn, diagnostics);
}

function renderBookList(books) {
  if (!books.length) {
    return "<p>現在、表示できる本情報がありません。</p>";
  }

  return books
    .map(
      (book) => `
    <div class="book-item">
      ${book.coverUrl ? `<img class="book-cover" src="${escapeHtml(book.coverUrl)}" alt="${escapeHtml(book.title)} Cover">` : ""}
      <div class="book-details">
        <h4 class="book-title">${escapeHtml(book.title)}</h4>
        <p class="book-author">著者: ${escapeHtml(book.author)}</p>
        ${book.description ? `<p style="font-size:0.9em; color:#555;">${escapeHtml(book.description)}</p>` : ""}
      </div>
    </div>
  `,
    )
    .join("");
}

function setDiagnosticsHeader(res, diagnostics) {
  const asciiToken = (value) =>
    encodeURIComponent(String(value || "none")).replace(/%20/g, "+");

  const rakutenDetail = diagnostics.rakutenSectionFailures
    .slice(0, 3)
    .join("|")
    .replace(/\s+/g, "_")
    .replace(/;/g, ",");
  const ndlDetail = diagnostics.ndlSectionFailures
    .slice(0, 3)
    .join("|")
    .replace(/\s+/g, "_")
    .replace(/;/g, ",");

  res.setHeader(
    "X-SEO-Diagnostics",
    [
      `rakuten_section_fail=${diagnostics.rakutenSectionFailures.length}`,
      `rakuten_section_detail=${asciiToken(rakutenDetail)}`,
      `rakuten_isbn_fail=${diagnostics.rakutenIsbnFailures}`,
      `ndl_section_fail=${diagnostics.ndlSectionFailures.length}`,
      `ndl_section_detail=${asciiToken(ndlDetail)}`,
      `ndl_isbn_fail=${diagnostics.ndlIsbnFailures}`,
      `ndl_fallback=${ENABLE_NDL_FALLBACK ? "on" : "off"}`,
      `supabase_index_err=${diagnostics.supabaseIndexError === "none" ? "no" : "yes"}`,
      `supabase_profile_err=${diagnostics.supabaseProfileError === "none" ? "no" : "yes"}`,
    ].join(";"),
  );
}

function toAbsoluteUrl(pathname) {
  const normalized = String(pathname || "/").startsWith("/")
    ? String(pathname || "/")
    : `/${String(pathname || "")}`;
  return `${SITE_URL}${normalized}`;
}

function canonicalProfilePath(profileId) {
  const rawId = String(profileId || "").trim();
  if (!rawId) return "/users";
  return `/users/${encodeURIComponent(rawId)}`;
}

function looksLikeUuid(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
    String(value || "").trim(),
  );
}

function faqStructuredData() {
  return {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: [
      {
        "@type": "Question",
        name: "シェアマリウムとは何ですか？",
        acceptedAnswer: {
          "@type": "Answer",
          text: "シェアマリウムは英字でSharemariumと表記する、読書記録・本管理・レビュー共有のためのWebサービスです。",
        },
      },
      {
        "@type": "Question",
        name: "Sharemariumでは何ができますか？",
        acceptedAnswer: {
          "@type": "Answer",
          text: "本の検索、レビュー投稿、読書記録の管理、タイムライン閲覧ができます。",
        },
      },
      {
        "@type": "Question",
        name: "レビューは誰でも投稿できますか？",
        acceptedAnswer: {
          "@type": "Answer",
          text: "アプリ内アカウントでログインしたユーザーがレビュー投稿できます。",
        },
      },
      {
        "@type": "Question",
        name: "Sharemariumの対象ジャンルは何ですか？",
        acceptedAnswer: {
          "@type": "Answer",
          text: "おすすめの本、洋書、人気作品を中心に紹介しています。",
        },
      },
    ],
  };
}

function organizationStructuredData() {
  return {
    "@context": "https://schema.org",
    "@type": "Organization",
    name: SITE_NAME,
    alternateName: SITE_ALT_NAME,
    url: `${SITE_URL}/`,
    logo: `${SITE_URL}/icons/Icon-192.png`,
  };
}

function breadcrumbStructuredData(items) {
  return {
    "@context": "https://schema.org",
    "@type": "BreadcrumbList",
    itemListElement: items.map((item, index) => ({
      "@type": "ListItem",
      position: index + 1,
      name: item.name,
      item: item.url,
    })),
  };
}

function itemListStructuredData(sectionTitle, books, pagePath) {
  return {
    "@context": "https://schema.org",
    "@type": "ItemList",
    name: `${sectionTitle}一覧`,
    url: toAbsoluteUrl(pagePath),
    numberOfItems: books.length,
    itemListElement: books.map((book, index) => ({
      "@type": "ListItem",
      position: index + 1,
      item: {
        "@type": "Book",
        name: book.title,
        author: book.author,
        description: book.description || "",
      },
    })),
  };
}

function webApplicationStructuredData() {
  return {
    "@context": "https://schema.org",
    "@type": "WebApplication",
    name: SITE_NAME,
    alternateName: SITE_ALT_NAME,
    url: `${SITE_URL}/`,
    applicationCategory: "LifestyleApplication",
    operatingSystem: "Web",
    inLanguage: "ja",
    description:
      "Sharemarium（シェアマリウム）は、読んだ本、読みたい本、読書履歴、蔵書をまとめて管理できる読書記録Webアプリです。",
  };
}

function siteNavigationStructuredData() {
  const navItems = [
    { name: "ホーム", url: `${SITE_URL}/` },
    { name: "おすすめの本", url: `${SITE_URL}/genre/recommended` },
    { name: "洋書", url: `${SITE_URL}/genre/western` },
    { name: "人気作品", url: `${SITE_URL}/genre/popular` },
    { name: "プライバシーポリシー", url: `${SITE_URL}/privacy` },
    { name: "利用規約", url: `${SITE_URL}/terms` },
  ];

  return navItems.map((item) => ({
    "@context": "https://schema.org",
    "@type": "SiteNavigationElement",
    name: item.name,
    url: item.url,
  }));
}

function sectionByGenrePath(pathname) {
  const map = {
    "/genre/recommended": "おすすめの本",
    "/genre/western": "洋書",
    "/genre/popular": "人気作品",
  };
  return map[pathname] || "";
}

function genrePathBySection(sectionTitle) {
  const map = {
    おすすめの本: "/genre/recommended",
    洋書: "/genre/western",
    人気作品: "/genre/popular",
  };
  return map[sectionTitle] || "/";
}

function truncateForMeta(text, maxLength = 110) {
  const value = String(text || "")
    .replace(/\s+/g, " ")
    .trim();
  if (!value) return "";
  if (value.length <= maxLength) return value;
  return `${value.slice(0, maxLength - 1)}…`;
}

function buildProfileDescription(username, stats) {
  return truncateForMeta(
    `${username}さんのプロフィールページ。読了数${stats.read}冊、フォロワー${stats.followers}人、フォロー${stats.following}人。書評やお気に入り本をチェックできます。`,
  );
}

function buildGenreDescription(sectionTitle, books) {
  const titles = (books || [])
    .slice(0, 3)
    .map((book) => book?.title)
    .filter(Boolean)
    .join("、");
  if (!titles) {
    return truncateForMeta(
      `Sharemariumの${sectionTitle}ページです。注目タイトルや著者情報、作品概要をまとめて確認できます。`,
    );
  }
  return truncateForMeta(
    `Sharemariumの${sectionTitle}ページです。${titles} などの注目タイトルを一覧で確認できます。`,
  );
}

function buildBookDescription(book) {
  const base = `${book.title}（${book.author}）の紹介ページです。`;
  const detail = book.description
    ? `${book.description} ${book.section}ジャンルの関連作品も確認できます。`
    : `${book.section}ジャンルの関連作品も確認できます。`;
  return truncateForMeta(`${base}${detail}`);
}

module.exports = async (req, res) => {
  const { path } = req.query;
  const decodedPath = decodeURIComponent(path || "");
  const diagnostics = {
    rakutenSectionFailures: [],
    rakutenIsbnFailures: 0,
    ndlSectionFailures: [],
    ndlIsbnFailures: 0,
    supabaseIndexError: "none",
    supabaseProfileError: "none",
  };

  if (!IS_PRODUCTION) {
    res.setHeader("X-Robots-Tag", "noindex, nofollow");
  }

  const renderPage = ({
    title,
    description,
    content,
    jsonLd,
    robots,
    pagePath = "/",
    extraJsonLd = [],
    enableAds = false,
  }) => {
    const absoluteUrl = toAbsoluteUrl(pagePath);
    const fullTitle = title.includes(SITE_NAME)
      ? title.includes(SITE_ALT_NAME)
        ? title
        : title.replace(SITE_NAME, SITE_BRAND)
      : `${title} | ${SITE_BRAND}`;
    const jsonLdList = [
      organizationStructuredData(),
      jsonLd,
      ...extraJsonLd,
    ].filter(Boolean);
    return `
    <!DOCTYPE html>
    <html lang="ja">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>${fullTitle}</title>
      <meta name="description" content="${description}">
            <meta name="robots" content="${IS_PRODUCTION ? robots || "index,follow" : "noindex,nofollow"}">
      <link rel="canonical" href="${absoluteUrl}">
        <meta property="og:title" content="${fullTitle}">
      <meta property="og:description" content="${description}">
            <meta property="og:site_name" content="${SITE_BRAND}">
      <meta property="og:type" content="website">
            <meta property="og:locale" content="ja_JP">
      <meta property="og:url" content="${absoluteUrl}">
            <meta property="og:image" content="${OG_IMAGE_URL}">
      <meta name="twitter:card" content="summary_large_image">
      <meta name="twitter:title" content="${fullTitle}">
      <meta name="twitter:description" content="${description}">
            <meta name="twitter:image" content="${OG_IMAGE_URL}">
      <link rel="icon" type="image/png" sizes="48x48" href="${SITE_URL}/favicon.png">
      <link rel="icon" type="image/png" sizes="192x192" href="${SITE_URL}/icons/Icon-192.png">
      <link rel="icon" type="image/svg+xml" sizes="any" href="${SITE_URL}/favicon.svg">
      <link rel="shortcut icon" href="${SITE_URL}/favicon.png">
      <link rel="apple-touch-icon" sizes="192x192" href="${SITE_URL}/icons/Icon-192.png">
      <script>
        window.__sharemariumAdsAllowed = ${enableAds ? "true" : "false"};
      </script>
      ${
        enableAds
          ? `
      <script>
        (function() {
          if (!window.__sharemariumAdsAllowed) return;
          const existing = document.querySelector('script[data-adsense]');
          if (existing) return;
          const script = document.createElement('script');
          script.async = true;
          script.src = 'https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js?client=ca-pub-3052085512168272';
          script.crossOrigin = 'anonymous';
          script.dataset.adsense = '1';
          document.head.appendChild(script);
        })();
      </script>`
          : ""
      }
      ${jsonLdList
        .map(
          (item) =>
            `<script type="application/ld+json">${JSON.stringify(item)}</script>`,
        )
        .join("")}
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; line-height: 1.6; color: #333; max-width: 800px; margin: 0 auto; padding: 20px; }
        header { border-bottom: 2px solid #ff3b30; padding-bottom: 10px; margin-bottom: 20px; }
        h1 { color: #ff3b30; margin: 0; }
        h2 { border-bottom: 1px solid #ddd; padding-bottom: 5px; margin-top: 30px; }
        .book-item { display: flex; margin-bottom: 15px; border: 1px solid #eee; border-radius: 8px; padding: 10px; }
        .book-cover { width: 60px; height: 90px; object-fit: cover; margin-right: 15px; border-radius: 4px; }
        .book-details { flex: 1; }
        .book-title { font-weight: bold; font-size: 1.1em; margin: 0; }
        .book-author { color: #666; font-size: 0.9em; margin: 5px 0; }
        .post-card { border: 1px solid #eee; border-radius: 8px; padding: 15px; margin-bottom: 15px; background: #fafafa; }
        .post-header { display: flex; justify-content: space-between; margin-bottom: 10px; }
        .post-rating { color: #ffcc00; font-weight: bold; }
        .post-comment { font-style: italic; color: #555; }
        footer { margin-top: 50px; text-align: center; font-size: 0.8em; color: #999; border-top: 1px solid #eee; padding-top: 20px; }
      </style>
    </head>
    <body>
            <header>
                <h1>${SITE_BRAND}</h1>
        <p>本のレビューと読書記録を管理できるアプリ</p>
      </header>
      <main>
                <nav style="margin: 0 0 16px 0; font-size: 0.95em;">
                    <a href="${SITE_URL}/">ホーム</a> |
                    <a href="${SITE_URL}/genre/recommended">おすすめの本</a> |
                    <a href="${SITE_URL}/genre/western">洋書</a> |
                    <a href="${SITE_URL}/genre/popular">人気作品</a>
                </nav>
        ${content}
      </main>
      <footer>
        <p>© 2026 ${SITE_BRAND}. All rights reserved.</p>
      </footer>
    </body>
    </html>
  `;
  };

  if (decodedPath.includes("user") || decodedPath.includes("profile")) {
    let username = "ユーザー";
    let bio = "プロフィール情報を準備中です。";
    let stats = { read: 0, followers: 0, following: 0 };
    let posts = [];
    let favorites = [];
    let hasReliableData = false;
    const isbnCache = new Map();
    const requestedProfileId = (() => {
      const match = decodedPath.match(
        /(?:\/users\/|\/user\/|\/profile\/)([^/?#]+)/i,
      );
      return match ? decodeURIComponent(match[1]) : "";
    })();
    const canonicalProfileUrl = canonicalProfilePath(requestedProfileId || "");

    try {
      if (requestedProfileId) {
        const profileFilter = looksLikeUuid(requestedProfileId)
          ? `id=eq.${encodeURIComponent(requestedProfileId)}`
          : `user_id=eq.${encodeURIComponent(requestedProfileId.toLowerCase())}`;
        const profiles = await supabaseGet(
          `profiles?${profileFilter}&select=id,username,user_id,bio,read_count,followers_count,following_count,is_private,is_suspended`,
        );
        const user = Array.isArray(profiles) ? profiles[0] : null;
        if (user) {
          const isPublic =
            user.is_private !== true && user.is_suspended !== true;
          if (!isPublic) {
            const forbiddenHtml = renderPage({
              title: "プロフィールは非公開です",
              description:
                "指定されたプロフィールは公開範囲の条件を満たしていません。",
              content: `<h2>プロフィールは非公開です</h2><p>このユーザーの公開プロフィールは表示できません。</p>`,
              jsonLd: {
                "@context": "https://schema.org",
                "@type": "WebPage",
                name: "プロフィールは非公開です",
                description:
                  "指定されたプロフィールは公開範囲の条件を満たしていません。",
                url: toAbsoluteUrl(canonicalProfileUrl),
              },
              pagePath: canonicalProfileUrl,
              robots: "noindex,nofollow",
            });
            res.setHeader("Content-Type", "text/html; charset=utf-8");
            setDiagnosticsHeader(res, diagnostics);
            return res.status(404).send(forbiddenHtml);
          }

          hasReliableData = true;
          username = user.username;
          bio = user.bio || bio;
          stats.read = user.read_count || stats.read;
          stats.followers = user.followers_count || stats.followers;
          stats.following = user.following_count || stats.following;

          const fetchedPosts = await supabaseGet(
            `posts?profile_id=eq.${user.id}&select=id,book_id,rating,comment,created_at&order=created_at.desc&limit=10`,
          );

          if (Array.isArray(fetchedPosts) && fetchedPosts.length > 0) {
            posts = await Promise.all(
              fetchedPosts.map(async (p) => {
                const rawBookId = p.book_id || "書籍ID未設定";
                let resolved = isbnCache.get(rawBookId);
                if (resolved === undefined) {
                  resolved = await resolveBookByIsbn(rawBookId, diagnostics);
                  isbnCache.set(rawBookId, resolved || null);
                }

                return {
                  id: p.id,
                  username,
                  book_title: resolved?.title || rawBookId,
                  rating: p.rating,
                  comment: p.comment,
                  date: p.created_at
                    ? new Date(p.created_at).toLocaleDateString("ja-JP")
                    : "",
                };
              }),
            );
          }

          const favoriteRows = await supabaseGet(
            `favorites?profile_id=eq.${user.id}&select=book_id&limit=20`,
          );

          if (Array.isArray(favoriteRows) && favoriteRows.length > 0) {
            favorites = await Promise.all(
              favoriteRows.map(async (row) => {
                const rawBookId = row.book_id || "書籍ID未設定";
                let resolved = isbnCache.get(rawBookId);
                if (resolved === undefined) {
                  resolved = await resolveBookByIsbn(rawBookId, diagnostics);
                  isbnCache.set(rawBookId, resolved || null);
                }

                return {
                  title: resolved?.title || rawBookId,
                  author: resolved?.author || "著者情報なし",
                  rating_avg: "-",
                };
              }),
            );
          }
        } else {
          const notFoundHtml = renderPage({
            title: "ユーザーが見つかりません",
            description: "指定されたユーザーは存在しません。",
            content: `<h2>ユーザーが見つかりません</h2><p>指定されたURLに対応するプロフィールは存在しません。</p>`,
            jsonLd: {
              "@context": "https://schema.org",
              "@type": "WebPage",
              name: "ユーザーが見つかりません",
              description: "指定されたユーザーは存在しません。",
              url: toAbsoluteUrl(canonicalProfileUrl),
            },
            pagePath: canonicalProfileUrl,
            robots: "noindex,nofollow",
          });
          res.setHeader("Content-Type", "text/html; charset=utf-8");
          setDiagnosticsHeader(res, diagnostics);
          return res.status(404).send(notFoundHtml);
        }
      }
    } catch (err) {
      diagnostics.supabaseProfileError =
        err instanceof Error ? err.message.slice(0, 80) : "unknown";
    }

    const postsHtml = posts
      .map(
        (p) => `
      <div class="post-card">
        <div class="post-header">
          <strong>${escapeHtml(p.book_title)}</strong>
          <span class="post-rating">★ ${p.rating}/5</span>
        </div>
        <p class="post-comment">"${escapeHtml(p.comment)}"</p>
        <small style="color:#888;">投稿日: ${escapeHtml(p.date)}</small>
      </div>
    `,
      )
      .join("");

    const favoritesHtml = favorites
      .map(
        (b) => `
      <div class="book-item">
        <div class="book-details">
          <p class="book-title">${escapeHtml(b.title)}</p>
          <p class="book-author">著者: ${escapeHtml(b.author)} | 評価: ★ ${escapeHtml(b.rating_avg)}</p>
        </div>
      </div>
    `,
      )
      .join("");

    const canonicalPath = canonicalProfilePath(
      user?.user_id || user?.username || requestedProfileId || "",
    );
    const html = renderPage({
      title: `${escapeHtml(username)} のプロフィール`,
      description: buildProfileDescription(username, stats),
      content: `
        <h2>ユーザー情報</h2>
        <div style="background:#eee; padding:15px; border-radius:8px; margin-bottom:20px;">
          <h3>${escapeHtml(username)}</h3>
          <p>${escapeHtml(bio)}</p>
          <p><strong>読了:</strong> ${stats.read} 冊 | <strong>フォロワー:</strong> ${stats.followers} 人 | <strong>フォロー:</strong> ${stats.following} 人</p>
        </div>

        <h2>投稿した書評</h2>
        <div>${postsHtml.length > 0 ? postsHtml : "<p>現在、表示できる投稿がありません。</p>"}</div>

        <h2>お気に入りの本</h2>
        <div>${favoritesHtml.length > 0 ? favoritesHtml : "<p>現在、表示できるお気に入り情報がありません。</p>"}</div>
      `,
      jsonLd: {
        "@context": "https://schema.org",
        "@type": "ProfilePage",
        name: escapeHtml(username),
        description: escapeHtml(bio),
      },
      pagePath: canonicalPath,
      robots: "index,follow",
    });

    res.setHeader("Content-Type", "text/html; charset=utf-8");
    setDiagnosticsHeader(res, diagnostics);
    return res.status(200).send(html);
  }

  if (decodedPath === "/privacy") {
    const html = renderPage({
      title: "プライバシーポリシー",
      description:
        "Sharemariumのプライバシーポリシーです。読書記録アプリにおける個人情報の取り扱い方針を説明しています。",
      content: `
        <section>
          <h2>プライバシーポリシー</h2>
          <p>Sharemariumは、読書記録アプリの提供に必要な範囲で情報を取り扱います。</p>
          <h3>収集する情報</h3>
          <p>ログイン情報、読書記録、感想、アプリ利用時に必要な技術情報を収集する場合があります。</p>
          <h3>利用目的</h3>
          <p>本管理アプリ機能の提供、読書履歴表示、サービス改善、不正利用防止のために利用します。</p>
        </section>
      `,
      jsonLd: {
        "@context": "https://schema.org",
        "@type": "WebPage",
        name: "プライバシーポリシー | Sharemarium",
        url: toAbsoluteUrl(decodedPath),
        description:
          "Sharemariumのプライバシーポリシーです。個人情報の取り扱い方針を説明しています。",
      },
      extraJsonLd: [
        breadcrumbStructuredData([
          { name: "ホーム", url: `${SITE_URL}/` },
          {
            name: "プライバシーポリシー",
            url: toAbsoluteUrl(decodedPath),
          },
        ]),
      ],
      pagePath: decodedPath,
      robots: "index,follow",
    });

    res.setHeader("Content-Type", "text/html; charset=utf-8");
    setDiagnosticsHeader(res, diagnostics);
    return res.status(200).send(html);
  }

  if (decodedPath === "/terms") {
    const html = renderPage({
      title: "利用規約",
      description:
        "Sharemariumの利用規約です。読書記録・本管理アプリの利用条件を掲載しています。",
      content: `
        <section>
          <h2>利用規約</h2>
          <p>Sharemariumをご利用いただく際の条件を定めたものです。</p>
          <h3>サービス内容</h3>
          <p>Sharemariumは、読んだ本の記録、読みたい本の管理、読書履歴の保存などを提供します。</p>
          <h3>禁止事項</h3>
          <p>不正アクセス、第三者への迷惑行為、法令違反につながる行為は禁止します。</p>
        </section>
      `,
      jsonLd: {
        "@context": "https://schema.org",
        "@type": "WebPage",
        name: "利用規約 | Sharemarium",
        url: toAbsoluteUrl(decodedPath),
        description:
          "Sharemariumの利用規約です。読書記録・本管理アプリの利用条件を掲載しています。",
      },
      extraJsonLd: [
        breadcrumbStructuredData([
          { name: "ホーム", url: `${SITE_URL}/` },
          { name: "利用規約", url: toAbsoluteUrl(decodedPath) },
        ]),
      ],
      pagePath: decodedPath,
      robots: "index,follow",
    });

    res.setHeader("Content-Type", "text/html; charset=utf-8");
    setDiagnosticsHeader(res, diagnostics);
    return res.status(200).send(html);
  }

  if (decodedPath === "/community-guidelines") {
    const html = renderPage({
      title: "コミュニティガイドライン",
      description:
        "Sharemariumのコミュニティガイドラインです。安心して使える読書コミュニティのためのルールを掲載しています。",
      content: `
        <section>
          <h2>コミュニティガイドライン</h2>
          <p>Sharemariumでは、他の利用者への敬意と安全性を重視しています。</p>
          <h3>主な方針</h3>
          <p>誹謗中傷、差別、スパム、不正行為、権利侵害につながる投稿は禁止します。</p>
        </section>
      `,
      jsonLd: {
        "@context": "https://schema.org",
        "@type": "WebPage",
        name: "コミュニティガイドライン | Sharemarium",
        url: toAbsoluteUrl(decodedPath),
        description:
          "Sharemariumのコミュニティガイドラインです。安心して使える読書コミュニティのためのルールを掲載しています。",
      },
      extraJsonLd: [
        breadcrumbStructuredData([
          { name: "ホーム", url: `${SITE_URL}/` },
          {
            name: "コミュニティガイドライン",
            url: toAbsoluteUrl(decodedPath),
          },
        ]),
      ],
      pagePath: decodedPath,
      robots: "index,follow",
    });

    res.setHeader("Content-Type", "text/html; charset=utf-8");
    setDiagnosticsHeader(res, diagnostics);
    return res.status(200).send(html);
  }

  if (decodedPath === "/infringement-policy") {
    const html = renderPage({
      title: "権利侵害・通報ポリシー",
      description:
        "Sharemariumの権利侵害・通報ポリシーです。著作権侵害や不適切な投稿への対応方針を説明しています。",
      content: `
        <section>
          <h2>権利侵害・通報ポリシー</h2>
          <p>著作権、肖像権、商標権など第三者の権利を侵害する投稿は禁止しています。</p>
          <h3>通報への対応</h3>
          <p>通報内容を確認し、必要に応じて投稿の削除やアカウント制限を行います。</p>
        </section>
      `,
      jsonLd: {
        "@context": "https://schema.org",
        "@type": "WebPage",
        name: "権利侵害・通報ポリシー | Sharemarium",
        url: toAbsoluteUrl(decodedPath),
        description:
          "Sharemariumの権利侵害・通報ポリシーです。著作権侵害や不適切な投稿への対応方針を説明しています。",
      },
      extraJsonLd: [
        breadcrumbStructuredData([
          { name: "ホーム", url: `${SITE_URL}/` },
          {
            name: "権利侵害・通報ポリシー",
            url: toAbsoluteUrl(decodedPath),
          },
        ]),
      ],
      pagePath: decodedPath,
      robots: "index,follow",
    });

    res.setHeader("Content-Type", "text/html; charset=utf-8");
    setDiagnosticsHeader(res, diagnostics);
    return res.status(200).send(html);
  }

  if (decodedPath === "/external-transmission") {
    const html = renderPage({
      title: "外部送信に関する公表事項",
      description:
        "Sharemariumの外部送信に関する公表事項です。第三者サービスへの情報送信内容と目的を掲載しています。",
      content: `
        <section>
          <h2>外部送信に関する公表事項</h2>
          <p>本サービスでは、機能提供・分析・広告配信のために必要な範囲で外部事業者へ情報を送信する場合があります。</p>
          <h3>主な目的</h3>
          <p>ログイン維持、サービス改善、広告配信と効果測定、不正利用防止のために利用します。</p>
        </section>
      `,
      jsonLd: {
        "@context": "https://schema.org",
        "@type": "WebPage",
        name: "外部送信に関する公表事項 | Sharemarium",
        url: toAbsoluteUrl(decodedPath),
        description:
          "Sharemariumの外部送信に関する公表事項です。第三者サービスへの情報送信内容と目的を掲載しています。",
      },
      extraJsonLd: [
        breadcrumbStructuredData([
          { name: "ホーム", url: `${SITE_URL}/` },
          {
            name: "外部送信に関する公表事項",
            url: toAbsoluteUrl(decodedPath),
          },
        ]),
      ],
      pagePath: decodedPath,
      robots: "index,follow",
    });

    res.setHeader("Content-Type", "text/html; charset=utf-8");
    setDiagnosticsHeader(res, diagnostics);
    return res.status(200).send(html);
  }

  if (decodedPath === "/contact") {
    const html = renderPage({
      title: "お問い合わせ",
      description:
        "Sharemariumへのお問い合わせページです。ご意見・不具合報告・権利侵害の申告を受け付けています。",
      content: `
        <section>
          <h2>お問い合わせ</h2>
          <p>サービスに関するご質問、不具合報告、権利侵害申告などを受け付けています。</p>
          <p>アプリ内のお問い合わせフォームからご連絡ください。</p>
        </section>
      `,
      jsonLd: {
        "@context": "https://schema.org",
        "@type": "ContactPage",
        name: "お問い合わせ | Sharemarium",
        url: toAbsoluteUrl(decodedPath),
        description:
          "Sharemariumへのお問い合わせページです。ご意見・不具合報告・権利侵害の申告を受け付けています。",
      },
      extraJsonLd: [
        breadcrumbStructuredData([
          { name: "ホーム", url: `${SITE_URL}/` },
          { name: "お問い合わせ", url: toAbsoluteUrl(decodedPath) },
        ]),
      ],
      pagePath: decodedPath,
      robots: "index,follow",
    });

    res.setHeader("Content-Type", "text/html; charset=utf-8");
    setDiagnosticsHeader(res, diagnostics);
    return res.status(200).send(html);
  }

  const genreSection = sectionByGenrePath(decodedPath);
  if (genreSection) {
    let books = [];
    try {
      books = await fetchRakutenSection(genreSection, diagnostics);
    } catch {
      books = [];
    }

    const hasGenreBooks = books.length > 0;
    const detailLinks = "";

    const html = renderPage({
      title: `${genreSection}一覧`,
      description: buildGenreDescription(genreSection, books),
      enableAds: false,
      content: `
        <h2>${genreSection}について</h2>
        <p>Sharemariumが注目する${genreSection}を一覧で紹介します。</p>
        <div>${renderBookList(books)}</div>
        <h2>${genreSection}の詳細ページ</h2>
        <ul>${detailLinks}</ul>
      `,
      jsonLd: {
        "@context": "https://schema.org",
        "@type": "CollectionPage",
        name: `${genreSection}一覧 | Sharemarium`,
        description: buildGenreDescription(genreSection, books),
        url: toAbsoluteUrl(decodedPath),
      },
      extraJsonLd: [
        breadcrumbStructuredData([
          { name: "ホーム", url: `${SITE_URL}/` },
          { name: genreSection, url: toAbsoluteUrl(decodedPath) },
        ]),
        itemListStructuredData(genreSection, books, decodedPath),
      ],
      pagePath: decodedPath,
      robots: hasGenreBooks ? "index,follow" : "noindex,nofollow",
    });

    res.setHeader("Content-Type", "text/html; charset=utf-8");
    setDiagnosticsHeader(res, diagnostics);
    return res.status(200).send(html);
  }

  if (decodedPath.startsWith("/book/")) {
    const slug = decodedPath.replace("/book/", "").split("/")[0];
    const notFoundHtml = renderPage({
      title: "書籍ページが見つかりません",
      description: "指定された書籍ページは見つかりませんでした。",
      content: `<h2>書籍ページが見つかりません</h2><p>URLをご確認ください。</p>`,
      jsonLd: {
        "@context": "https://schema.org",
        "@type": "WebPage",
        name: "書籍ページが見つかりません",
        description: "指定された書籍ページは見つかりませんでした。",
        url: toAbsoluteUrl(decodedPath),
      },
      pagePath: decodedPath,
      robots: "noindex,nofollow",
    });
    res.setHeader("Content-Type", "text/html; charset=utf-8");
    setDiagnosticsHeader(res, diagnostics);
    return res.status(404).send(notFoundHtml);
  }

  let recommendedBooks = [];
  let westernBooks = [];
  let popularBooks = [];
  let recentPosts = [];
  let hasReliableData = false;

  try {
    const [recommendedR, westernR, popularR] = await Promise.all([
      fetchRakutenSection("おすすめの本", diagnostics),
      fetchRakutenSection("洋書", diagnostics),
      fetchRakutenSection("人気作品", diagnostics),
    ]);

    const [recommendedN, westernN, popularN] = ENABLE_NDL_FALLBACK
      ? await Promise.all([
          recommendedR.length
            ? Promise.resolve([])
            : fetchNdlSection("おすすめの本", diagnostics),
          westernR.length
            ? Promise.resolve([])
            : fetchNdlSection("洋書", diagnostics),
          popularR.length
            ? Promise.resolve([])
            : fetchNdlSection("人気作品", diagnostics),
        ])
      : [[], [], []];

    recommendedBooks = recommendedR.length ? recommendedR : recommendedN;
    westernBooks = westernR.length ? westernR : westernN;
    popularBooks = popularR.length ? popularR : popularN;

    if (
      recommendedBooks.length > 0 ||
      westernBooks.length > 0 ||
      popularBooks.length > 0
    ) {
      hasReliableData = true;
    }

    const rawPosts = await supabaseGet(
      "posts?select=id,book_id,rating,comment,created_at,profiles(username)&order=created_at.desc&limit=5",
    );

    if (rawPosts && rawPosts.length > 0) {
      hasReliableData = true;
      const isbnCache = new Map();
      recentPosts = await Promise.all(
        rawPosts.map(async (p) => {
          const rawBookId = p.book_id || "書籍ID未設定";
          let resolved = isbnCache.get(rawBookId);
          if (resolved === undefined) {
            resolved = await resolveBookByIsbn(rawBookId, diagnostics);
            isbnCache.set(rawBookId, resolved || null);
          }

          return {
            id: p.id,
            username: p.profiles?.username || "匿名ユーザー",
            book_title: resolved?.title || rawBookId,
            rating: p.rating,
            comment: p.comment,
            date: p.created_at
              ? new Date(p.created_at).toLocaleDateString("ja-JP")
              : "",
          };
        }),
      );
    }
  } catch (err) {
    diagnostics.supabaseIndexError =
      err instanceof Error ? err.message.slice(0, 80) : "unknown";
  }

  const timelineHtml = recentPosts
    .map(
      (p) => `
    <div class="post-card">
      <div class="post-header">
        <strong>${escapeHtml(p.username)} さん のレビュー - 『${escapeHtml(p.book_title)}』</strong>
        <span class="post-rating">★ ${p.rating}/5</span>
      </div>
      <p class="post-comment">"${escapeHtml(p.comment)}"</p>
      <small style="color:#888;">投稿日: ${escapeHtml(p.date)}</small>
    </div>
  `,
    )
    .join("");
  const faqHtml = `
            <h2>よくある質問</h2>
            <div class="post-card">
                <strong>シェアマリウムとは何ですか？</strong>
                <p>シェアマリウムは、英字でSharemariumと表記する、読書記録・本管理・レビュー共有のためのWebサービスです。</p>
            </div>
            <div class="post-card">
                <strong>Sharemariumでは何ができますか？</strong>
                <p>本の検索、レビュー投稿、読書記録の管理、タイムライン閲覧ができます。</p>
            </div>
            <div class="post-card">
                <strong>レビューは誰でも投稿できますか？</strong>
                <p>アプリ内アカウントでログインしたユーザーがレビュー投稿できます。</p>
            </div>
            <div class="post-card">
                <strong>Sharemariumの対象ジャンルは何ですか？</strong>
                <p>おすすめの本、洋書、人気作品を中心に紹介しています。</p>
            </div>
        `;
  const primaryLinksHtml = `
            <h2>主要ページ</h2>
            <ul>
                <li><a href="${SITE_URL}/genre/recommended">おすすめの本一覧</a></li>
                <li><a href="${SITE_URL}/genre/western">洋書一覧</a></li>
                <li><a href="${SITE_URL}/genre/popular">人気作品一覧</a></li>
                <li><a href="${SITE_URL}/privacy">プライバシーポリシー</a></li>
                <li><a href="${SITE_URL}/terms">利用規約</a></li>
                <li><a href="${SITE_URL}/community-guidelines">コミュニティガイドライン</a></li>
                <li><a href="${SITE_URL}/infringement-policy">権利侵害・通報ポリシー</a></li>
                <li><a href="${SITE_URL}/external-transmission">外部送信に関する公表事項</a></li>
                <li><a href="${SITE_URL}/contact">お問い合わせ</a></li>
            </ul>
        `;

  const canShowAdsOnHome =
    recommendedBooks.length > 0 ||
    westernBooks.length > 0 ||
    popularBooks.length > 0 ||
    recentPosts.length > 0;

  const html = renderPage({
    title: SITE_TITLE,
    description: TOP_DESCRIPTION,
    enableAds: canShowAdsOnHome,
    content: `
            <section>
            <h2>Sharemarium（シェアマリウム）でできること</h2>
            <p>Sharemarium（シェアマリウム）は、読んだ本、読書中の本、これから読みたい本をまとめて管理できる読書記録・本管理アプリです。読書履歴、感想、蔵書管理を一つのWeb本棚で行えます。</p>
            <h3>主な機能</h3>
            <ul>
                <li>読んだ本の登録と読書履歴の保存</li>
                <li>読みたい本の管理</li>
                <li>レビュー・読書メモの記録</li>
                <li>自分の本棚の一覧表示</li>
                <li>書籍情報の検索とお気に入り管理</li>
            </ul>
            <p>読んだ本を忘れずに記録したい方、所有している本を整理したい方、読書習慣を振り返りたい方に向けたサービスです。</p>
            <p><a href="${SITE_URL}/">Sharemariumを始める</a> / <a href="${SITE_URL}/contact">お問い合わせ</a></p>
            </section>
      <h2>おすすめの本</h2>
      <div>${renderBookList(recommendedBooks)}</div>

      <h2>洋書</h2>
      <div>${renderBookList(westernBooks)}</div>

      <h2>人気作品</h2>
      <div>${renderBookList(popularBooks)}</div>

      <h2>タイムライン (最新レビュー)</h2>
      <div>${timelineHtml.length > 0 ? timelineHtml : "<p>現在、表示できる投稿がありません。</p>"}</div>

            ${primaryLinksHtml}
      ${faqHtml}
    `,
    jsonLd: {
      "@context": "https://schema.org",
      "@type": "WebSite",
      name: SITE_NAME,
      alternateName: SITE_ALT_NAME,
      description: TOP_DESCRIPTION,
      url: `${SITE_URL}/`,
      potentialAction: {
        "@type": "SearchAction",
        target: `${SITE_URL}/?seo_preview=1&path={search_term_string}`,
        "query-input": "required name=search_term_string",
      },
    },
    extraJsonLd: [
      faqStructuredData(),
      webApplicationStructuredData(),
      ...siteNavigationStructuredData(),
    ],
    pagePath: decodedPath || "/",
    robots: hasReliableData ? "index,follow" : "noindex,nofollow",
  });

  res.setHeader("Content-Type", "text/html; charset=utf-8");
  setDiagnosticsHeader(res, diagnostics);
  return res.status(200).send(html);
};

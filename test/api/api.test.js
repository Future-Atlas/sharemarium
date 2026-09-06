const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

function responseRecorder() {
  return {
    headers: {},
    statusCode: 200,
    body: undefined,
    setHeader(name, value) {
      this.headers[name] = value;
    },
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(value) {
      this.body = value;
      return this;
    },
    send(value) {
      this.body = value;
      return this;
    },
  };
}

function loadRakuten(env = {}) {
  const { createHandler } = require("../../api/rakuten");
  return createHandler({ env });
}

test("Rakuten proxy rejects non-GET requests", async () => {
  const res = responseRecorder();
  await loadRakuten()({ method: "POST", query: {}, headers: {} }, res);
  assert.equal(res.statusCode, 405);
  assert.equal(res.body.error, "method_not_allowed");
});

test("Rakuten proxy rejects missing credentials", async () => {
  const res = responseRecorder();
  await loadRakuten()({ method: "GET", query: {}, headers: {} }, res);
  assert.equal(res.statusCode, 500);
  assert.equal(res.body.error, "rakuten_credentials_missing");
});

test("Rakuten proxy validates endpoint and pagination", async () => {
  const env = { RAKUTEN_APP_ID: "app", RAKUTEN_ACCESS_KEY: "key" };
  const invalidEndpoint = responseRecorder();
  await loadRakuten(env)(
    { method: "GET", query: { endpoint: "invalid" }, headers: {} },
    invalidEndpoint,
  );
  assert.equal(invalidEndpoint.statusCode, 400);
  assert.equal(invalidEndpoint.body.error, "invalid_endpoint");

  const invalidPage = responseRecorder();
  await loadRakuten(env)(
    { method: "GET", query: { page: "0" }, headers: {} },
    invalidPage,
  );
  assert.equal(invalidPage.statusCode, 400);
  assert.equal(invalidPage.body.error, "invalid_pagination");
});

test("Rakuten proxy returns 502 when upstream request fails", async () => {
  const handler = loadRakuten({
    RAKUTEN_APP_ID: "app",
    RAKUTEN_ACCESS_KEY: "key",
  });
  const res = responseRecorder();
  const request = require("../../api/rakuten").createHandler({
    env: { RAKUTEN_APP_ID: "app", RAKUTEN_ACCESS_KEY: "key" },
    request: async () => {
      throw new Error("timeout");
    },
  });
  assert.ok(handler);
  await request({ method: "GET", query: {}, headers: {} }, res);
  assert.equal(res.statusCode, 502);
  assert.equal(res.body.error, "rakuten_proxy_failed");
});

test("sitemap returns XML and hides non-production pages from robots", async () => {
  const previous = process.env.VERCEL_ENV;
  const previousFetch = global.fetch;
  delete process.env.VERCEL_ENV;
  global.fetch = async () => {
    throw new Error("network disabled in test");
  };
  delete require.cache[require.resolve("../../api/sitemap")];
  const sitemap = require("../../api/sitemap");
  const res = responseRecorder();
  await sitemap({}, res);
  assert.equal(res.statusCode, 200);
  assert.match(res.body, /<urlset/);
  assert.equal(res.headers["X-Robots-Tag"], "noindex, nofollow");
  assert.match(res.headers["X-Sitemap-Diagnostics"], /profiles=/);
  if (previous === undefined) delete process.env.VERCEL_ENV;
  else process.env.VERCEL_ENV = previous;
  global.fetch = previousFetch;
});

test("production sitemap includes fixed pages and public profile canonical URLs", async () => {
  const previousEnv = {
    VERCEL_ENV: process.env.VERCEL_ENV,
    SUPABASE_URL: process.env.SUPABASE_URL,
    SUPABASE_ANON_KEY: process.env.SUPABASE_ANON_KEY,
  };
  const previousFetch = global.fetch;
  process.env.VERCEL_ENV = "production";
  process.env.SUPABASE_URL = "https://example.supabase.co";
  process.env.SUPABASE_ANON_KEY = "anon-key";
  global.fetch = async () => ({
    ok: true,
    json: async () => [
      {
        id: "public-profile",
        username: "公開ユーザー",
        user_id: "reader_1",
        bio: "読書記録を公開しています。",
        read_count: 3,
        is_private: false,
        is_suspended: false,
      },
      {
        id: "private-user",
        username: "private",
        user_id: "private_user",
        bio: "private bio",
        read_count: 10,
        is_private: true,
        is_suspended: false,
      },
      {
        id: "suspended-user",
        username: "suspended",
        user_id: "suspended_user",
        bio: "suspended bio",
        read_count: 10,
        is_private: false,
        is_suspended: true,
      },
      {
        id: "empty-profile",
        username: "empty",
        user_id: "empty_user",
        bio: "",
        read_count: 0,
        is_private: false,
        is_suspended: false,
      },
    ],
  });
  delete require.cache[require.resolve("../../api/sitemap")];
  const sitemap = require("../../api/sitemap");
  const res = responseRecorder();
  await sitemap({}, res);
  assert.equal(res.statusCode, 200);
  assert.match(res.body, /<loc>https:\/\/sharemarium\.com\/<\/loc>/);
  assert.match(res.body, /<loc>https:\/\/sharemarium\.com\/privacy<\/loc>/);
  assert.match(
    res.body,
    /<loc>https:\/\/sharemarium\.com\/users\/reader_1<\/loc>/,
  );
  assert.doesNotMatch(res.body, /\/users\/private_user/);
  assert.doesNotMatch(res.body, /\/users\/suspended_user/);
  assert.doesNotMatch(res.body, /\/users\/empty_user/);
  assert.doesNotMatch(res.body, /\/user\//);
  assert.doesNotMatch(res.body, /\/profile\//);
  assert.doesNotMatch(res.body, /\/book\/konbini-ningen/);
  assert.doesNotMatch(res.body, /\/book\/midnight-library/);
  assert.doesNotMatch(res.body, /\/genre\/recommended/);
  assert.doesNotMatch(res.body, /\/genre\/western/);
  assert.doesNotMatch(res.body, /\/genre\/popular/);
  assert.equal(res.headers["X-Sitemap-Diagnostics"], "profiles=ok");
  for (const [key, value] of Object.entries(previousEnv)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  global.fetch = previousFetch;
});

test("production sitemap falls back to fixed URLs when Supabase fails", async () => {
  const previousEnv = {
    VERCEL_ENV: process.env.VERCEL_ENV,
    SUPABASE_URL: process.env.SUPABASE_URL,
    SUPABASE_ANON_KEY: process.env.SUPABASE_ANON_KEY,
  };
  const previousFetch = global.fetch;
  process.env.VERCEL_ENV = "production";
  process.env.SUPABASE_URL = "https://example.supabase.co";
  process.env.SUPABASE_ANON_KEY = "anon-key";
  global.fetch = async () => {
    throw new Error("supabase unavailable");
  };
  delete require.cache[require.resolve("../../api/sitemap")];
  const sitemap = require("../../api/sitemap");
  const res = responseRecorder();
  await sitemap({}, res);
  assert.equal(res.statusCode, 200);
  assert.match(res.body, /<loc>https:\/\/sharemarium\.com\/<\/loc>/);
  assert.doesNotMatch(res.body, /\/users\//);
  assert.doesNotMatch(res.body, /\/book\//);
  assert.doesNotMatch(res.body, /konbini-ningen|midnight-library/);
  assert.equal(res.headers["X-Sitemap-Diagnostics"], "profiles=error");
  for (const [key, value] of Object.entries(previousEnv)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  global.fetch = previousFetch;
});

test("production SEO disables sample fallback by default", async () => {
  process.env.VERCEL_ENV = "production";
  delete process.env.SEO_ENABLE_SAMPLE_BOOK_FALLBACK;
  delete require.cache[require.resolve("../../api/seo")];
  const seo = require("../../api/seo");
  const res = responseRecorder();
  await seo({ query: {} }, res);
  assert.equal(res.statusCode, 200);
  assert.doesNotMatch(
    res.body,
    /コンビニ人間|The Midnight Library|Atomic Habits/,
  );
  delete process.env.VERCEL_ENV;
  delete process.env.SEO_ENABLE_SAMPLE_BOOK_FALLBACK;
});

test("SEO handler renders the public home page", async () => {
  process.env.VERCEL_ENV = "preview";
  delete process.env.SUPABASE_URL;
  delete process.env.SUPABASE_ANON_KEY;
  delete require.cache[require.resolve("../../api/seo")];
  const seo = require("../../api/seo");
  const res = responseRecorder();
  await seo({ query: {} }, res);
  assert.equal(res.statusCode, 200);
  assert.match(res.body, /Sharemarium/);
  assert.match(res.headers["Content-Type"], /text\/html/);
});

test("SEO handler returns noindex 404 for a missing profile", async () => {
  process.env.VERCEL_ENV = "production";
  process.env.SUPABASE_URL = "https://supabase.example";
  process.env.SUPABASE_ANON_KEY = "public-key";
  const originalFetch = global.fetch;
  let requestedUrl = "";
  global.fetch = async (url) => {
    requestedUrl = String(url);
    return new Response("[]", {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  };
  delete require.cache[require.resolve("../../api/seo")];
  const seo = require("../../api/seo");
  const res = responseRecorder();
  await seo({ query: { path: "/users/missing-user" } }, res);
  global.fetch = originalFetch;
  assert.equal(res.statusCode, 404);
  assert.match(requestedUrl, /profiles\?user_id=eq\.missing-user/);
  assert.match(res.body, /ユーザーが見つかりません/);
  assert.match(res.body, /noindex/);
});

test("SEO handler returns noindex 404 for a private profile", async () => {
  process.env.VERCEL_ENV = "production";
  process.env.SUPABASE_URL = "https://supabase.example";
  process.env.SUPABASE_ANON_KEY = "public-key";
  const originalFetch = global.fetch;
  global.fetch = async () =>
    new Response(
      JSON.stringify([
        { id: "private-user", username: "private", is_private: true },
      ]),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  delete require.cache[require.resolve("../../api/seo")];
  const seo = require("../../api/seo");
  const res = responseRecorder();
  await seo({ query: { path: "/users/private-user" } }, res);
  global.fetch = originalFetch;
  assert.equal(res.statusCode, 404);
  assert.match(res.body, /プロフィールは非公開です/);
  assert.match(res.body, /noindex/);
});

test("web HTML loads AdSense only on approved content routes with substantive content", () => {
  const html = fs.readFileSync(
    path.join(__dirname, "../../web/index.html"),
    "utf8",
  );

  assert.match(html, /allowedPath/);
  assert.match(html, /const allowedPath = \/\^\\\/\$\//);
  assert.match(html, /hasMeaningfulContent/);
  assert.match(html, /__sharemariumAdsAllowed !== false/);
  assert.match(html, /window\.location\.pathname/);
  assert.match(html, /DOMContentLoaded/);
  assert.match(html, /MutationObserver/);
  assert.match(html, /setTimeout\(scheduleAdCheck, 3000\)/);
  assert.match(html, /popstate|pushState|replaceState/);
  assert.doesNotMatch(html, /if \(!shouldLoadAds\(\)\) \{\s*return;\s*\}/);
});

test("genre SEO pages never enable AdSense even when books are available", async () => {
  process.env.VERCEL_ENV = "production";
  process.env.RAKUTEN_APP_ID = "app";
  process.env.RAKUTEN_ACCESS_KEY = "key";
  process.env.RAKUTEN_REFERER = "https://sharemarium.com";

  const requestModulePath = require.resolve("../../api/_rakuten_request");
  const originalRequestModule = require.cache[requestModulePath];
  require.cache[requestModulePath] = {
    id: requestModulePath,
    filename: requestModulePath,
    loaded: true,
    exports: {
      requestRakuten: async () => ({
        ok: true,
        status: 200,
        text: async () =>
          JSON.stringify({
            Items: [
              {
                Item: {
                  title: "Sharemarium Test Book",
                  author: "Test Author",
                  itemCaption: "A test book for SEO rendering.",
                },
              },
            ],
          }),
      }),
    },
  };

  delete require.cache[require.resolve("../../api/seo")];
  const seo = require("../../api/seo");

  for (const pathName of ["/genre/recommended", "/genre/western", "/genre/popular"]) {
    const res = responseRecorder();
    await seo({ query: { path: pathName } }, res);
    assert.equal(res.statusCode, 200);
    assert.match(res.body, /index,follow/);
    assert.doesNotMatch(res.body, /pagead2\.googlesyndication\.com/);
    assert.doesNotMatch(res.body, /__sharemariumAdsAllowed = true/);
  }

  if (originalRequestModule) {
    require.cache[requestModulePath] = originalRequestModule;
  } else {
    delete require.cache[requestModulePath];
  }
  delete require.cache[require.resolve("../../api/seo")];
  delete process.env.VERCEL_ENV;
  delete process.env.RAKUTEN_APP_ID;
  delete process.env.RAKUTEN_ACCESS_KEY;
  delete process.env.RAKUTEN_REFERER;
});

test("genre SEO pages are noindex when no books are available", async () => {
  process.env.VERCEL_ENV = "production";
  delete process.env.RAKUTEN_APP_ID;
  delete process.env.RAKUTEN_ACCESS_KEY;
  delete require.cache[require.resolve("../../api/seo")];
  const seo = require("../../api/seo");

  const res = responseRecorder();
  await seo({ query: { path: "/genre/recommended" } }, res);

  assert.equal(res.statusCode, 200);
  assert.match(res.body, /noindex,nofollow/);
  assert.doesNotMatch(res.body, /pagead2\.googlesyndication\.com/);
  delete process.env.VERCEL_ENV;
});

test("Flutter placeholder ad banner is not rendered", () => {
  const screen = fs.readFileSync(
    path.join(__dirname, "../../lib/screens/book_list_screen.dart"),
    "utf8",
  );
  const bannerPath = path.join(__dirname, "../../lib/widgets/ad_banner.dart");

  assert.doesNotMatch(screen, /AdBanner|ad_banner/);
  assert.equal(fs.existsSync(bannerPath), false);
});

test("Flutter book routes do not resolve legacy sample slugs", () => {
  const bookListScreen = fs.readFileSync(
    path.join(__dirname, "../../lib/screens/book_list_screen.dart"),
    "utf8",
  );
  const main = fs.readFileSync(
    path.join(__dirname, "../../lib/main.dart"),
    "utf8",
  );
  const productionSource = `${bookListScreen}\n${main}`;
  const legacySampleSlugs = [
    "konbini-ningen",
    "fune-wo-amu",
    "midnight-library",
    "atomic-habits",
    "baton-wa-watasareta",
    "nanji-hoshi-no-gotoku",
  ];

  assert.doesNotMatch(productionSource, /_titleForBookSlug|initialBookSlug/);
  for (const slug of legacySampleSlugs) {
    assert.doesNotMatch(productionSource, new RegExp(slug));
  }
});

test("AdSense crawlers use the SEO HTML routing", () => {
  const vercel = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../../vercel.json"), "utf8"),
  );
  const crawlerRoutes = vercel.routes.filter((route) =>
    route.has?.some((condition) => condition.key === "user-agent"),
  );

  assert.equal(crawlerRoutes.length, 2);
  for (const route of crawlerRoutes) {
    const userAgentPattern = route.has[0].value;
    assert.match(userAgentPattern, /\[Gg\]ooglebot/);
    assert.match(userAgentPattern, /Mediapartners-Google/);
    assert.match(userAgentPattern, /Google-Display-Ads-Bot/);
  }
});

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const {
  MIN_SUBSTANTIVE_REVIEW_CHARS,
  hasSubstantivePublicReview,
  fetchHomeAdEligibility,
} = require("../../api/_home_ad_eligibility");
const { suppressAdsInRenderedHtml } = require("../../api/seo-home")._test;

test("home ads require a non-spoiler review with at least 80 characters", () => {
  assert.equal(MIN_SUBSTANTIVE_REVIEW_CHARS, 80);
  assert.equal(
    hasSubstantivePublicReview([
      { comment: "短いレビューです。", is_spoiler: false },
    ]),
    false,
  );
  assert.equal(
    hasSubstantivePublicReview([
      { comment: "あ".repeat(79), is_spoiler: false },
    ]),
    false,
  );
  assert.equal(
    hasSubstantivePublicReview([
      { comment: "あ".repeat(80), is_spoiler: false },
    ]),
    true,
  );
  assert.equal(
    hasSubstantivePublicReview([
      { comment: "あ".repeat(120), is_spoiler: true },
    ]),
    false,
  );
});

test("home ad eligibility is fail-closed without public original content", async () => {
  const baseEnv = {
    SUPABASE_URL: "https://example.supabase.co",
    SUPABASE_ANON_KEY: "anon-key",
  };

  const noReviews = await fetchHomeAdEligibility({
    env: baseEnv,
    request: async () => ({
      ok: true,
      status: 200,
      json: async () => [],
    }),
  });
  assert.deepEqual(noReviews, { eligible: false, diagnostic: "ok" });

  const shortReviews = await fetchHomeAdEligibility({
    env: baseEnv,
    request: async (url) => {
      const requested = new URL(String(url));
      assert.equal(requested.searchParams.get("is_spoiler"), "is.false");
      return {
        ok: true,
        status: 200,
        json: async () => [
          { id: "post-1", comment: "短いレビュー", is_spoiler: false },
        ],
      };
    },
  });
  assert.deepEqual(shortReviews, { eligible: false, diagnostic: "ok" });

  const substantiveReview = await fetchHomeAdEligibility({
    env: baseEnv,
    request: async () => ({
      ok: true,
      status: 200,
      json: async () => [
        { id: "post-2", comment: "読書体験についての独自レビュー".repeat(8), is_spoiler: false },
      ],
    }),
  });
  assert.deepEqual(substantiveReview, { eligible: true, diagnostic: "ok" });
});

test("crawler home renderer can suppress an otherwise enabled AdSense loader", () => {
  const rendered = `
    <script>window.__sharemariumAdsAllowed = true;</script>
    <script>
      (function() {
        if (!window.__sharemariumAdsAllowed) return;
        const script = document.createElement('script');
        script.src = 'https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js?client=ca-pub-test';
        document.head.appendChild(script);
      })();
    </script>
    <main>Sharemarium</main>`;

  const suppressed = suppressAdsInRenderedHtml(rendered);
  assert.match(suppressed, /__sharemariumAdsAllowed = false/);
  assert.doesNotMatch(suppressed, /pagead2\.googlesyndication\.com/);
});

test("browser AdSense loader waits for the same home content eligibility", () => {
  const html = fs.readFileSync(
    path.join(__dirname, "../../web/index.html"),
    "utf8",
  );

  assert.match(html, /fetch\("\/api\/home-ad-eligibility"/);
  assert.match(html, /homeContentState !== "eligible"/);
  assert.match(html, /homeContentState = "not_eligible"/);
  assert.match(html, /Fail closed when the independent-content check is unavailable/);
});

test("crawler and SEO preview home requests pass through seo-router", () => {
  const vercel = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../../vercel.json"), "utf8"),
  );
  const rootCrawler = vercel.routes.find(
    (route) => route.src === "/" && route.has?.some((entry) => entry.key === "user-agent"),
  );
  const preview = vercel.routes.find(
    (route) => route.src === "/(.*)" && route.has?.some((entry) => entry.key === "seo_preview"),
  );

  assert.equal(rootCrawler?.dest, "/api/seo-router?path=/");
  assert.equal(preview?.dest, "/api/seo-router?path=/$1");

  const router = fs.readFileSync(
    path.join(__dirname, "../../api/seo-router.js"),
    "utf8",
  );
  assert.match(router, /normalizedPath === "\/"/);
  assert.match(router, /return seoHome/);
});

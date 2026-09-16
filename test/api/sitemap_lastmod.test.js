const assert = require("node:assert/strict");
const test = require("node:test");

function responseRecorder() {
  return {
    headers: {},
    statusCode: 200,
    body: "",
    setHeader(name, value) {
      this.headers[name] = value;
    },
    status(code) {
      this.statusCode = code;
      return this;
    },
    send(value) {
      this.body = String(value);
      return this;
    },
  };
}

function restoreEnv(name, value) {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}

test("sitemap omits fixed-page lastmod when SEO_LASTMOD is not configured", async () => {
  const previous = {
    SEO_LASTMOD: process.env.SEO_LASTMOD,
    SUPABASE_URL: process.env.SUPABASE_URL,
    SUPABASE_ANON_KEY: process.env.SUPABASE_ANON_KEY,
  };
  delete process.env.SEO_LASTMOD;
  delete process.env.SUPABASE_URL;
  delete process.env.SUPABASE_ANON_KEY;
  delete require.cache[require.resolve("../../api/sitemap")];

  const sitemap = require("../../api/sitemap");
  const res = responseRecorder();
  await sitemap({}, res);

  assert.equal(res.statusCode, 200);
  assert.match(res.body, /<loc>https:\/\/sharemarium\.com\/<\/loc>/);
  assert.doesNotMatch(res.body, /<lastmod>/);
  assert.doesNotMatch(res.body, /2026-09-02/);

  for (const [name, value] of Object.entries(previous)) restoreEnv(name, value);
  delete require.cache[require.resolve("../../api/sitemap")];
});

test("sitemap emits an explicitly configured valid fixed-page lastmod", async () => {
  const previous = {
    SEO_LASTMOD: process.env.SEO_LASTMOD,
    SUPABASE_URL: process.env.SUPABASE_URL,
    SUPABASE_ANON_KEY: process.env.SUPABASE_ANON_KEY,
  };
  process.env.SEO_LASTMOD = "2026-09-16";
  delete process.env.SUPABASE_URL;
  delete process.env.SUPABASE_ANON_KEY;
  delete require.cache[require.resolve("../../api/sitemap")];

  const sitemap = require("../../api/sitemap");
  const res = responseRecorder();
  await sitemap({}, res);

  assert.match(res.body, /<lastmod>2026-09-16<\/lastmod>/);

  for (const [name, value] of Object.entries(previous)) restoreEnv(name, value);
  delete require.cache[require.resolve("../../api/sitemap")];
});

test("invalid SEO_LASTMOD values are ignored", () => {
  delete require.cache[require.resolve("../../api/sitemap")];
  const { normalizedLastmod } = require("../../api/sitemap")._test;

  assert.equal(normalizedLastmod("2026-09-16"), "2026-09-16");
  assert.equal(normalizedLastmod("2026-02-30"), undefined);
  assert.equal(normalizedLastmod("September 16, 2026"), undefined);
  assert.equal(normalizedLastmod(""), undefined);
});

test("dynamic review URLs keep their real created_at lastmod", async () => {
  const previous = {
    SEO_LASTMOD: process.env.SEO_LASTMOD,
    SUPABASE_URL: process.env.SUPABASE_URL,
    SUPABASE_ANON_KEY: process.env.SUPABASE_ANON_KEY,
  };
  const previousFetch = global.fetch;
  delete process.env.SEO_LASTMOD;
  process.env.SUPABASE_URL = "https://example.supabase.co";
  process.env.SUPABASE_ANON_KEY = "anon-key";
  global.fetch = async (url) => {
    const pathname = new URL(String(url)).pathname;
    if (pathname.endsWith("/profiles")) {
      return { ok: true, json: async () => [] };
    }
    if (pathname.endsWith("/posts")) {
      return {
        ok: true,
        json: async () => [
          {
            id: "11111111-1111-4111-8111-111111111111",
            comment: "十分な長さの公開レビューです。".repeat(10),
            created_at: "2026-09-15T12:34:56.000Z",
            is_spoiler: false,
          },
        ],
      };
    }
    throw new Error(`unexpected URL: ${url}`);
  };
  delete require.cache[require.resolve("../../api/sitemap")];

  const sitemap = require("../../api/sitemap");
  const res = responseRecorder();
  await sitemap({}, res);

  assert.match(res.body, /\/posts\/11111111-1111-4111-8111-111111111111/);
  assert.match(res.body, /<lastmod>2026-09-15<\/lastmod>/);
  assert.doesNotMatch(res.body, /<lastmod>2026-09-02<\/lastmod>/);

  global.fetch = previousFetch;
  for (const [name, value] of Object.entries(previous)) restoreEnv(name, value);
  delete require.cache[require.resolve("../../api/sitemap")];
});

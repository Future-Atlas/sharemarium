const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const POST_A = "11111111-1111-4111-8111-111111111111";
const POST_B = "22222222-2222-4222-8222-222222222222";
const PROFILE_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const PROFILE_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

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
    send(value) {
      this.body = value;
      return this;
    },
  };
}

function setSupabaseEnv() {
  process.env.SUPABASE_URL = "https://example.supabase.co";
  process.env.SUPABASE_ANON_KEY = "anon-key";
}

function restoreEnv(previous) {
  for (const [key, value] of Object.entries(previous)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
}

test("posts index renders public reviews with reply counts and detail links", async () => {
  const previousEnv = {
    SUPABASE_URL: process.env.SUPABASE_URL,
    SUPABASE_ANON_KEY: process.env.SUPABASE_ANON_KEY,
  };
  const previousFetch = global.fetch;
  setSupabaseEnv();
  const requestedUrls = [];

  global.fetch = async (url) => {
    const requested = String(url);
    requestedUrls.push(requested);
    if (requested.includes("/rest/v1/posts")) {
      return {
        ok: true,
        status: 200,
        json: async () => [
          {
            id: POST_A,
            profile_id: PROFILE_A,
            book_id: "9784000000000",
            book_title: "テスト書籍A",
            rating: 4,
            comment: "この作品は登場人物の変化が丁寧で、後半の展開が特に印象的でした。",
            created_at: "2026-09-08T01:23:45Z",
            is_spoiler: false,
          },
          {
            id: POST_B,
            profile_id: PROFILE_B,
            book_id: "9784000000001",
            book_title: "テスト書籍B",
            rating: 5,
            comment: "結末に関する感想です。",
            created_at: "2026-09-07T01:23:45Z",
            is_spoiler: true,
          },
        ],
      };
    }
    if (requested.includes("/rest/v1/profiles")) {
      return {
        ok: true,
        status: 200,
        json: async () => [
          { id: PROFILE_A, username: "読書好きA", user_id: "reader_a" },
          { id: PROFILE_B, username: "読書好きB", user_id: "reader_b" },
        ],
      };
    }
    if (requested.includes("/rest/v1/post_replies")) {
      return {
        ok: true,
        status: 200,
        json: async () => [
          { post_id: POST_A },
          { post_id: POST_A },
          { post_id: POST_B },
        ],
      };
    }
    throw new Error(`unexpected URL: ${requested}`);
  };

  delete require.cache[require.resolve("../../api/posts-seo")];
  const handler = require("../../api/posts-seo");
  const res = responseRecorder();
  await handler({}, res);

  assert.equal(res.statusCode, 200);
  const postsRequest = requestedUrls.find((url) => url.includes("/rest/v1/posts"));
  const profilesRequest = requestedUrls.find((url) =>
    url.includes("/rest/v1/profiles"),
  );
  assert.ok(postsRequest);
  assert.ok(profilesRequest);
  assert.equal(
    new URL(postsRequest).searchParams.get("select"),
    "id,profile_id,book_id,book_title,rating,comment,created_at,is_spoiler",
  );
  assert.equal(
    new URL(profilesRequest).searchParams.get("select"),
    "id,username,user_id",
  );
  assert.match(res.body, /<h1>投稿一覧<\/h1>/);
  assert.match(res.body, new RegExp(`href="/posts/${POST_A}"`));
  assert.match(res.body, new RegExp(`href="/posts/${POST_B}"`));
  assert.match(res.body, /2件の返信/);
  assert.match(res.body, /1件の返信/);
  assert.match(res.body, /読書好きA/);
  assert.match(res.body, /ネタバレを含む投稿です/);
  assert.match(res.body, /<meta name="robots" content="index,follow">/);
  assert.equal(res.headers["X-Robots-Tag"], undefined);
  assert.equal(res.headers["X-Posts-Diagnostics"], "ok");

  global.fetch = previousFetch;
  restoreEnv(previousEnv);
  delete require.cache[require.resolve("../../api/posts-seo")];
});

test("posts index reports a safe diagnostic code when the posts query fails", async () => {
  const previousEnv = {
    SUPABASE_URL: process.env.SUPABASE_URL,
    SUPABASE_ANON_KEY: process.env.SUPABASE_ANON_KEY,
  };
  const previousFetch = global.fetch;
  setSupabaseEnv();

  global.fetch = async () => ({
    ok: false,
    status: 400,
    json: async () => ({}),
  });

  delete require.cache[require.resolve("../../api/posts-seo")];
  const handler = require("../../api/posts-seo");
  const res = responseRecorder();
  await handler({}, res);

  assert.equal(res.statusCode, 503);
  assert.equal(res.headers["X-Posts-Diagnostics"], "posts_400");
  assert.equal(res.headers["Retry-After"], "60");

  global.fetch = previousFetch;
  restoreEnv(previousEnv);
  delete require.cache[require.resolve("../../api/posts-seo")];
});

test("reply-count failure does not make the public posts index unavailable", async () => {
  const previousEnv = {
    SUPABASE_URL: process.env.SUPABASE_URL,
    SUPABASE_ANON_KEY: process.env.SUPABASE_ANON_KEY,
  };
  const previousFetch = global.fetch;
  setSupabaseEnv();

  global.fetch = async (url) => {
    const requested = String(url);
    if (requested.includes("/rest/v1/posts")) {
      return {
        ok: true,
        status: 200,
        json: async () => [
          {
            id: POST_A,
            profile_id: PROFILE_A,
            book_id: "9784000000000",
            book_title: "テスト書籍A",
            rating: 4,
            comment: "公開投稿です。",
            created_at: "2026-09-08T01:23:45Z",
            is_spoiler: false,
          },
        ],
      };
    }
    if (requested.includes("/rest/v1/profiles")) {
      return {
        ok: true,
        status: 200,
        json: async () => [
          { id: PROFILE_A, username: "読書好きA", user_id: "reader_a" },
        ],
      };
    }
    if (requested.includes("/rest/v1/post_replies")) {
      return { ok: false, status: 403, json: async () => ({}) };
    }
    throw new Error(`unexpected URL: ${requested}`);
  };

  delete require.cache[require.resolve("../../api/posts-seo")];
  const handler = require("../../api/posts-seo");
  const res = responseRecorder();
  await handler({}, res);

  assert.equal(res.statusCode, 200);
  assert.match(res.body, /公開投稿です/);
  assert.match(res.body, /返信数を取得できません/);
  assert.equal(
    res.headers["X-Posts-Diagnostics"],
    "posts=ok;profiles=ok;replies=replies_403",
  );

  global.fetch = previousFetch;
  restoreEnv(previousEnv);
  delete require.cache[require.resolve("../../api/posts-seo")];
});

test("empty posts index remains accessible but is noindex", async () => {
  const previousEnv = {
    SUPABASE_URL: process.env.SUPABASE_URL,
    SUPABASE_ANON_KEY: process.env.SUPABASE_ANON_KEY,
  };
  const previousFetch = global.fetch;
  setSupabaseEnv();

  global.fetch = async (url) => {
    const requested = String(url);
    if (requested.includes("/rest/v1/posts")) {
      return { ok: true, status: 200, json: async () => [] };
    }
    throw new Error(`unexpected URL: ${requested}`);
  };

  delete require.cache[require.resolve("../../api/posts-seo")];
  const handler = require("../../api/posts-seo");
  const res = responseRecorder();
  await handler({}, res);

  assert.equal(res.statusCode, 200);
  assert.match(res.body, /現在、表示できる投稿がありません/);
  assert.match(res.body, /<meta name="robots" content="noindex,follow">/);
  assert.equal(res.headers["X-Robots-Tag"], "noindex, follow");
  assert.equal(res.headers["X-Posts-Diagnostics"], "ok");

  global.fetch = previousFetch;
  restoreEnv(previousEnv);
  delete require.cache[require.resolve("../../api/posts-seo")];
});

test("Vercel routes /posts to the posts index renderer", () => {
  const vercel = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../../vercel.json"), "utf8"),
  );
  const postsRoute = vercel.routes.find((route) => route.src === "/posts$");
  const detailRoute = vercel.routes.find(
    (route) => route.src === "/posts/([^/]+)",
  );

  assert.ok(postsRoute);
  assert.equal(postsRoute.dest, "/api/posts-seo");
  assert.ok(detailRoute);
  assert.equal(detailRoute.dest, "/api/post-seo?post_id=$1");
});

test("sitemap contains the posts index", async () => {
  const previousEnv = {
    VERCEL_ENV: process.env.VERCEL_ENV,
    SUPABASE_URL: process.env.SUPABASE_URL,
    SUPABASE_ANON_KEY: process.env.SUPABASE_ANON_KEY,
  };
  const previousFetch = global.fetch;
  process.env.VERCEL_ENV = "production";
  setSupabaseEnv();

  global.fetch = async (url) => {
    const requested = String(url);
    if (requested.includes("/rest/v1/profiles")) {
      return { ok: true, status: 200, json: async () => [] };
    }
    if (requested.includes("/rest/v1/posts")) {
      return { ok: true, status: 200, json: async () => [] };
    }
    throw new Error(`unexpected URL: ${requested}`);
  };

  delete require.cache[require.resolve("../../api/sitemap")];
  const sitemap = require("../../api/sitemap");
  const res = responseRecorder();
  await sitemap({}, res);

  assert.equal(res.statusCode, 200);
  assert.match(res.body, /<loc>https:\/\/sharemarium\.com\/posts<\/loc>/);

  global.fetch = previousFetch;
  restoreEnv(previousEnv);
  delete require.cache[require.resolve("../../api/sitemap")];
});

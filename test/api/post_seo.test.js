const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const POST_ID = "11111111-1111-4111-8111-111111111111";
const SHORT_POST_ID = "22222222-2222-4222-8222-222222222222";
const SPOILER_POST_ID = "33333333-3333-4333-8333-333333333333";

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

test("review permalink rejects malformed post ids without querying Supabase", async () => {
  const previousEnv = {
    SUPABASE_URL: process.env.SUPABASE_URL,
    SUPABASE_ANON_KEY: process.env.SUPABASE_ANON_KEY,
  };
  const previousFetch = global.fetch;
  setSupabaseEnv();
  let fetched = false;
  global.fetch = async () => {
    fetched = true;
    throw new Error("unexpected fetch");
  };
  delete require.cache[require.resolve("../../api/post-seo")];
  const handler = require("../../api/post-seo");
  const res = responseRecorder();

  await handler({ query: { post_id: "not-a-post-id" } }, res);

  assert.equal(res.statusCode, 404);
  assert.equal(fetched, false);
  assert.equal(res.headers["X-Robots-Tag"], "noindex, nofollow");
  assert.match(res.body, /投稿が見つかりません/);

  global.fetch = previousFetch;
  restoreEnv(previousEnv);
  delete require.cache[require.resolve("../../api/post-seo")];
});

test("review permalink renders a substantial public review as indexable HTML", async () => {
  const previousEnv = {
    SUPABASE_URL: process.env.SUPABASE_URL,
    SUPABASE_ANON_KEY: process.env.SUPABASE_ANON_KEY,
  };
  const previousFetch = global.fetch;
  setSupabaseEnv();
  const longComment =
    "物語の前半では主人公の選択に共感できない場面もありましたが、後半でその理由が丁寧に回収されていく構成が印象的でした。登場人物同士の距離感の変化も自然で、読み終えた後にもう一度序盤を振り返りたくなる作品です。";
  let requestedUrl = "";
  global.fetch = async (url) => {
    requestedUrl = String(url);
    return {
      ok: true,
      status: 200,
      json: async () => [
        {
          id: POST_ID,
          profile_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          book_id: "9784000000000",
          book_title: "テスト書籍",
          rating: 4.5,
          comment: longComment,
          created_at: "2026-09-08T01:23:45Z",
          is_spoiler: false,
          profiles: { username: "読書好き", user_id: "reader_1" },
        },
      ],
    };
  };
  delete require.cache[require.resolve("../../api/post-seo")];
  const handler = require("../../api/post-seo");
  const res = responseRecorder();

  await handler({ query: { post_id: POST_ID } }, res);

  assert.equal(res.statusCode, 200);
  assert.match(requestedUrl, /rest\/v1\/posts/);
  assert.match(requestedUrl, new RegExp(`id=eq\\.${POST_ID}`));
  assert.match(res.body, /<meta name="robots" content="index,follow">/);
  assert.match(
    res.body,
    new RegExp(`https://sharemarium\\.com/posts/${POST_ID}`),
  );
  assert.match(res.body, /『テスト書籍』のレビュー/);
  assert.match(res.body, /読書好き/);
  assert.match(res.body, /Review/);
  assert.equal(res.headers["X-Robots-Tag"], undefined);

  global.fetch = previousFetch;
  restoreEnv(previousEnv);
  delete require.cache[require.resolve("../../api/post-seo")];
});

test("short and spoiler reviews remain readable but are noindex", async () => {
  const previousEnv = {
    SUPABASE_URL: process.env.SUPABASE_URL,
    SUPABASE_ANON_KEY: process.env.SUPABASE_ANON_KEY,
  };
  const previousFetch = global.fetch;
  setSupabaseEnv();
  const cases = [
    { id: SHORT_POST_ID, comment: "面白かったです。", is_spoiler: false },
    {
      id: SPOILER_POST_ID,
      comment:
        "物語の核心に触れる内容を含むため、検索結果から本文が直接見えないようにするための十分に長いネタバレレビュー本文です。登場人物の結末について具体的に記述しています。",
      is_spoiler: true,
    },
  ];

  for (const current of cases) {
    global.fetch = async () => ({
      ok: true,
      status: 200,
      json: async () => [
        {
          id: current.id,
          profile_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          book_id: "9784000000000",
          book_title: "テスト書籍",
          rating: 5,
          comment: current.comment,
          created_at: "2026-09-08T01:23:45Z",
          is_spoiler: current.is_spoiler,
          profiles: { username: "読書好き", user_id: "reader_1" },
        },
      ],
    });
    delete require.cache[require.resolve("../../api/post-seo")];
    const handler = require("../../api/post-seo");
    const res = responseRecorder();
    await handler({ query: { post_id: current.id } }, res);

    assert.equal(res.statusCode, 200);
    assert.match(res.body, /<meta name="robots" content="noindex,follow">/);
    assert.equal(res.headers["X-Robots-Tag"], "noindex, follow");
  }

  global.fetch = previousFetch;
  restoreEnv(previousEnv);
  delete require.cache[require.resolve("../../api/post-seo")];
});

test("production sitemap includes only substantial non-spoiler review permalinks", async () => {
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
      return {
        ok: true,
        status: 200,
        json: async () => [
          {
            id: POST_ID,
            comment:
              "このレビューは検索可能な個別ページとして扱うために十分な長さがあります。作品の構成や登場人物の変化について具体的な感想を書き、読書を検討している人にも内容が伝わる文章にしています。",
            created_at: "2026-09-08T01:23:45Z",
            is_spoiler: false,
          },
          {
            id: SHORT_POST_ID,
            comment: "良かったです。",
            created_at: "2026-09-08T01:23:45Z",
            is_spoiler: false,
          },
          {
            id: SPOILER_POST_ID,
            comment:
              "十分な長さがあってもネタバレ投稿は検索結果に本文を出さない方針なので、サイトマップには含めないことを確認するためのテスト文章です。",
            created_at: "2026-09-08T01:23:45Z",
            is_spoiler: true,
          },
        ],
      };
    }
    throw new Error(`unexpected URL: ${requested}`);
  };

  delete require.cache[require.resolve("../../api/sitemap")];
  const sitemap = require("../../api/sitemap");
  const res = responseRecorder();
  await sitemap({}, res);

  assert.equal(res.statusCode, 200);
  assert.match(res.body, new RegExp(`/posts/${POST_ID}`));
  assert.doesNotMatch(res.body, new RegExp(`/posts/${SHORT_POST_ID}`));
  assert.doesNotMatch(res.body, new RegExp(`/posts/${SPOILER_POST_ID}`));
  assert.equal(res.headers["X-Sitemap-Post-Diagnostics"], "posts=ok");

  global.fetch = previousFetch;
  restoreEnv(previousEnv);
  delete require.cache[require.resolve("../../api/sitemap")];
});

test("Vercel routes public review permalinks to the dedicated renderer", () => {
  const vercel = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../../vercel.json"), "utf8"),
  );
  const postRoute = vercel.routes.find(
    (route) => route.src === "/posts/([^/]+)",
  );

  assert.ok(postRoute);
  assert.equal(postRoute.dest, "/api/post-seo?post_id=$1");
});

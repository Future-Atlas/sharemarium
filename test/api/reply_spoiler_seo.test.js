const assert = require("node:assert/strict");
const test = require("node:test");

const POST_ID = "11111111-1111-4111-8111-111111111111";

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

function restoreEnv(previous) {
  for (const [key, value] of Object.entries(previous)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
}

test("public post page renders replies but never embeds spoiler reply bodies", async () => {
  const previousEnv = {
    SUPABASE_URL: process.env.SUPABASE_URL,
    SUPABASE_ANON_KEY: process.env.SUPABASE_ANON_KEY,
  };
  const previousFetch = global.fetch;
  process.env.SUPABASE_URL = "https://example.supabase.co";
  process.env.SUPABASE_ANON_KEY = "anon-key";

  const safeReply = "作品のテーマについて私も同じように感じました。";
  const spoilerReply = "犯人は最後に登場する人物です。この本文はHTMLに含まれてはいけません。";

  global.fetch = async (url) => {
    const requested = String(url);
    if (requested.includes("/rest/v1/post_replies")) {
      return {
        ok: true,
        status: 200,
        json: async () => [
          {
            id: 1,
            post_id: POST_ID,
            profile_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            parent_reply_id: null,
            message: safeReply,
            has_spoiler: false,
            created_at: "2026-09-08T02:00:00Z",
            profiles: { username: "返信ユーザー", user_id: "reply_reader" },
          },
          {
            id: 2,
            post_id: POST_ID,
            profile_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            parent_reply_id: 1,
            message: spoilerReply,
            has_spoiler: true,
            created_at: "2026-09-08T02:05:00Z",
            profiles: { username: "ネタバレ返信ユーザー", user_id: "spoiler_reader" },
          },
        ],
      };
    }
    if (requested.includes("/rest/v1/posts")) {
      return {
        ok: true,
        status: 200,
        json: async () => [
          {
            id: POST_ID,
            profile_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            book_id: "9784000000000",
            book_title: "テスト書籍",
            rating: 4,
            comment:
              "作品全体を通して登場人物の考え方が変化していく過程が丁寧に描かれており、読み終わった後にも考えさせられる部分が多いレビュー対象作品でした。",
            created_at: "2026-09-08T01:23:45Z",
            is_spoiler: false,
            profiles: { username: "投稿ユーザー", user_id: "reader_1" },
          },
        ],
      };
    }
    throw new Error(`unexpected URL: ${requested}`);
  };

  delete require.cache[require.resolve("../../api/post-seo")];
  const handler = require("../../api/post-seo");
  const res = responseRecorder();
  await handler({ query: { post_id: POST_ID } }, res);

  assert.equal(res.statusCode, 200);
  assert.equal(res.headers["X-Reply-Diagnostics"], "replies=ok");
  assert.match(res.body, /返信 2件/);
  assert.match(res.body, new RegExp(safeReply));
  assert.match(res.body, /ネタバレを含む返信です/);
  assert.match(res.body, /ネタバレあり/);
  assert.doesNotMatch(res.body, new RegExp(spoilerReply));

  global.fetch = previousFetch;
  restoreEnv(previousEnv);
  delete require.cache[require.resolve("../../api/post-seo")];
});

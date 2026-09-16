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
  };
}

test("AdSense runtime is isolated from non-content SPA routes and ad-free users", () => {
  const html = fs.readFileSync(
    path.join(__dirname, "../../web/index.html"),
    "utf8",
  );

  assert.match(html, /const allowedPath = \/\^\\\/\$\//);
  assert.match(html, /function isAdsRouteAllowed\(\)/);
  assert.match(html, /function reloadIfAdsAreNoLongerAllowed\(\)/);
  assert.match(html, /currentSupabaseAccessToken/);
  assert.match(html, /\/api\/ad-entitlement/);
  assert.match(html, /entitlementState = "ad_free"/);
  assert.match(html, /accessToken && entitlementState !== "ads_allowed"/);
  assert.match(html, /window\.location\.replace\(window\.location\.href\)/);
  assert.match(html, /if \(reloadIfAdsAreNoLongerAllowed\(\)\) return/);
  assert.match(html, /popstate/);
  assert.match(html, /history\.pushState/);
  assert.match(html, /history\.replaceState/);
});

test("ad entitlement endpoint treats anonymous visitors as ad-supported", async () => {
  delete require.cache[require.resolve("../../api/ad-entitlement")];
  const handler = require("../../api/ad-entitlement");
  const res = responseRecorder();
  await handler({ method: "GET", headers: {} }, res);

  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { authenticated: false, adFree: false });
  assert.equal(res.headers["Cache-Control"], "no-store");
});

test("ad entitlement endpoint forwards the user token to the Supabase RPC", async () => {
  const previousEnv = {
    SUPABASE_URL: process.env.SUPABASE_URL,
    SUPABASE_ANON_KEY: process.env.SUPABASE_ANON_KEY,
  };
  const previousFetch = global.fetch;
  process.env.SUPABASE_URL = "https://example.supabase.co";
  process.env.SUPABASE_ANON_KEY = "anon-key";
  let requestUrl = "";
  let requestOptions = null;
  global.fetch = async (url, options) => {
    requestUrl = String(url);
    requestOptions = options;
    return {
      ok: true,
      json: async () => true,
    };
  };

  delete require.cache[require.resolve("../../api/ad-entitlement")];
  const handler = require("../../api/ad-entitlement");
  const res = responseRecorder();
  await handler(
    { method: "GET", headers: { authorization: "Bearer user-token" } },
    res,
  );

  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { authenticated: true, adFree: true });
  assert.equal(
    requestUrl,
    "https://example.supabase.co/rest/v1/rpc/current_user_has_ad_free_access",
  );
  assert.equal(requestOptions.headers.apikey, "anon-key");
  assert.equal(requestOptions.headers.Authorization, "Bearer user-token");

  global.fetch = previousFetch;
  for (const [key, value] of Object.entries(previousEnv)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  delete require.cache[require.resolve("../../api/ad-entitlement")];
});

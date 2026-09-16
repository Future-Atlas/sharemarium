const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
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

test("crawler legal routes use the synchronized legal renderer", () => {
  const vercel = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../../vercel.json"), "utf8"),
  );
  const legalRoutes = vercel.routes.filter((route) =>
    String(route.dest || "").startsWith("/api/legal-seo"),
  );

  assert.ok(legalRoutes.length >= 2);
  assert.ok(
    legalRoutes.every((route) =>
      String(route.src).includes("privacy|terms|community-guidelines"),
    ),
  );
});

test("legal SEO renderer serves full Flutter legal source without AdSense", async () => {
  delete require.cache[require.resolve("../../api/legal-seo")];
  const handler = require("../../api/legal-seo");
  const cases = [
    ["privacy", "Sharemarium プライバシーポリシー", "Cookieその他の識別子"],
    ["terms", "Sharemarium 利用規約", "広告"],
    ["community-guidelines", "Sharemarium コミュニティガイドライン", "PR"],
    ["infringement-policy", "Sharemarium 権利侵害・通報ポリシー", "権利侵害"],
    ["external-transmission", "Sharemarium 外部送信に関する公表事項", "Google LLC"],
  ];

  for (const [pathName, title, requiredText] of cases) {
    const res = responseRecorder();
    await handler({ query: { path: pathName } }, res);
    assert.equal(res.statusCode, 200, pathName);
    assert.match(res.body, new RegExp(title), pathName);
    assert.match(res.body, new RegExp(requiredText), pathName);
    assert.ok(res.body.length > 5000, `${pathName} should contain the full document`);
    assert.doesNotMatch(res.body, /pagead2\.googlesyndication\.com/, pathName);
    assert.match(res.body, /index,follow/, pathName);
  }
});

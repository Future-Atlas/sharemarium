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

test("privacy policy contains the required Google advertising-cookie disclosures", () => {
  const privacy = fs.readFileSync(
    path.join(__dirname, "../../lib/screens/privacy_policy_screen.dart"),
    "utf8",
  );

  assert.match(privacy, /Googleを含む第三者配信事業者は、Cookieを使用/);
  assert.match(privacy, /Googleが広告Cookieを使用/);
  assert.match(privacy, /https:\/\/adssettings\.google\.com\//);
  assert.match(privacy, /https:\/\/www\.aboutads\.info\//);
  assert.match(privacy, /2026年9月16日／バージョン1\.10\.0/);
  assert.match(privacy, /最終改定日[\s\S]*2026年9月16日/);
  assert.match(privacy, /\*\*バージョン\*\*[\s\S]*1\.10\.0/);
});

test("legal version constants require renewed privacy consent", () => {
  const versions = fs.readFileSync(
    path.join(__dirname, "../../lib/services/legal_document_versions.dart"),
    "utf8",
  );

  assert.match(versions, /bundle = '1\.12\.0'/);
  assert.match(versions, /privacy = '1\.10\.0'/);
});

test("legal changelog records the AdSense privacy-policy revision", () => {
  const changelog = fs.readFileSync(
    path.join(__dirname, "../../docs/legal_changelog.md"),
    "utf8",
  );

  assert.match(changelog, /プライバシーポリシー \| 1\.10\.0/);
  assert.match(changelog, /2026年9月16日 \| 1\.10\.0/);
  assert.match(changelog, /Google広告Cookie/);
});

test("crawler privacy HTML inherits the same advertising-cookie disclosure", async () => {
  delete require.cache[require.resolve("../../api/legal-seo")];
  const handler = require("../../api/legal-seo");
  const res = responseRecorder();

  await handler({ query: { path: "privacy" } }, res);

  assert.equal(res.statusCode, 200);
  assert.match(res.body, /Googleを含む第三者配信事業者/);
  assert.match(res.body, /Googleが広告Cookieを使用/);
  assert.match(res.body, /adssettings\.google\.com/);
  assert.match(res.body, /バージョン1\.10\.0/);
  assert.doesNotMatch(res.body, /pagead2\.googlesyndication\.com/);
});

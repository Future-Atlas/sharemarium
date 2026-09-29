const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const root = path.join(__dirname, "../..");
const read = (relativePath) =>
  fs.readFileSync(path.join(root, relativePath), "utf8");

const BARE_ORIGIN_RE = /https:\/\/sharemarium\.com(?=\/|["'`\s])/;

test("all crawler-facing production SEO surfaces use the www canonical origin", () => {
  const files = [
    "api/seo.js",
    "api/legal-seo.js",
    "api/sitemap.js",
    "api/posts-seo.js",
    "api/post-seo.js",
    "web/index.html",
    "web/robots.txt",
  ];

  for (const file of files) {
    const source = read(file);
    assert.doesNotMatch(
      source,
      BARE_ORIGIN_RE,
      `${file} must not emit the redirecting bare origin`,
    );
  }

  assert.match(
    read("web/index.html"),
    /rel="canonical" href="https:\/\/www\.sharemarium\.com\/"/,
  );
  assert.match(
    read("web/robots.txt"),
    /Sitemap: https:\/\/www\.sharemarium\.com\/sitemap\.xml/,
  );
});

test("production smoke checks the final indexed www host", () => {
  assert.match(
    read("scripts/production-smoke.mjs"),
    /DEFAULT_BASE_URL = "https:\/\/www\.sharemarium\.com"/,
  );
  assert.match(
    read(".github/workflows/deploy.yaml"),
    /SMOKE_BASE_URL: https:\/\/www\.sharemarium\.com/,
  );
});

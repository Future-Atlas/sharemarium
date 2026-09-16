const assert = require("node:assert/strict");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const test = require("node:test");

async function loadSmokeModule() {
  const moduleUrl = pathToFileURL(
    path.resolve(__dirname, "../../scripts/production-smoke.mjs"),
  ).href;
  return import(moduleUrl);
}

test("production smoke profile keeps public SEO and AdSense endpoints", async () => {
  const { smokeChecksForProfile } = await loadSmokeModule();
  const paths = smokeChecksForProfile("production").map((check) => check.path);

  assert.deepEqual(paths, ["/", "/robots.txt", "/sitemap.xml", "/ads.txt"]);
});

test("staging smoke profile validates the app asset and Vercel API runtime", async () => {
  const { smokeChecksForProfile } = await loadSmokeModule();
  const paths = smokeChecksForProfile("staging").map((check) => check.path);

  assert.deepEqual(paths, [
    "/",
    "/flutter_bootstrap.js",
    "/api/home-ad-eligibility",
  ]);
  assert.equal(paths.includes("/ads.txt"), false);
  assert.equal(paths.includes("/sitemap.xml"), false);
});

test("unknown smoke profiles fail closed", async () => {
  const { smokeChecksForProfile } = await loadSmokeModule();

  assert.throws(
    () => smokeChecksForProfile("unknown"),
    /Unsupported SMOKE_PROFILE: unknown/,
  );
});

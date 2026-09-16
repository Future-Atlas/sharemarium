const assert = require("node:assert/strict");
const fs = require("node:fs");
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

test("staging deployment uploads Flutter output and API source instead of a preview prebuild", () => {
  const root = path.resolve(__dirname, "../..");
  const workflow = fs.readFileSync(
    path.join(root, ".github/workflows/deploy-staging.yaml"),
    "utf8",
  );
  const vercelIgnore = fs.readFileSync(
    path.join(root, ".vercelignore"),
    "utf8",
  );

  assert.match(workflow, /vercel deploy \. --target=preview --force/);
  assert.doesNotMatch(workflow, /vercel deploy --prebuilt/);
  assert.match(workflow, /test -s build\/web\/flutter_bootstrap\.js/);
  assert.match(workflow, /bash scripts\/staging-smoke\.sh/);

  assert.match(vercelIgnore, /^\/\*/m);
  assert.match(vercelIgnore, /^!api$/m);
  assert.match(vercelIgnore, /^!build$/m);
  assert.match(vercelIgnore, /^!lib$/m);
  assert.match(vercelIgnore, /^!vercel\.json$/m);
});

test("staging smoke script uses authenticated Vercel curl for protected previews", () => {
  const script = fs.readFileSync(
    path.resolve(__dirname, "../../scripts/staging-smoke.sh"),
    "utf8",
  );

  assert.match(script, /vercel curl/);
  assert.match(script, /--deployment "\$DEPLOYMENT_URL"/);
  assert.match(script, /\/flutter_bootstrap\.js/);
  assert.match(script, /\/api\/home-ad-eligibility/);
});

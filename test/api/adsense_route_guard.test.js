const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

test("AdSense runtime is isolated when SPA leaves the approved home route", () => {
  const html = fs.readFileSync(
    path.join(__dirname, "../../web/index.html"),
    "utf8",
  );

  assert.match(html, /const allowedPath = \/\^\\\/\$\//);
  assert.match(html, /function isAdsRouteAllowed\(\)/);
  assert.match(html, /function reloadIfLeavingAdsRoute\(\)/);
  assert.match(html, /!adScriptLoaded \|\| isAdsRouteAllowed\(\)/);
  assert.match(html, /window\.location\.replace\(window\.location\.href\)/);
  assert.match(html, /if \(reloadIfLeavingAdsRoute\(\)\) return/);
  assert.match(html, /popstate/);
  assert.match(html, /history\.pushState/);
  assert.match(html, /history\.replaceState/);
});

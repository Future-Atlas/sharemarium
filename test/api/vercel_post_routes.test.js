const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const vercelConfig = JSON.parse(
  fs.readFileSync(path.join(__dirname, "../../vercel.json"), "utf8"),
);

function routeFor(src) {
  return vercelConfig.routes.find((route) => route.src === src);
}

function assertCrawlerOnly(route, expectedDestination) {
  assert.ok(route, "route exists");
  assert.equal(route.dest, expectedDestination);
  assert.ok(Array.isArray(route.has), "route is conditional");
  assert.ok(
    route.has.some(
      (condition) =>
        condition.type === "header" &&
        condition.key === "user-agent" &&
        typeof condition.value === "string" &&
        condition.value.includes("Googlebot"),
    ),
    "route is restricted to crawler user agents",
  );
}

test("public post SSR rewrites are crawler-only", () => {
  assertCrawlerOnly(routeFor("/posts$"), "/api/posts-seo");
  assertCrawlerOnly(
    routeFor("/posts/([^/]+)"),
    "/api/post-seo?post_id=$1",
  );
});

test("human post requests can fall through to the Flutter SPA", () => {
  const listIndex = vercelConfig.routes.findIndex(
    (route) => route.src === "/posts$",
  );
  const detailIndex = vercelConfig.routes.findIndex(
    (route) => route.src === "/posts/([^/]+)",
  );
  const spaFallbackIndex = vercelConfig.routes.findIndex(
    (route) => route.src === "/(.*)" && route.dest === "/" && !route.has,
  );

  assert.ok(listIndex >= 0);
  assert.ok(detailIndex >= 0);
  assert.ok(spaFallbackIndex > listIndex);
  assert.ok(spaFallbackIndex > detailIndex);
});

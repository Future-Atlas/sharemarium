const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const config = JSON.parse(fs.readFileSync(path.join(__dirname, '../../vercel.json'), 'utf8'));

// Simulate the ordered path/header rules for document requests (these post
// paths have no static file). This checks both the crawler match and fallback.
function destination(url, agent) {
  for (const route of config.routes) {
    if (!route.src) continue;
    const match = new RegExp(`^${route.src}$`).exec(url);
    if (!match) continue;
    if (!(route.has || []).every(condition =>
      condition.type === 'header' && condition.key === 'user-agent' &&
      new RegExp(`^(?:${condition.value})$`).test(agent))) continue;
    return route.dest?.replace(/\$(\d+)/g, (_, index) => match[Number(index)] || '');
  }
}

for (const [url, expected] of [
  ['/about', '/api/seo-router?path=/about'],
  ['/posts', '/api/posts-seo'],
  ['/posts/11111111-1111-4111-8111-111111111111', '/api/post-seo?post_id=11111111-1111-4111-8111-111111111111'],
]) {
  for (const agent of ['Googlebot', 'Mozilla/5.0 (compatible; Googlebot/2.1)', 'bingbot', 'Mediapartners-Google', 'Twitterbot']) {
    test(`${url} serves SSR to ${agent}`, () => assert.equal(destination(url, agent), expected));
  }
  for (const agent of ['', 'Mozilla/5.0 Chrome/140.0.0.0 Safari/537.36', 'Mozilla/5.0 (iPhone) Version/18.0 Mobile Safari/604.1']) {
    test(`${url} serves Flutter to browser ${agent || '(no user agent)'}`, () => assert.equal(destination(url, agent), '/'));
  }
}

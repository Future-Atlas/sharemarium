const assert = require('node:assert/strict');
const test = require('node:test');

function recorder() {
  return {
    headers: {},
    setHeader(key, value) { this.headers[key] = value; },
    status(code) { this.statusCode = code; return this; },
    send(body) { this.body = body; return this; },
  };
}

for (const environment of ['production', 'preview']) {
  test(`operator page is public and database-independent (${environment})`, async () => {
    const previous = { ...process.env };
    const originalFetch = global.fetch;
    try {
      process.env.VERCEL_ENV = environment;
      delete process.env.SUPABASE_URL;
      delete process.env.SUPABASE_ANON_KEY;
      let fetches = 0;
      global.fetch = async () => { fetches++; throw new Error('No network expected'); };
      delete require.cache[require.resolve('../../api/seo')];
      delete require.cache[require.resolve('../../api/seo-router')];
      const response = recorder();
      await require('../../api/seo-router')({ query: { path: '/about' } }, response);
      assert.equal(response.statusCode, 200);
      assert.equal(fetches, 0);
      assert.match(response.body, /伊能 龍之介/);
      assert.match(response.body, /劉 鴻斌/);
      assert.match(response.body, /企画・開発・運営/);
      assert.match(response.body, /共同開発/);
      assert.match(response.body, /href="https:\/\/www.instagram.com\/ryunosukeino\/" target="_blank" rel="noopener noreferrer">Instagram/);
      assert.match(response.body, /href="\/contact"/);
      assert.match(response.body, /"@type":"AboutPage"/);
      assert.doesNotMatch(response.body, /<iframe|<script[^>]+instagram/);
      assert.match(response.body, environment === 'preview'
        ? /name="robots" content="noindex,nofollow"/
        : /name="robots" content="index,follow"/);
      const sitemap = recorder();
      delete require.cache[require.resolve('../../api/sitemap')];
      await require('../../api/sitemap')({}, sitemap);
      assert.match(sitemap.body, /<loc>https:\/\/sharemarium.com\/about<\/loc>/);
    } finally {
      process.env = previous;
      global.fetch = originalFetch;
    }
  });
}

# AdSense content readiness

Sharemarium treats AdSense approval as a content-readiness problem, not only an
ad-placement problem.

Google does not publish a minimum page-view, review-count, or word-count
requirement for AdSense approval. The thresholds below are therefore
Sharemarium's conservative internal release gates. They are intended to prevent
ads from appearing while the public site is still thin or dominated by
third-party catalog data.

## Home ad gate

The home page may load AdSense only when all of the following are true:

- at least 5 public, non-spoiler reviews contain 120 or more characters;
- those qualifying reviews come from at least 3 distinct profiles;
- the Supabase content-readiness check succeeds;
- the current route is the home page;
- an authenticated user's ad-free entitlement does not suppress ads.

Failures are fail-closed: AdSense is not loaded.

Third-party book catalog results from Rakuten or NDL never make a page eligible
for ads.

## Search indexing

- Individual review pages are indexable only for non-spoiler reviews with at
  least 80 characters.
- The public posts index is indexable only when at least 3 review pages meet the
  individual indexability threshold.
- Genre/catalog pages remain `noindex,follow` until they contain substantial
  manually curated Sharemarium content.
- Thin, private, suspended, missing, error, settings, login, form, and other
  non-content pages must not become indexable ad inventory.

## Canonical-domain requirements

- The production canonical origin is `https://www.sharemarium.com`.
- `https://sharemarium.com` must remain a redirect-only origin.
- The legacy Vercel hostname `book-case-u9uq.vercel.app` must permanently
  redirect every path to the corresponding `www.sharemarium.com` path.
- Canonical tags, Open Graph URLs, sitemap URLs and robots.txt must use the
  same `www` origin.
- Google Search Console should be submitted
  `https://www.sharemarium.com/sitemap.xml`, not the redirecting bare-domain
  sitemap.

## Before requesting another AdSense review

Do not resubmit solely because the CI is green. Confirm all of the following:

1. Production deployment for the remediation commit succeeded.
2. The home ad eligibility endpoint remains ineligible until the internal UGC
   threshold is met.
3. There are genuine reviews from multiple real users; do not create artificial
   traffic or filler reviews for approval.
4. Google Search Console shows successful crawling/indexing of the home page and
   multiple substantive public review pages.
5. Search results are beginning to expose Sharemarium-owned review content, not
   only the landing page.
6. AdSense Policy Center does not show another unrelated violation.

The numeric thresholds in this document are internal engineering safeguards,
not claims about Google's official approval requirements.

# SEO URL / app route consistency notes

Sharemarium uses Flutter for the human-facing web app and Vercel Serverless
Functions for crawler-friendly HTML where static metadata/indexable content is
needed.

## Canonical public route families

The general crawler-aware routes include:

- `/`
- `/book/{id}`
- `/genre/{genre}`
- `/users/{id}`
- public legal/information pages

`/users/{id}` is the canonical public profile family. Legacy `/user/{id}` and
`/profile/{id}` routes redirect to `/users/{id}`.

The Flutter app keeps compatible route semantics so a human opening a canonical
URL sees the same content intent as the crawler representation.

## Public posts: active human/crawler split

Public post URLs intentionally use different renderers for the same public
resource:

```text
crawler -> SSR
human   -> Flutter
```

`vercel.json` applies the post SSR rewrites only when the request User-Agent
matches a supported crawler:

- crawler `/posts` -> `/api/posts-seo`
- crawler `/posts/{postId}` -> `/api/post-seo?post_id={postId}`

Ordinary browser requests fall through to the Flutter SPA:

- human `/posts` -> Flutter public post index
- human `/posts/{postId}` -> Flutter post detail

The Flutter post routes retain the normal account gates and the existing privacy,
age, blocking, and spoiler behavior. SSR and Flutter must represent the same
public data; this split is an alternate rendering strategy rather than separate
content.

The crawler SSR functions read `SUPABASE_URL` and `SUPABASE_ANON_KEY` from the
Vercel Serverless runtime. Those values are separate from the Supabase values
passed to Flutter with `--dart-define` during GitHub Actions builds. Configure
them independently for Production and Preview/Staging.

## Verification

For staging, inspect `https://staging.sharemarium.com/posts` with both request
types:

- default browser User-Agent: expect the Flutter post index and working post detail navigation
- crawler User-Agent such as Googlebot: expect SSR HTML, HTTP 200, and a healthy `X-Posts-Diagnostics` value

When Preview deployment protection is enabled, use an authenticated Vercel
Preview session for browser verification. A Vercel login page that happens to
return HTTP 200 is not a successful SSR/content check.

Production uses the same human/crawler routing model on the canonical Sharemarium
domain.

## Indexing boundaries

Crawler rendering and sitemap generation must not expose content that is not
publicly indexable. In particular, private, suspended, deleted, missing, empty,
or otherwise restricted content should return an appropriate 404/noindex result
or be omitted from the sitemap.

Crawler HTML and the Flutter page for the same canonical URL should describe the
same public resource. SSR exists to make that resource understandable to
crawlers, not to create a separate content model.

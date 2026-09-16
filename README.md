# Sharemarium

Sharemarium is a Flutter Web first book review and reading management app.
It uses Supabase for auth, database, storage, and Edge Functions, and Vercel for
the production/staging web deployments and crawler-friendly SEO pages.

## Current Scope

- Production target: Web
- `main`: production release branch
- `develop`: long-lived staging/integration branch and repository default branch
- iOS / Android: in development, not production-targeted yet
- Public browsing: enabled for public read-only content and SEO/AdSense review
- Write actions: protected by Supabase RLS/RPC checks; Flutter UI checks are not a security boundary

## Tech Stack

- Flutter 3.44.9
- Dart SDK ^3.12.0
- supabase_flutter ^2.17.2
- provider ^6.1.2
- google_fonts ^8.2.1
- Vercel CLI 58.7.1 in deployment workflows
- Supabase CLI 2.115.0 in validation/deployment workflows

## Local Development

This project uses FVM to pin Flutter 3.44.9 for repository-local development.
Install FVM locally if needed, then initialize the project SDK with:

```bash
fvm install
fvm flutter pub get
npm install
cp env.example.json env.json
fvm flutter run -d chrome --dart-define-from-file=env.json
```

`env.json` is intentionally ignored by Git.

Use FVM for local Flutter commands:

```bash
fvm flutter analyze --no-fatal-infos --no-fatal-warnings
fvm flutter test
fvm flutter run
```

Start local Supabase when database-backed features are needed:

```bash
supabase start
supabase db reset
supabase test db
```

`supabase db reset` applies `supabase/migrations/*.sql` and then reads
`supabase/seed.sql`.

## Environment Variables

### Flutter build-time values

These values are supplied with `--dart-define` / `--dart-define-from-file` and are
therefore available to the browser build where applicable.

| Variable | Purpose |
| --- | --- |
| `APP_ENV` | `production`, `staging`, or `development` |
| `SUPABASE_URL` | Environment-specific Supabase project URL |
| `SUPABASE_ANON_KEY` | Environment-specific Supabase publishable/anon key |
| `SUPABASE_REDIRECT_URL` | OAuth redirect URL |
| `AMAZON_ASSOCIATE_TAG` | Amazon associate tag used by the Flutter build |
| `RAKUTEN_PROXY_BASE_URL` | Optional base URL for native builds to call the Vercel proxy |

### Vercel Serverless runtime values

Server-side SEO/API functions read their own Vercel runtime environment. These
are separate from Flutter build-time GitHub Secrets.

| Variable | Purpose |
| --- | --- |
| `SUPABASE_URL` | Supabase URL used by crawler/SEO server functions |
| `SUPABASE_ANON_KEY` | Supabase anon/publishable key used by crawler/SEO server functions |
| `RAKUTEN_APP_ID` | Rakuten API application id |
| `RAKUTEN_ACCESS_KEY` | Rakuten API access key |
| `RAKUTEN_REFERER` | Origin used for Rakuten API requests |

Do not pass Rakuten server credentials through `--dart-define` or
`--dart-define-from-file`.

### GitHub deployment secrets

GitHub Environments keep production and staging credentials separate.

| Variable | Purpose |
| --- | --- |
| `VERCEL_ORG_ID` | Vercel organization id |
| `VERCEL_PROJECT_ID` | Vercel project id |
| `VERCEL_TOKEN` | Vercel deploy token |
| `SUPABASE_ACCESS_TOKEN` | Supabase deploy token |
| `SUPABASE_PROJECT_ID` | Environment-specific Supabase project ref |
| `SUPABASE_DB_PASSWORD` | Environment-specific database password for migration deploys |
| `SUPABASE_URL` | Flutter build-time Supabase URL for the selected GitHub Environment |
| `SUPABASE_ANON_KEY` | Flutter build-time Supabase key for the selected GitHub Environment |
| `SUPABASE_REDIRECT_URL` | Flutter OAuth redirect URL for the selected environment |

## Production / Staging

The intended branch/environment topology is:

```text
feature/*
   ↓ PR
develop  -> staging
   ↓ release PR
main     -> production
```

GitHub Environments are used to separate credentials:

- `production`: production Vercel/Supabase credentials
- `staging`: staging Vercel/Supabase credentials

Web deployment workflows:

- `.github/workflows/deploy.yaml`: `main` -> Vercel Production, supports manual dispatch, and runs post-deploy smoke tests against the production domain
- `.github/workflows/deploy-staging.yaml`: `develop` -> Vercel Preview/Staging

Supabase workflows:

- `.github/workflows/supabase-validate.yaml`: local migration replay + pgTAP/RLS validation on relevant PRs
- `.github/workflows/supabase-deploy.yaml`: production migrations/Edge Functions from `main`
- `.github/workflows/supabase-deploy-staging.yaml`: guarded staging migrations/Edge Functions from `develop`, with manual plan/apply support

Branch protection is a GitHub repository setting rather than repository code.
The required target settings and the current manual-configuration caveat are
documented in `docs/github_branch_protection.md`.

## CI / Validation

Pull requests and pushes to `main` / `develop` run `.github/workflows/ci.yaml`:

```bash
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test
flutter build web --release
npm ci
npm run test:api
```

Relevant Supabase PRs additionally run `.github/workflows/supabase-validate.yaml`
with Supabase CLI 2.115.0:

```bash
supabase start
supabase db reset
supabase test db
```

## SEO / Public Routes

`vercel.json` separates Flutter routing from crawler-oriented server rendering.

`api/seo.js` serves crawler-friendly HTML for routes such as:

- `/`
- `/book/{id}`
- `/genre/{genre}`
- `/users/{userId}`
- legal/public information pages

Legacy `/user/*` and `/profile/*` URLs redirect to the canonical `/users/*`
family.

Public post URLs use the active human/crawler split:

- ordinary browser `/posts` -> Flutter public post index
- ordinary browser `/posts/{postId}` -> Flutter post detail
- crawler `/posts` -> `api/posts-seo.js`
- crawler `/posts/{postId}` -> `api/post-seo.js`

The crawler SSR functions require `SUPABASE_URL` and `SUPABASE_ANON_KEY` in the
corresponding Vercel runtime environment. Flutter build-time values do not replace
those Serverless runtime variables.

Private, suspended, deleted, missing, or otherwise non-indexable content must not
be exposed as indexable crawler HTML or sitemap entries. Human and crawler views
must represent the same public resource; SSR is an alternate rendering path, not
a separate content model.

## Project Structure

```text
sharemarium/
  .github/workflows/
  api/
    rakuten.js
    _rakuten_request.js
    seo.js
    posts-seo.js
    post-seo.js
    sitemap.js
  docs/
    github_branch_protection.md
    seo_routing_notes.md
  lib/
    api/
    config/
    controllers/
    models/
    repositories/
    screens/
    services/
    widgets/
  scripts/
  supabase/
    functions/
    migrations/
    tests/
    config.toml
    schema.sql
    seed.sql
  test/
  web/
```

`supabase/migrations/*.sql` is the canonical database history.
`supabase/schema.sql` is a snapshot artifact and should not replace migrations.

## Useful Commands

```bash
fvm flutter clean
fvm flutter pub get
fvm flutter analyze
fvm flutter test
fvm flutter build web --release --dart-define-from-file=env.json
npm ci
npm run test:api
supabase db reset
supabase test db
```

## License

MIT License. See `LICENSE`.

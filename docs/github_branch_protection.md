# GitHub branch protection and required checks

Sharemarium uses `develop` as the long-lived staging/integration branch and
`main` as the production release branch.

## Current repository state

Branch protection is configured in GitHub repository settings, not in this
repository. As of 2026-09-16, the GitHub branch API reports both `main` and
`develop` as **not protected**.

Therefore the rules below are the required target state, not a claim that they
are already enforced. Keep the Asana task for branch protection open until the
GitHub settings have actually been changed and verified.

## Required target policy for `main`

Configure a ruleset or branch-protection rule for `main` that:

- requires a pull request before merging
- requires status checks to pass before merging
- requires `CI / flutter`
- prevents ordinary direct pushes to `main`
- does not allow a failing/stale required check to be bypassed accidentally
- optionally requires at least one review when another reviewer is available
- documents any administrator/bypass actors explicitly

For changes under `supabase/**` or `.github/workflows/supabase-*.yaml`, also
require the Supabase validation check when GitHub allows a path-specific check to
be made required without blocking unrelated PRs.

## Recommended policy for `develop`

`develop` is the staging/integration branch. Use the same PR + CI model where
practical:

- feature/fix branches merge into `develop` through PRs
- `CI / flutter` must pass before merge
- database-related changes must pass Supabase validation
- direct pushes should be restricted once the staging workflow is stable

The production release path remains:

```text
feature/* -> develop -> release PR -> main
```

## What the checks actually run

`.github/workflows/ci.yaml` runs:

- `flutter analyze --no-fatal-infos --no-fatal-warnings`
- `flutter test`
- `flutter build web --release`
- `npm ci`
- `npm run test:api`

The required check name is the workflow/job combination `CI / flutter`.

`.github/workflows/supabase-validate.yaml` runs for relevant pull requests and
uses Supabase CLI 2.115.0 to:

- start local Supabase services
- replay migrations with `supabase db reset`
- execute pgTAP/RLS tests with `supabase test db`

Its workflow/job combination is `Validate Supabase Migrations / validate`.

## Deployment environments

Deployment credentials are intentionally separated through GitHub Environments:

- `production`: production Vercel and Supabase credentials
- `staging`: staging Vercel and Supabase credentials

Web deployment workflows:

- `.github/workflows/deploy.yaml`
- `.github/workflows/deploy-staging.yaml`

Database/Edge Function deployment workflows:

- `.github/workflows/supabase-deploy.yaml`
- `.github/workflows/supabase-deploy-staging.yaml`

Do not move environment-specific credentials into shared repository-level values
when that would allow staging and production targets to be confused.

## Completion check for the Asana task

Before marking branch protection complete, verify in GitHub that:

1. `main` is protected by the intended ruleset/branch rule.
2. A PR with failing `CI / flutter` cannot be merged through the normal path.
3. Ordinary contributors cannot push directly to `main`.
4. Database-related PRs run the Supabase validation workflow.
5. This document still matches the actual settings.

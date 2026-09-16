#!/usr/bin/env bash
set -euo pipefail

: "${DEPLOYMENT_URL:?DEPLOYMENT_URL is required}"
: "${VERCEL_TOKEN:?VERCEL_TOKEN is required}"

base_url="${DEPLOYMENT_URL%/}"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

check_endpoint() {
  local path="$1"
  local content_type_pattern="$2"
  local body_pattern="$3"
  local label="$4"
  local safe_name
  safe_name="$(printf '%s' "$path" | tr '/?=&' '____')"
  local headers="$workdir/${safe_name}.headers"
  local body="$workdir/${safe_name}.body"
  local url="${base_url}${path}"

  # Vercel CLI reads VERCEL_TOKEN from the environment. Using a full Preview URL
  # lets `vercel curl` authenticate and bypass Deployment Protection without
  # leaking the token into native curl arguments.
  vercel curl "$url" \
    --location \
    --fail \
    --silent \
    --show-error \
    --dump-header "$headers" \
    --output "$body"

  if ! grep -Eqi "^content-type:.*${content_type_pattern}" "$headers"; then
    echo "::error::${label}: unexpected content-type"
    cat "$headers"
    exit 1
  fi

  if ! grep -Eqi "$body_pattern" "$body"; then
    echo "::error::${label}: expected response marker was missing"
    exit 1
  fi

  echo "OK ${path} (${label})"
}

check_endpoint "/" "text/html" "<html([[:space:]]|>)" "Flutter entry page"
check_endpoint "/flutter_bootstrap.js" "(application|text)/(javascript|x-javascript)" "(_flutter|FlutterLoader|flutter)" "Flutter bootstrap asset"
check_endpoint "/api/home-ad-eligibility" "application/json" '"eligible"[[:space:]]*:' "Vercel API runtime"

echo "Staging deployment smoke tests passed."

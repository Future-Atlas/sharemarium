import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const DEFAULT_BASE_URL = "https://sharemarium.com";
const DEFAULT_ATTEMPTS = 6;
const DEFAULT_RETRY_DELAY_MS = 8000;
const DEFAULT_TIMEOUT_MS = 15000;

const flutterEntryCheck = {
  path: "/",
  contentTypes: ["text/html"],
  bodyPattern: /<html(?:\s|>)/i,
  description: "Flutter entry page",
};

export const productionSmokeChecks = [
  flutterEntryCheck,
  {
    path: "/robots.txt",
    contentTypes: ["text/plain"],
    bodyPattern: /user-agent\s*:/i,
    description: "robots.txt",
  },
  {
    path: "/sitemap.xml",
    contentTypes: ["application/xml", "text/xml"],
    bodyPattern: /<(?:urlset|sitemapindex)(?:\s|>)/i,
    description: "sitemap.xml",
  },
  {
    path: "/ads.txt",
    contentTypes: ["text/plain"],
    bodyPattern: /google\.com\s*,\s*pub-/i,
    description: "ads.txt",
  },
];

export const stagingSmokeChecks = [
  flutterEntryCheck,
  {
    path: "/flutter_bootstrap.js",
    contentTypes: [
      "application/javascript",
      "text/javascript",
      "application/x-javascript",
    ],
    bodyPattern: /(?:_flutter|FlutterLoader|flutter)/i,
    description: "Flutter bootstrap asset",
  },
  {
    path: "/api/home-ad-eligibility",
    contentTypes: ["application/json"],
    bodyPattern: /"eligible"\s*:/i,
    description: "Vercel API runtime",
  },
];

// Backward-compatible export for existing imports and local usage.
export const smokeChecks = productionSmokeChecks;

export function smokeChecksForProfile(profile = "production") {
  const normalized = String(profile || "production").trim().toLowerCase();
  if (normalized === "production") return productionSmokeChecks;
  if (normalized === "staging") return stagingSmokeChecks;
  throw new Error(`Unsupported SMOKE_PROFILE: ${profile}`);
}

const sleep = (ms) => new Promise((resolveSleep) => setTimeout(resolveSleep, ms));

export function validateResponse(check, response, body) {
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`);
  }

  const contentType = response.headers.get("content-type")?.toLowerCase() ?? "";
  if (!check.contentTypes.some((expected) => contentType.includes(expected))) {
    throw new Error(
      `unexpected content-type "${contentType || "missing"}"; expected ${check.contentTypes.join(" or ")}`,
    );
  }

  if (!check.bodyPattern.test(body)) {
    throw new Error("response body did not contain the expected marker");
  }
}

async function fetchWithTimeout(
  url,
  timeoutMs,
  fetchImpl,
  bypassToken = "",
) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  const headers = {
    "user-agent": "Sharemarium-Deployment-Smoke-Test/1.0",
    accept: "*/*",
  };
  if (bypassToken) {
    headers["x-vercel-protection-bypass"] = bypassToken;
  }

  try {
    return await fetchImpl(url, {
      redirect: "follow",
      signal: controller.signal,
      headers,
    });
  } finally {
    clearTimeout(timeout);
  }
}

export async function checkEndpoint(
  baseUrl,
  check,
  {
    attempts = DEFAULT_ATTEMPTS,
    retryDelayMs = DEFAULT_RETRY_DELAY_MS,
    timeoutMs = DEFAULT_TIMEOUT_MS,
    fetchImpl = fetch,
    bypassToken = process.env.SMOKE_BYPASS_TOKEN || "",
  } = {},
) {
  const url = new URL(check.path, baseUrl).toString();
  let lastError;

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const response = await fetchWithTimeout(
        url,
        timeoutMs,
        fetchImpl,
        bypassToken,
      );
      const body = await response.text();
      validateResponse(check, response, body);
      console.log(`OK ${response.status} ${url} (${check.description})`);
      return;
    } catch (error) {
      lastError = error;
      const message = error instanceof Error ? error.message : String(error);
      console.warn(
        `Attempt ${attempt}/${attempts} failed for ${url}: ${message}`,
      );
      if (attempt < attempts) await sleep(retryDelayMs);
    }
  }

  const message = lastError instanceof Error ? lastError.message : String(lastError);
  throw new Error(`${url}: ${message}`);
}

export async function runProductionSmokeTests({
  baseUrl = process.env.SMOKE_BASE_URL || DEFAULT_BASE_URL,
  fetchImpl = fetch,
  bypassToken = process.env.SMOKE_BYPASS_TOKEN || "",
  profile = process.env.SMOKE_PROFILE || "production",
} = {}) {
  const normalizedBaseUrl = new URL(baseUrl);
  if (!/^https?:$/.test(normalizedBaseUrl.protocol)) {
    throw new Error("SMOKE_BASE_URL must use http or https");
  }

  const checks = smokeChecksForProfile(profile);
  console.log(
    `Running ${profile} deployment smoke tests against ${normalizedBaseUrl.origin}`,
  );
  await Promise.all(
    checks.map((check) =>
      checkEndpoint(normalizedBaseUrl, check, { fetchImpl, bypassToken }),
    ),
  );
  console.log(`${profile} deployment smoke tests passed.`);
}

const invokedPath = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : null;
if (invokedPath === import.meta.url) {
  runProductionSmokeTests().catch((error) => {
    const message = error instanceof Error ? error.stack || error.message : String(error);
    console.error(`::error::Deployment smoke test failed\n${message}`);
    process.exitCode = 1;
  });
}

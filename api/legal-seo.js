const fs = require("node:fs");
const path = require("node:path");

const SITE_URL = "https://sharemarium.com";
const SITE_NAME = "Sharemarium";

// Keep the crawler representation tied to the exact Flutter legal-document
// source. The explicit reads also allow Vercel's file tracer to include these
// Dart sources in the serverless bundle.
const SOURCES = {
  privacy: fs.readFileSync(
    path.join(__dirname, "../lib/screens/privacy_policy_screen.dart"),
    "utf8",
  ),
  terms: fs.readFileSync(
    path.join(__dirname, "../lib/screens/terms_screen.dart"),
    "utf8",
  ),
  "community-guidelines": fs.readFileSync(
    path.join(__dirname, "../lib/screens/community_guidelines_screen.dart"),
    "utf8",
  ),
  "infringement-policy": fs.readFileSync(
    path.join(__dirname, "../lib/screens/infringement_policy_screen.dart"),
    "utf8",
  ),
  "external-transmission": fs.readFileSync(
    path.join(__dirname, "../lib/screens/external_transmission_screen.dart"),
    "utf8",
  ),
};

const CONFIG = {
  privacy: { marker: "_policyText", label: "プライバシーポリシー" },
  terms: { marker: "_termsText", label: "利用規約" },
  "community-guidelines": {
    marker: "_guidelinesText",
    label: "コミュニティガイドライン",
  },
  "infringement-policy": {
    marker: "_policyText",
    label: "権利侵害・通報ポリシー",
  },
  "external-transmission": {
    marker: "_disclosureText",
    label: "外部送信に関する公表事項",
  },
};

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function extractRawDartString(source, marker) {
  const escapedMarker = marker.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pattern = new RegExp(
    `static\\s+const\\s+String\\s+${escapedMarker}\\s*=\\s*r'''([\\s\\S]*?)''';`,
  );
  const match = source.match(pattern);
  return match ? match[1].trim() : "";
}

function renderDocument(text) {
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  const out = [];
  let listType = null;

  function closeList() {
    if (!listType) return;
    out.push(`</${listType}>`);
    listType = null;
  }

  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line || /^[_-]{6,}$/.test(line)) {
      closeList();
      continue;
    }

    const heading = /^(#{1,3})\s+(.+)$/.exec(line);
    if (heading) {
      closeList();
      const level = Math.min(3, heading[1].length);
      out.push(`<h${level}>${escapeHtml(heading[2])}</h${level}>`);
      continue;
    }

    const bullet = /^[*•]\s+(.+)$/.exec(line);
    if (bullet) {
      if (listType !== "ul") {
        closeList();
        listType = "ul";
        out.push("<ul>");
      }
      out.push(`<li>${escapeHtml(bullet[1])}</li>`);
      continue;
    }

    const numbered = /^\d+[.)]\s+(.+)$/.exec(line);
    if (numbered) {
      if (listType !== "ol") {
        closeList();
        listType = "ol";
        out.push("<ol>");
      }
      out.push(`<li>${escapeHtml(numbered[1])}</li>`);
      continue;
    }

    closeList();
    out.push(`<p>${escapeHtml(line)}</p>`);
  }

  closeList();
  return out.join("\n");
}

function normalizeKey(rawPath) {
  return String(rawPath || "")
    .replace(/^\/+/, "")
    .replace(/\/+$/, "");
}

module.exports = async (req, res) => {
  const key = normalizeKey(req.query?.path);
  const config = CONFIG[key];
  const source = SOURCES[key];

  if (!config || !source) {
    res.setHeader("X-Robots-Tag", "noindex, nofollow");
    return res.status(404).send("Not found");
  }

  const documentText = extractRawDartString(source, config.marker);
  if (!documentText) {
    res.setHeader("X-Robots-Tag", "noindex, nofollow");
    return res.status(500).send("Legal document source unavailable");
  }

  const canonical = `${SITE_URL}/${key}`;
  const description = `${SITE_NAME}の${config.label}です。正式な公開文書の全文を掲載しています。`;

  res.setHeader("Content-Type", "text/html; charset=utf-8");
  res.setHeader("Cache-Control", "s-maxage=300, stale-while-revalidate=3600");
  return res.status(200).send(`<!doctype html>
<html lang="ja">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>${escapeHtml(config.label)} | ${SITE_NAME}</title>
    <meta name="description" content="${escapeHtml(description)}">
    <meta name="robots" content="index,follow">
    <link rel="canonical" href="${canonical}">
    <meta property="og:type" content="article">
    <meta property="og:site_name" content="${SITE_NAME}">
    <meta property="og:title" content="${escapeHtml(config.label)} | ${SITE_NAME}">
    <meta property="og:description" content="${escapeHtml(description)}">
    <meta property="og:url" content="${canonical}">
    <style>
      body { margin: 0; font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; line-height: 1.8; color: #202124; background: #fff; }
      header, main, footer { max-width: 880px; margin: 0 auto; padding-left: 20px; padding-right: 20px; }
      header { padding-top: 24px; padding-bottom: 16px; border-bottom: 1px solid #ddd; }
      header a, footer a { color: inherit; }
      main { padding-top: 28px; padding-bottom: 48px; }
      h1 { font-size: 2rem; }
      h2 { margin-top: 2.2rem; }
      h3 { margin-top: 1.6rem; }
      p, li { overflow-wrap: anywhere; }
      footer { padding-top: 20px; padding-bottom: 36px; border-top: 1px solid #ddd; }
    </style>
  </head>
  <body>
    <header><a href="/">${SITE_NAME}</a></header>
    <main>${renderDocument(documentText)}</main>
    <footer><a href="/">${SITE_NAME}へ戻る</a></footer>
  </body>
</html>`);
};

module.exports._test = { extractRawDartString, renderDocument, CONFIG };

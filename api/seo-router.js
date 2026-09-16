const legalSeo = require("./legal-seo");
const seoHome = require("./seo-home");
const seo = require("./seo");

const LEGAL_PATHS = new Set([
  "/privacy",
  "/terms",
  "/community-guidelines",
  "/infringement-policy",
  "/external-transmission",
]);

function normalizePath(rawPath) {
  const value = String(rawPath || "/").trim();
  if (!value || value === "/") return "/";
  return `/${value.replace(/^\/+/, "").replace(/\/+$/, "")}`;
}

module.exports = async (req, res) => {
  const normalizedPath = normalizePath(req.query?.path);

  if (normalizedPath === "/") {
    return seoHome(
      {
        ...req,
        query: {
          ...(req.query || {}),
          path: "/",
        },
      },
      res,
    );
  }

  if (LEGAL_PATHS.has(normalizedPath)) {
    return legalSeo(
      {
        ...req,
        query: {
          ...(req.query || {}),
          path: normalizedPath.slice(1),
        },
      },
      res,
    );
  }

  return seo(
    {
      ...req,
      query: {
        ...(req.query || {}),
        path: normalizedPath,
      },
    },
    res,
  );
};

module.exports._test = { LEGAL_PATHS, normalizePath };

const seo = require("./seo");
const { fetchHomeAdEligibility } = require("./_home_ad_eligibility");

function responseRecorder() {
  return {
    headers: {},
    statusCode: 200,
    body: "",
    setHeader(name, value) {
      this.headers[name] = value;
    },
    status(code) {
      this.statusCode = code;
      return this;
    },
    send(value) {
      this.body = String(value);
      return this;
    },
    json(value) {
      this.body = JSON.stringify(value);
      return this;
    },
  };
}

function suppressAdsInRenderedHtml(html) {
  return String(html || "")
    .replace(
      /window\.__sharemariumAdsAllowed\s*=\s*true;/g,
      "window.__sharemariumAdsAllowed = false;",
    )
    .replace(
      /\s*<script>\s*\(function\(\)\s*\{[\s\S]*?pagead2\.googlesyndication\.com[\s\S]*?<\/script>/g,
      "",
    );
}

module.exports = async (req, res) => {
  const captured = responseRecorder();
  const eligibilityPromise = fetchHomeAdEligibility();

  await seo(
    {
      ...req,
      query: {
        ...(req.query || {}),
        path: "/",
      },
    },
    captured,
  );

  const eligibility = await eligibilityPromise;
  for (const [name, value] of Object.entries(captured.headers)) {
    res.setHeader(name, value);
  }
  res.setHeader("X-Home-Ad-Eligibility", eligibility.diagnostic);

  const body = eligibility.eligible
    ? captured.body
    : suppressAdsInRenderedHtml(captured.body);
  return res.status(captured.statusCode).send(body);
};

module.exports._test = { suppressAdsInRenderedHtml, responseRecorder };

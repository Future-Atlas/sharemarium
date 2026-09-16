const { fetchHomeAdEligibility } = require("./_home_ad_eligibility");

module.exports = async (req, res) => {
  if (req.method && req.method !== "GET") {
    return res.status(405).json({ error: "method_not_allowed" });
  }

  const result = await fetchHomeAdEligibility();
  res.setHeader("Cache-Control", "s-maxage=60, stale-while-revalidate=300");
  res.setHeader("X-Home-Ad-Eligibility", result.diagnostic);
  return res.status(200).json({ eligible: result.eligible === true });
};

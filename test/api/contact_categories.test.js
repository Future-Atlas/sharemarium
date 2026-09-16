const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "../..");

function read(relativePath) {
  return fs.readFileSync(path.join(root, relativePath), "utf8");
}

test("contact form exposes billing/refund and fraud categories", () => {
  const source = read("lib/screens/contact_screen.dart");

  assert.match(source, /'billing': '料金・返金'/);
  assert.match(source, /'fraud': '不正利用'/);
  assert.match(source, /料金・返金、不正利用に関するご連絡/);
});

test("contact category migration allows the UI category keys", () => {
  const migration = read(
    "supabase/migrations/20260916072000_add_billing_and_fraud_contact_categories.sql",
  );

  for (const category of [
    "general",
    "privacy",
    "infringement",
    "report",
    "account",
    "billing",
    "fraud",
    "other",
  ]) {
    assert.match(migration, new RegExp(`'${category}'`));
  }

  assert.match(migration, /DROP CONSTRAINT IF EXISTS contact_requests_category_check/i);
  assert.match(migration, /ADD CONSTRAINT contact_requests_category_check/i);
});

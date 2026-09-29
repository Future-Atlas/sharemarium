const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const source = fs.readFileSync(
  path.join(__dirname, "../../lib/widgets/post_composer_dialog.dart"),
  "utf8",
);

test("review composer gives user-centered prompts for substantive reviews", () => {
  assert.match(source, /印象に残った場面、その理由、読後に考えたこと/);
  assert.match(source, /自分の言葉で書いてみましょう/);
  assert.match(source, /短い感想でも投稿できます/);
  assert.match(source, /読書記録として役立ちます/);
});

test("review composer does not impose an AdSense-oriented minimum length", () => {
  assert.doesNotMatch(source, /80文字以上|120文字以上|AdSense/);
  assert.match(source, /if \(review\.isEmpty\)/);
});

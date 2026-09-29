const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const source = fs.readFileSync(
  path.join(__dirname, "../../lib/screens/book_list_screen.dart"),
  "utf8",
);

test("home screen explains Sharemarium's original value to human users", () => {
  assert.match(source, /Sharemariumでできること/);
  assert.match(source, /読書体験をレビューとして残す/);
  assert.match(source, /ほかの読者の感想に触れる/);
  assert.match(source, /書籍情報と利用者レビューを分けて表示/);
  assert.match(source, /実際に読んだ人のレビューや交流がSharemariumの中心コンテンツ/);
});

test("home service introduction links to public reviews and operator information", () => {
  assert.match(source, /pushNamed\('\/posts'\)/);
  assert.match(source, /pushNamed\('\/about'\)/);
  assert.match(source, /公開レビューを見る/);
  assert.match(source, /サービス・運営方針について/);
});

test("service introduction is limited to the real home screen", () => {
  assert.match(
    source,
    /if \(widget\.initialGenre == null &&\s+_controller\.searchQuery\.isEmpty\)\s+_buildServiceIntroduction\(\)/,
  );
});

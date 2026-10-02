# 書籍概要のAmazonアソシエイトリンク

## 表示と遷移

- 検索結果から開く書籍詳細と、マイページから開く書籍詳細は共通の `AmazonBookLink` を使用する。
- チェックディジットが正しいISBN-10、または978で始まるISBN-13は、ISBN-10を使ったAmazon.co.jpの商品URLへ直接遷移する（「Amazonで見る」）。
- ISBN-13をそのままASINにしない。ISBN-10が対応しない979、ISBN不明、不正なISBNは「Amazonで探す」と「検索結果を開きます」の説明を表示する。
- ISBNから作るリンクは紙の版が対象。Kindle版ASINやAmazonでの販売有無・在庫は推測しない。商品が存在しないケースは将来、確認済みASINを版ごとに管理して対応する。
- Amazonへはユーザー操作で新しいタブを開く。広告表示とアソシエイトの収入に関する説明をボタンの下に表示する。
- Amazon APIによる価格・画像取得、トラッキングスクリプト、サイト内の自動転送は追加しない。

## 設定・公開前の確認

1. Amazonアソシエイトに実際の公開サイトを登録し、発行されたトラッキングIDを用意する。サンプルのIDを本番で使わない。
2. 既存のGitHub Actionsで参照している `AMAZON_ASSOCIATE_TAG` を対象環境に設定する。Flutterのビルド時に必要な値であり、Vercelへの環境変数追加だけではビルド済みアプリへ反映されない。
3. 未設定の場合はリンクを非表示にする。このコード変更はSecretsの有無や値を検証していない。
4. 検証環境で代表的な国内書籍・ISBN-10・ISBN不明のケースを確認する。商品ページの書名と版が一致し、URLに実際のタグが含まれることを確認する。自分のリンクから購入して動作確認しない。
5. 本番公開は別途承認後に実施する。

## テスト

```powershell
flutter test test/amazon_book_link_test.dart
flutter test --dart-define=AMAZON_ASSOCIATE_TAG=test-22 test/amazon_book_link_test.dart
```

上記テスト用IDは外部通信を行わないテストでのみ使用する。

Amazon公式のリンク形式: https://affiliate.amazon.co.jp/help/node/topic/GP38PJ6EUR6PFBEC

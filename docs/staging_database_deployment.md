# 検証用Supabaseの初期構築・更新

## 対象

- GitHub: `Future-Atlas/sharemarium` の `develop`
- GitHub Environment: `staging`
- Supabase: `sharemarium-staging` / `wpoigmywpewrrbudqhgh`
- ワークフロー: **Deploy Database to Supabase (Staging)**

本番の **Deploy Database to Supabase** は使用しません。本番用ワークフローは変更していません。

## 事前に登録するSecrets

GitHub → Settings → Environments → staging → Environment secrets に、次の3件を**それぞれ**登録してください。

| 名前 | 内容 |
| --- | --- |
| `SUPABASE_PROJECT_ID` | `wpoigmywpewrrbudqhgh`（引用符・空白なし） |
| `SUPABASE_DB_PASSWORD` | 検証用DBのパスワード |
| `SUPABASE_ACCESS_TOKEN` | 検証プロジェクトだけに対象を限定したSupabase管理用トークン |

GitHubの仕様上、同名の環境SecretがなければRepository/Organization Secretにフォールバックします。ワークフローからSecretの保存元は識別できません。このため、3件ともstagingに明示登録し、トークンの対象も検証用だけに限定してください。スクリプトはプロジェクトID不一致を接続前に拒否し、CLIがリンクした先も再確認しますが、トークンの権限範囲そのものは検査しません。

公開キーやVercel Tokenは `SUPABASE_ACCESS_TOKEN` ではありません。値をログ・チャット・コードに出さないでください。有効期限前にトークンを更新してください。権限不足はエラーを確認して必要な権限だけ追加し、安易に全権限へ切り替えないでください。

## いつ実行されるか

このワークフローを含むコミットを `develop` にプッシュすると、初回のテスト・計画・**実際のDB反映**が自動で始まります。以降はDB・デプロイスクリプト・安全性テスト・専用ワークフローに変更があったときだけ実行されます。画面だけの変更では動きません。

手動実行は、このファイルがGitHubのデフォルトブランチにも存在してから利用できます（developだけにある段階でRun workflowが表示されないのは正常です）。手動実行時は必ずブランチを `develop` にし、`apply_changes` を選びます。

- false（初期値）: 接続確認と反映予定の表示のみ。テーブルや関数は作りません。
- true: 反映予定の確認が成功したら、テーブル・関数を実際に反映します。

mainを選んで手動実行してもジョブはスキップされます。

## 処理の順番

1. GitHubランナーの一時DBで全マイグレーションを最初から実行。
2. `supabase/tests` のアクセス制限テストを実行。
3. 別ジョブでstagingのSecretsを読み、接続先・必須値を検査。
4. 検証プロジェクトにリンクし、その結果が指定IDと一致するか検査。
5. `db push --dry-run --include-all` で未適用ファイルを確認。
6. applyの場合だけ、同じ未適用ファイルを反映。
7. `session-guard`、`delete-account`、`admin-delete-account` を検証プロジェクトに配置。

クラウドDBにresetは行いません。DBリセットはSecretsを渡していないGitHubランナーの一時DBに限定しています。dry-runはSQLの実行結果を保証するものではないため、一時DBの構築とテストも必須です。

SQLは複数ファイル全体で一括トランザクションにはなりません。途中で失敗した場合は後続処理を停止しますが、成功済みの変更は残り得ます。エラーを修正し、適用履歴と次のdry-runを確認してから再実行してください。`--include-all` は後から追加された古い日付の未適用ファイルも対象にします。

## 完了確認と、まだ必要な設定

Actionsのvalidate/deployが成功し、SummaryのModeが `apply` であることを確認します。plan成功だけではDB構築完了ではありません。

- 検証用Table Editorに `profiles` / `posts` 等がある。
- 検証用Edge Functionsに上記3関数がある。
- Google・XのProvider設定、Site URL、Redirect URLsは別途管理画面で設定する。
- 関数固有の追加Secretsやスケジュール等が必要なら、別途設定と動作確認を行う。
- GitHub stagingの `SUPABASE_URL` / `SUPABASE_ANON_KEY` / `SUPABASE_REDIRECT_URL` と、Vercel PreviewのURL・公開キーを検証用に切り替える。
- **Deploy Flutter Web to Vercel (Staging)** を再実行する。このDBワークフローはWebサイトを再デプロイしない。
- 検証アカウントでログインし、データが検証用DBだけに作られることを確認する。

本番ユーザーのデータ・ログイン情報・画像はコピーしません。DB構築ファイルに含まれる固定の設定や権限ルールは適用されます。

## 手元の同期ファイルについて

`example 2.sql` のような同期コピーや同じ日時の重複マイグレーションは検査で拒否します。今回見つかった既存ファイルの削除状態・同期コピーは、この追加作業では変更していません。コミット時は新しい専用ファイルだけを選び、`git add .` で秘密情報や同期コピーをまとめて登録しないでください。

# shared-skills

複数 Replit プロジェクトから共有する Agent スキル集。各サブディレクトリが 1 つのスキル
（例: `ecforce/`）で、配下に `SKILL.md` を置く。Replit Agent は `.local/skills/<name>/SKILL.md`
を自動で読みに行くので、各プロジェクトで以下のスクリプトを実行するだけで最新版が
取り込まれる。

## 使い方（各プロジェクト側）

1. プロジェクトのシークレットに以下を設定する：
   - `SHARED_SKILLS_REPO` = `<owner>/<repo>` （このリポジトリの GitHub パス）
   - （任意）`SHARED_SKILLS_REF` = ブランチ・タグ・SHA（既定 `main`）
   - （任意）`SHARED_SKILLS_NAME` = 同期するスキル名のスペース区切り（既定 `ecforce`）
   - （任意 / private repo の場合）`SHARED_SKILLS_GITHUB_TOKEN` = GitHub の PAT

2. 同期スクリプト `scripts/sync-shared-skills.sh` をプロジェクトに置く
   （このリポジトリの兄弟プロジェクトからコピーするか、新規 Repl ならこの README から
   コピペ）。

3. 1 回手動で実行：

   ```bash
   pnpm run sync:shared-skills
   # または bash scripts/sync-shared-skills.sh
   ```

これで `.local/skills/ecforce/SKILL.md` が作られる。以降は post-merge フックや
任意のタイミングで再実行することで最新化される。

## このリポジトリの更新フロー

1. このリポジトリで `<name>/SKILL.md` を編集して push（main 直 push か PR マージ）。
2. 各プロジェクト側で `pnpm run sync:shared-skills` を実行（または post-merge を発火）。
3. それだけ。各プロジェクトの中身は触らない。

## 各プロジェクトの `replit.md` に追記すべき恒久ルール（必須）

  各プロジェクトのエージェントに「ecforce API を触る前に必ずこのスキルを読み、終わったら新事実をここへ書き戻す」習慣を強制するため、各プロジェクトの `replit.md` の `## User preferences` セクションに以下のブロックを**そのまま**追記する。同期スクリプトは SKILL.md を取得するだけで読む行為や書き戻しは強制しないため、この `replit.md` ルールが運用上の本体になる。

  ```md
  ### ecforce API ナレッジ運用ルール（恒久）

  **事前読み込み（MUST: 着手前）**

  ecforce API に関係する読み取り・実装・デバッグ・実機検証のいずれかを行う前に、エージェントは中央ナレッジリポジトリ `locabo-data/ecforce-api_skills` の `ecforce/SKILL.md` を GitHub から最新版を取得して読むこと（ローカルキャッシュではなく毎セッション初回は再取得）。読まずに着手することは禁止。発火条件は以下のいずれか:

  - ecforce 関連のクライアントコード（`ecforceClient.ts` 相当 / `postVerify.ts` 相当 / その他 ecforce へ HTTP を出すモジュール）を読む / 編集する
  - ecforce の任意のエンドポイント（`/api/v2/admin/*`）を新規に叩く / 既存呼び出しを変更する
  - `Authorization: Token token="..."` ヘッダー、`bulk_update`、`payment_state`、`tbc`、`memo01`、`label_ids`、`notes_attributes`、与信審査ポーリング、自動化ルールに関する実装・デバッグ
  - ユーザーから「ecforce API が動かない / 反映されない / レート制限に当たる」等の相談を受けた

  GitHub 連携が未接続なら、まず `connector:github` を `proposeIntegration` で接続してから読む。読んだ後、該当する MUST / MUST NOT ルール（§0 G1〜）を実装方針に明示的に反映してから着手する。

  **事後更新（MUST: タスクの一部として）**

  ecforce API に関係する実機検証で確定した新しい事実を得たら、エージェントは以下をそのタスクの一部として必ず実行する。

  1. 中央ナレッジリポジトリ `locabo-data/ecforce-api_skills` の `ecforce/SKILL.md` を取得し、該当箇所を更新する（追記 / 修正 / グローバルルール表 G1〜 への追加）。
  2. 既存セクションの構造（§0 ルール表 / エンドポイント節の `METHOD/PATH/REQUEST/RULES` / `payment_state` 辞書 / 定数表）を維持し、AI が読む前提の構造化フォーマットで書く（人間向けの語り口・体験談・重複は入れない）。
  3. GitHub への書き込み前に意図確認（ユーザーへの宣言）を行ったうえで PUT。コミットメッセージは `docs(ecforce): <変更要点>` 形式。
  4. 矛盾が出たら新しい実機検証側を正として上書きする（旧記述を残さない）。
  5. 「コード変更だけして SKILL.md を更新しない」「新規ファイル `docs/*.md` を作って逃げる」のは禁止。必ず `ecforce/SKILL.md` 本体に統合する。
  ```

## スキル一覧

- `ecforce/` — ecforce 管理 API（認証ヘッダー仕様、bulk_update、トークン管理、
  よくある落とし穴）

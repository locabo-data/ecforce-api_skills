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

## スキル一覧

- `ecforce/` — ecforce 管理 API（認証ヘッダー仕様、bulk_update、トークン管理、
  よくある落とし穴）

---
name: ecforce
description: ecforce (EC構築プラットフォーム) の管理 API 連携ナレッジ。認証ヘッダー仕様、トークン管理、顧客一括更新エンドポイント、よくある落とし穴をまとめる。ecforce にリクエストを送る／ecforce から webhook を受ける処理を実装・デバッグするときに読む。
---

# ecforce API 連携スキル

このスキルは「ecforce の管理 API を別システムから叩く」ときに繰り返し必要になる
事実をまとめたもの。エンドポイント単位の細かい仕様は ecforce 公式ドキュメントが
正だが、ここには「ドキュメントを毎回読み返さなくても動くまで持っていける」だけの
最低限を置く。新しい知見が出たらこの SKILL.md（中央リポジトリ側）を更新する。

## 認証

- 認証ヘッダーの形式は **`Authorization: Token token="<API_TOKEN>"`** （Rails の
  `acts_as_token_authenticatable` 系の標準）。`Bearer` ではない点に注意。
- トークンは ecforce の管理画面で API ユーザーごとに発行する。失効・ローテーションは
  管理画面側の操作なので、システム側はトークンを 1 環境変数で扱えれば十分。
- ストレージ：必ずシークレット（Replit Secrets 等）に置く。DB やコードに直書きしない。
  推奨の env 名：`ECFORCE_API_TOKEN`。
- 失敗時の典型レスポンス：401 / 403 が返るときはトークン未設定 or 期限切れ or
  該当 API ユーザーに権限がない。`Token token=""`（空）でもサーバーは 401 を返す。

### このプロジェクトでの実装ポイント

- `process.env.ECFORCE_API_TOKEN` をそのまま使う。未設定時はそのステップを `failed`
  にして以降を `skipped` にする（`artifacts/api-server/src/lib/jobs.ts` の
  `SECRET_RESOLVERS.ecforce_token`）。
- HTTP ステップに `auth_service: "ecforce"` を指定すると、実行時に
  `Authorization: Token token="<token>"` が自動で付く。ユーザーが Authorization
  ヘッダーを手で書く必要はなく、UI のヘッダー一覧からも隠している。
- 旧データ互換：Authorization ヘッダーに `{{secrets.ecforce_token}}` または
  `Token token=""`（空テンプレ）が入っている場合、GET 時に `auth_service: "ecforce"`
  へ自動推定変換する（`inferAuthServiceFromHeader`）。リテラル値が入っているものは
  ユーザーが意図的に静的トークンを使っている可能性があるので触らない。

## エンドポイント

### 顧客一括更新（線形検索→一括 PUT）

- **URL**: `PUT https://<ショップドメイン>/api/v2/admin/customers/bulk_update`
- **用途**: LINE user id・LIFF 取得値・タグなどを ecforce 顧客に紐付ける。
- **特徴**: 1 リクエストで複数顧客を更新できる。`customers[].id` が更新対象の
  キー（ecforce 内部の customer_id）。

#### 動いた最小ペイロード

```json
{
  "customers": [
    {
      "id": "12345",
      "link_number": "U1234567890abcdef..."
    }
  ]
}
```

- `id` は **文字列でも数値でも受け付ける**が、間違った id を投げても 200 が返ること
  があるため「投げたら必ず取得して確認」するのが安全。
- `link_number` は LINE user id を入れる用途で使うのが ecforce 標準。

#### curl サンプル

```bash
curl -X PUT "https://<ショップドメイン>/api/v2/admin/customers/bulk_update" \
  -H "Authorization: Token token=\"$ECFORCE_API_TOKEN\"" \
  -H "Content-Type: application/json" \
  -d '{
    "customers": [
      { "id": "12345", "link_number": "U1234567890abcdef..." }
    ]
  }'
```

## ショップドメイン

- 「ショップドメイン」は店舗ごとに違う（例: `shop.example.com`）。施策ごとに保存して
  テンプレートに差し込む運用にする。
- このプロジェクトでは campaign の `config.shop_domains.ecforce` に保存し、
  テンプレ URL の `<ショップドメイン>` / `<ecforce-domain>` プレースホルダを
  実行前に差し替えている（`artifacts/api-server/src/routes/campaigns.ts` の
  `applyShopDomainsToSteps`）。
- 入力は `https://` 付き / `/` 末尾付き / 裸ドメイン のどれでも受け、`normalizeDomain`
  で `shop.example.com` 形式に揃える。

## レート制限・タイムアウト

- ecforce 公式の RPS は非公開だが、**1 RPS 程度に絞ると安定**する。バーストすると
  502 / 504 / Cloudflare の遮断が時々起きる。
- このプロジェクトでは `HostRateLimiter` で送信先ホスト単位に 1 RPS スロットルを
  かけている。HTTP は `AbortController` で 30 秒タイムアウト。
- 5xx / 429 は指数バックオフでリトライしている（`WEBHOOK_HTTP_DEFAULT_MAX_RETRIES`）。
  Retry-After ヘッダーがあれば優先する。

## ペイロードのテンプレート化

- このプロジェクトのテンプレ施策 `line_ecforce_repeatline` では受信 webhook
  ペイロードから ecforce 顧客 id と LINE user id を取り出して投げている：

```json
{
  "customers": [
    {
      "id": "{{payload.data.tracking_params.customer_id}}",
      "link_number": "{{payload.data.line_user_id}}"
    }
  ]
}
```

- `{{payload.foo.bar}}` 形式の自前テンプレートエンジン。配列添字も可。値が非文字列
  なら `JSON.stringify` される。
- `{{secrets.ecforce_token}}` は実行時に環境変数のトークンに置換される。

## よくある落とし穴

- **`Bearer` で送ってしまう**：他社 API の癖で `Bearer <token>` を書きがちだが
  ecforce は受け付けない。必ず `Token token="<token>"`。
- **id を数値か文字列か混在させる**：JSON 上はどちらでも通るが、ecforce 側の
  customer_id が文字列前提のショップだと予期しない一致になりうる。文字列に統一推奨。
- **空トークンで送る**：`Token token=""` も 200 を返す API が一部あるが大半は 401。
  デプロイ後に「なぜか動かない」のだいたい 7 割はこれ。Secrets タブで設定後は
  API サーバー再起動を忘れない。
- **タグ・カスタムフィールドの全件消し**：差分指定 API（upsert_xxx / delete_xxx）で
  delete を空配列にせず指定漏れすると既存値が消えるケースがある。雛形では
  必ず `delete_tags: []` `delete_custom_fields: []` を明示する。
- **Cloudflare の WAF**：日本語 UA や空 UA で時々 1020 / 403 を返す。
  `User-Agent` を明示するとマシになる。
- **HTTPS 必須**：`http://` で叩くとリダイレクトが返るだけでなく Cookie が落ちて
  認証セッション扱いになるケースがあるので必ず `https://`。

## デバッグ手順

1. まず `curl` で素のリクエストが通るか。401 ならトークン or 権限の問題。
2. 通ったら body に `{{...}}` を入れて、サーバーログのリクエストペイロードを確認。
   テンプレ置換後の値が想定どおりかを最優先で見る。
3. ecforce 側で更新されたかは ecforce 管理画面の顧客詳細を直接確認。
   API が 200 を返しても反映タイミングのズレで一見更新されないことがある。

## このプロジェクトを参考にしたい場合

- `artifacts/api-server/src/lib/jobs.ts` — シークレット解決・認証ヘッダー自動付与
- `artifacts/api-server/src/routes/campaigns.ts` — テンプレ施策生成・ドメイン差し込み
- `artifacts/api-server/src/routes/app-settings.ts` — `ECFORCE_API_TOKEN` の有無判定

---
name: ecforce
description: ecforce 管理 API (`/api/v2/admin`) を叩くときに参照する規約集。認証ヘッダー (`Token token="..."`)、JSON:API レスポンス、受注検索 (`GET /orders.json`)、決済再処理 (`bulk_update method=void|reauth`)、支払い方法変更・注文確定・倉庫連携待ち (`PUT /orders/:id`)、顧客一括更新 (`PUT /customers/bulk_update`)、顧客メモ追加 (`PUT /customers/:id` の `notes_attributes`)、`tbc` (要対応) が API では書き込めず管理画面の自動化ルール + GET ポーリングで反映を待つ必要があること、与信審査ポーリング、レート制御・リトライ、`payment_state` 値辞書をカバー。ecforce へ HTTP を出す/受ける実装・デバッグの前に必ず読む。
---

# ecforce API スキル (AI 向け仕様)

このドキュメントは LLM エージェントが ecforce 管理 API を叩く前に参照する規約。
散文より「規則」「テーブル」「コードブロック」を優先する。新しい実機検証で
得た事実は追記する。**矛盾が生じたら新しい実機検証側を正とする**。

---

## 0. グローバルルール (MUST / MUST NOT)

| #  | 種類       | ルール                                                                                                         |
| -- | ---------- | -------------------------------------------------------------------------------------------------------------- |
| G1 | MUST       | 認証ヘッダーは `Authorization: Token token="<TOKEN>"`。`Bearer` 不可。                                         |
| G2 | MUST       | リクエストは逐次。並列化しない。                                                                               |
| G3 | MUST       | 429 / 500 はリトライ。`Retry-After` ヘッダーがあれば常に優先。                                                 |
| G4 | MUST       | ベース URL を組むときは `RAW_BASE_URL.replace(/\/+$/, "")` で末尾スラッシュを除去してから `/api/v2/admin` を連結。 |
| G5 | MUST       | 書き込み後の検証は別 GET で行う。HTTP 200 は「ペイロードが受理された」ではなく「リクエストが届いた」しか意味しない。 |
| G6 | MUST NOT   | `tbc` を API で書き込もうとしない (silently 無視され HTTP 200 で帰ってくる)。                                  |
| G7 | MUST NOT   | 受注ラベル `label_ids` を API から付け外ししない (不可)。代替に `memo01` を使う。                              |
| G8 | MUST NOT   | `bulk_update method=void` で `decrement_subs_order_times` / `recalculate_subs_order` を省略しない (定期回数が壊れる)。 |
| G9 | MUST NOT   | `GET /orders.json` で `scheduled_to_be_shipped_at_eq=...` を使わない (datetime 型で取りこぼし)。`_gteq`+`_lt` 半開区間を使う。 |
| G10| MUST NOT   | 顧客メモを `{ "note": {...} }` や `customer.customer_notes_attributes` で送らない。正解は `customer.notes_attributes`。 |
| G11| MUST NOT   | `meta.total_pages` を単独で信用しない。最終ページ判定 (`data.length < per`) とハード上限を併用。              |

---

## 1. 認証

```http
Authorization: Token token="<API_TOKEN>"
Content-Type: application/json
Accept: application/json
```

| 項目             | 値                                                                       |
| ---------------- | ------------------------------------------------------------------------ |
| ヘッダー形式     | `Token token="<TOKEN>"` (Rails `acts_as_token_authenticatable` 系の標準) |
| 推奨 env 名      | `ECFORCE_API_TOKEN` (歴史的経緯で `ECFORCE_API_KEY` のプロジェクトもある — 値の意味は同じ) |
| 401 / 403 の原因 | トークン未設定 / 期限切れ / API ユーザー権限不足 / `Token token=""` 空    |

このリポジトリ側の実装フック (LINE webhook 施策側):

- `process.env.ECFORCE_API_TOKEN` をそのまま参照。未設定時はそのステップを `failed` にして以降を `skipped` (`artifacts/api-server/src/lib/jobs.ts` の `SECRET_RESOLVERS.ecforce_token`)。
- HTTP ステップで `auth_service: "ecforce"` を指定すると `Authorization` ヘッダーが自動付与され、UI の手書きヘッダー一覧からは隠れる。
- 旧データ互換: `{{secrets.ecforce_token}}` / `Token token=""` のヘッダーは GET 時に `auth_service: "ecforce"` へ自動推定変換 (`inferAuthServiceFromHeader`)。リテラル値はユーザー意図とみなして触らない。

---

## 2. ベース URL とレスポンス形式

| 項目                  | 値                                                          |
| --------------------- | ----------------------------------------------------------- |
| ベース URL            | `https://<ショップドメイン>/api/v2/admin`                   |
| レスポンス形式        | [JSON:API](https://jsonapi.org/) (`data` / `included` / `meta`) |
| 単一リソース          | `data: JsonApiResource`                                     |
| コレクション          | `data: JsonApiResource[]`、`included: JsonApiResource[]`    |
| 関連リソース解決      | `relationships.<rel>.data.id` → `included` 内の同 `type`+`id` |

ショップドメインの扱い:

- 店舗ごとに異なる (例: `shop.example.com`)。施策ごとに保存してテンプレに差し込む。
- このプロジェクトでは `campaign.config.shop_domains.ecforce` に保存し、
  URL テンプレ中の `<ショップドメイン>` / `<ecforce-domain>` を実行前に差し替える
  (`artifacts/api-server/src/routes/campaigns.ts` の `applyShopDomainsToSteps`)。
- 入力は `https://` 付き / `/` 末尾 / 裸ドメイン のどれでも受け、`normalizeDomain` で `shop.example.com` 形式に揃える。

---

## 3. レート制御・タイムアウト・リトライ

| 項目                       | 推奨値                       | 備考                                                              |
| -------------------------- | ---------------------------- | ----------------------------------------------------------------- |
| RPS                        | 0.5〜1 (= 1,000〜2,000 ms 間隔) | 書き込み比率が高いなら 2,000 ms (=0.5 RPS) 側に倒す                |
| HTTP タイムアウト          | 30 s (`AbortController`)     |                                                                   |
| リトライ対象               | `429`, `5xx`                  | `500` は `AOR9999` 等の一時エラーが混じるため同テーブルで扱う      |
| リトライ間隔               | `[3s, 5s, 15s]` (最大 3 回)  | `Retry-After` ヘッダーがあれば常に優先                            |
| HTML レスポンスのログ整形  | `<title>` だけ抜き出してログ | Cloudflare 等のブロックページで生 HTML を吐かない                  |

---

## 4. エンドポイント

各エンドポイントは「METHOD / PATH / REQUEST / RESPONSE NOTES / RULES」で記述する。

### 4-1. 顧客一括更新

| 項目     | 内容                                                                   |
| -------- | ---------------------------------------------------------------------- |
| METHOD   | `PUT`                                                                  |
| PATH     | `/customers/bulk_update`                                               |
| 用途     | LINE user id / LIFF 取得値 / タグ などを ecforce 顧客に紐付ける         |

REQUEST (最小):

```json
{
  "customers": [
    { "id": "12345", "link_number": "U1234567890abcdef..." }
  ]
}
```

RULES:

- `customers[].id` は文字列・数値どちらでも受理されるが、**文字列に統一**することで取り違え事故を防ぐ。
- 間違った id を投げても 200 が返ることがある → 必ず別 GET で確認 (G5)。
- `link_number` は LINE user id を入れる ecforce 標準のフィールド。
- 差分指定 API (`upsert_xxx` / `delete_xxx`) を併用する場合、`delete_tags: []` / `delete_custom_fields: []` を **必ず空配列で明示**。指定漏れすると既存値が消える事故。

curl サンプル:

```bash
curl -X PUT "https://<ショップドメイン>/api/v2/admin/customers/bulk_update" \
  -H "Authorization: Token token=\"$ECFORCE_API_TOKEN\"" \
  -H "Content-Type: application/json" \
  -d '{ "customers": [ { "id": "12345", "link_number": "U..." } ] }'
```

### 4-2. 受注検索

| 項目     | 内容                                                                                                         |
| -------- | ------------------------------------------------------------------------------------------------------------ |
| METHOD   | `GET`                                                                                                        |
| PATH     | `/orders.json`                                                                                               |
| 用途     | 配送予定日 + 支払い方法 + 失敗系 payment_state で受注を抽出                                                  |

QUERY (決済再処理ツールの例):

```
include=billing_address
&per=100                                          # 上限 100 で頭打ち
&page=N                                           # 1 始まり
&q[scheduled_to_be_shipped_at_gteq]=YYYY-MM-DD
&q[scheduled_to_be_shipped_at_lt]=YYYY-MM-DD     # 翌日 (半開区間)
&q[payment_payment_method_id_eq]=58
&q[state_eq]=complete
&q[payment_state_in][]=auth_failed
&q[payment_state_in][]=update_failed
&q[payment_state_in][]=credit_exam_failed
```

RULES:

- `scheduled_to_be_shipped_at` は datetime 型。`_eq` 不可 (G9)。`_gteq` + `_lt` の半開区間で当日全体を拾う。
- `per` の上限は 100。
- ページング終了判定は次の三段で守る:
  1. `meta.total_pages` が信頼できる (>0) なら `page >= total_pages` で終了。
  2. 上が無いなら `data.length < per` で終了。
  3. それでも止まらないケースに備え、ハード上限 (例: 1,000 ページ = 100,000 件)。
- `billing_address` の氏名は `included[type=address]` を `relationships.billing_address.data.id` で引いて `full_name` → なければ `name01 + " " + name02`。

### 4-3. 単一受注 GET

| 項目     | 内容                                          |
| -------- | --------------------------------------------- |
| METHOD   | `GET`                                         |
| PATH     | `/orders/:id.json`                            |
| 用途     | `payment_state` 確認 / `customer_id` 取り出し |

RESPONSE NOTES:

- `payment_state`: `data.attributes.payment_state`
- `customer_id` は **2 系統フォールバック必須**:
  1. `data.attributes.customer_id` (数値 or 数字文字列)
  2. なければ `data.relationships.customer.data.id`

### 4-4. 決済再処理 (`bulk_update`)

| 項目     | 内容                                              |
| -------- | ------------------------------------------------- |
| METHOD   | `POST`                                            |
| PATH     | `/orders/payment_status/bulk_update.json`         |
| 用途     | 決済キャンセル (`method=void`) / 再オーソリ (`method=reauth`) |

REQUEST `method=void` (G8 必須):

```json
{
  "method": "void",
  "order_ids": [12345],
  "decrement_subs_order_times": 0,
  "recalculate_subs_order": 0
}
```

REQUEST `method=reauth` (定期保護フラグは送らない):

```json
{ "method": "reauth", "order_ids": [12345] }
```

RULES:

- `void`: `decrement_subs_order_times: 0` / `recalculate_subs_order: 0` を**必ず**付ける。落とすと定期回数が `-1` され、次回お届け日が動く事故になる (G8)。
- `reauth`: 上記 2 フラグは無効。送らない。
- `reauth` 後は §5 のポーリングで `payment_state=credit_exam_completed` を待つ。

### 4-5. 受注更新 (`PUT /orders/:id`)

| 用途                | REQUEST                                                                              |
| ------------------- | ------------------------------------------------------------------------------------ |
| 支払い方法変更      | `{ "order": { "payment_attributes": { "payment_method_id": <id> } } }`               |
| 注文確定 + メモ書き | `{ "order": { "state": "complete", "memo01": "<マーカー文字列>" } }`                 |
| 注文確定のみ        | `{ "order": { "state": "complete" } }`                                               |
| 倉庫連携待ち遷移    | `{ "order": { "state": "wmswait" } }` / `{ "order": { "state": "cooolawait" } }`     |

RULES:

- `memo01` (受注備考1) は API で即書き換え可能。再処理済みマーカー文字列を入れて管理画面検索に使うのが定石。既存値は単純上書きされる。
- `label_ids` (受注ラベル) は API 不可 (G7)。代替に `memo01` を使う。
- `tbc` をペイロードに含めても **silently 無視** される (G6)。詳細は §6。
- `wmswait` / `cooolawait` への遷移は `payment_state=credit_exam_completed` を確認したあと。

`state` 値:

| 値           | 意味                            |
| ------------ | ------------------------------- |
| `complete`   | 注文確定                        |
| `wmswait`    | 倉庫連携待ち (FJロジ)           |
| `cooolawait` | 倉庫連携待ち (塚本郵便逓送)     |

### 4-6. 顧客メモ追加

| 項目     | 内容                                          |
| -------- | --------------------------------------------- |
| METHOD   | `PUT`                                         |
| PATH     | `/customers/:customer_id.json`                |

REQUEST (G10 厳守):

```json
{
  "customer": {
    "notes_attributes": [
      {
        "content":     "<本文>",
        "operated_at": "2019/06/08 05:47:17",
        "operated_by": 12345
      }
    ]
  }
}
```

RULES:

- 正しいキー名は `customer.notes_attributes`。以下は **すべて silently 無視される** (HTTP 200 だがメモは作成されない):
  - トップレベル `{ "note": {...} }`
  - `customer.customer_notes_attributes`
- `operated_at` は **`YYYY/MM/DD HH:MM:SS`** (区切りは `/`)。Asia/Tokyo:
  ```ts
  new Intl.DateTimeFormat("ja-JP", {
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
    hour12: false, timeZone: "Asia/Tokyo",
  }).formatToParts(new Date());
  ```
- `id` を省略すると新規追加。

---

## 5. 与信審査ポーリング (`reauth` 後)

`reauth` 直後の `payment_state` はほぼ `credit_exam_processing`。完了まで数秒〜十数秒の遅延あり。

手順:

1. `reauth` 後に **5,000 ms** 固定待機 (`POST_REAUTH_INITIAL_WAIT_MS`)。
2. `GET /orders/:id.json` でポーリング:
   - `credit_exam_completed` → 成功。
   - `credit_exam_processing` → 2,000 ms sleep → リトライ (最大 15 回 ≈ 30 s)。
   - それ以外 (`credit_exam_failed` 等) → 与信審査エラーとして上位でリカバリ分岐。

旧形式エラーメッセージにも注意:

- 「決済状況が credit_exam_completed ではありません…」という**文字列**で返るケースがある。
- 値だけで判定すると分岐に流れないので、上記文字列も `credit_exam_failed` 相当として扱う。

---

## 6. `tbc` (要対応) は API で書き込めない【最重要】

| 項目                  | 内容                                                                                       |
| --------------------- | ------------------------------------------------------------------------------------------ |
| 書き込み可否          | **不可** (HTTP 200 で帰るが silently 無視。再 GET すると値は変わっていない)                |
| 対象ペイロード        | `PUT /orders/:id` の `order.tbc` / `PUT /subs_orders/:id` の `subs_order.tbc` / `PUT /subs_orders/bulk_update.json` の `tbc` すべて |
| 原因 (推定)           | Rails strong_parameters で silently 弾かれている (同形式で `memo01` は persist する)        |
| 解決策                | 管理画面の **自動化ルール** + GET ポーリングで反映を待つ                                  |

運用中の自動化ルール例 (実機確認済み):

> **ルール #9**: 受注の決済状況が「与信審査完了」になったとき → 定期受注の要対応を解除する

特性:

| 項目                  | 値                                       |
| --------------------- | ---------------------------------------- |
| トリガー              | `payment_state` → `credit_exam_completed` |
| 実行                  | 非同期                                   |
| 反映遅延 (実測)       | ≈24 秒                                   |
| 確認方法              | `GET /subs_orders/:id.json` の `tbc`     |

クライアント側のラウンド方式 GET ポーリング:

```
round 1: wait  0 s → 対象全件 GET
round 2: wait  5 s → 未反映分のみ GET
round 3: wait 10 s → 未反映分のみ GET
round 4: wait 15 s → 未反映分のみ GET   (累計 30 s)
```

`tbc` の真偽判定は防御的に。以下はすべて「解除済み」とみなす:

```ts
tbc === false || tbc === 0 || tbc === "false" || tbc === "0" || tbc === null || tbc === undefined
```

過去の偽陰性事例: 本番ログで 22 件中 8 件が「tbc 解除未反映」エラーになったが、
後刻 GET し直すと全件 `tbc=false`。原因は (1) 無効な PUT を投げていた、
(2) 反映遅延を待ち切れていなかった、の 2 点。両方とも上記設計で解消。

---

## 7. `payment_state` 値辞書

| `payment_state`            | 日本語          | リカバリ対象? |
| -------------------------- | --------------- | ------------- |
| `auth_failed`              | 仮売上失敗      | ✅            |
| `update_failed`            | 取引修正失敗    | ✅            |
| `credit_exam_failed`       | 与信審査エラー  | ✅            |
| `credit_exam_processing`   | 与信審査中      | ポーリング継続 |
| `credit_exam_hold`         | 与信保留        | -             |
| `credit_exam_completed`    | 与信審査完了    | -             |
| `authed`                   | 仮売上完了      | -             |
| `captured`                 | 売上確定        | -             |
| `voided`                   | 取引キャンセル  | -             |
| `paid`                     | 入金済み        | -             |

---

## 8. 推奨ステップ設計 (決済再処理ツール: NP → バモス 切替)

成功パスと自動リカバリパスを併記。

```
① 対象抽出          GET /orders.json (§4-2)
② 決済キャンセル     POST bulk_update method=void (§4-4)
③ 支払い方法変更    PUT /orders/:id payment_attributes (§4-5)
④ 再オーソリ        POST bulk_update method=reauth (§4-4)
⑤ 与信審査完了確認  GET /orders/:id でポーリング (§5)
   ├─ credit_exam_completed → 成功パス ⑥ へ
   └─ credit_exam_failed / 旧文言 → リカバリパス R1 へ
⑥ 注文確定 + メモ   PUT /orders/:id { state:"complete", memo01:"<マーカー>" } (§4-5)
⑦ 倉庫連携待ち遷移  PUT /orders/:id { state:"wmswait"|"cooolawait" } (§4-5)
⑧ 顧客メモ追加      PUT /customers/:id notes_attributes (§4-6)
⑨ バッチ末尾検証    GET /subs_orders/:id tbc ラウンドポーリング (§6)
```

リカバリパス R1 (④ が `credit_exam_failed` のとき):

```
R1-1 決済キャンセル        POST bulk_update method=void
R1-2 支払い方法を戻す      PUT /orders/:id payment_attributes (元の方法)
R1-3 再オーソリ            POST bulk_update method=reauth
R1-4 与信審査完了確認      GET /orders/:id ポーリング
R1-5 注文確定のみ          PUT /orders/:id { state:"complete" }  ← tbc は触らない
                          (ルール #9 は発火しないので「要対応」は維持され、人間レビュー待ちになる — これが正しい挙動)
```

---

## 9. ペイロードのテンプレート化 (LINE webhook 施策側)

テンプレ施策 `line_ecforce_repeatline` の例:

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

- `{{payload.foo.bar}}` 形式の自前テンプレートエンジン。配列添字 (`foo.0.bar`) も可。
- 値が非文字列なら `JSON.stringify` される。
- `{{secrets.ecforce_token}}` は実行時に環境変数のトークンに置換される。

---

## 10. デバッグ手順

1. `curl` で素のリクエストが通るか確認。401 ならトークン / 権限。
2. テンプレ化されたボディはサーバーログで置換後の値を確認 (テンプレ置換ミスがいちばん多い)。
3. ecforce 管理画面の対象リソース詳細で実反映を確認 (HTTP 200 = 反映、ではない: G5)。
4. `tbc` 系で「反映されない」と言われたらまず `GET /subs_orders/:id.json` を `[0, 5, 10, 15]` 秒の累計 30 s スパンで叩き直す (§6)。

---

## 11. 参考実装

LINE webhook 施策側 (このリポジトリの周辺コード):

- `artifacts/api-server/src/lib/jobs.ts` — シークレット解決・認証ヘッダー自動付与
- `artifacts/api-server/src/routes/campaigns.ts` — テンプレ施策生成・ドメイン差し込み
- `artifacts/api-server/src/routes/app-settings.ts` — `ECFORCE_API_TOKEN` の有無判定

決済再処理ツール側:

- `artifacts/api-server/src/lib/ecforceClient.ts` — 認証 / 2,000 ms レート制御 / `[3s,5s,15s]` リトライ / `getTargetOrders` の半開区間ページング / `bulk_update` (void / reauth) / `PUT /orders/:id` (支払い方法変更・注文確定・倉庫連携待ち) / `getSubscriptionTbc` / `addCustomerNote` 公式仕様準拠
- `artifacts/api-server/src/lib/postVerify.ts` — バッチ末尾の `tbc` ラウンド GET ポーリングで「成功確定 / 失敗降格」を切り替える純粋ロジック
- `artifacts/api-server/src/routes/orders.ts` — 上記を組み合わせた ①〜⑨ オーケストレーションと `credit_exam_failed` 検出時の R1 分岐

---

## 12. 定数表 (決済再処理ツール実装値)

| 名前                                  | 値                              | 用途                                                       |
| ------------------------------------- | ------------------------------- | ---------------------------------------------------------- |
| `RATE_LIMIT_MS`                       | `2000`                          | リクエスト間隔の下限                                       |
| `RETRY_DELAYS_MS`                     | `[3000, 5000, 15000]`           | 429 / 500 リトライ間隔                                     |
| `RETRY_MAX_ATTEMPTS`                  | `3`                             | 429 / 500 リトライ最大試行                                 |
| `PAGE_SIZE`                           | `100`                           | `per` パラメータ (ecforce 側上限)                          |
| `MAX_PAGES`                           | `1000`                          | 受注検索の安全上限 (= 最大 100,000 件)                     |
| `POST_REAUTH_INITIAL_WAIT_MS`         | `5000`                          | 再オーソリ後の初期待機                                     |
| `VERIFY_POLL_INTERVAL_MS`             | `2000`                          | 与信審査完了ポーリング間隔                                 |
| `VERIFY_POLL_MAX_ATTEMPTS`            | `15`                            | 与信審査完了ポーリング最大試行                             |
| `POST_BATCH_TBC_RETRY_DELAYS_MS`      | `[0, 5000, 10000, 15000]`       | バッチ末尾 `tbc` 反映ラウンドの待機列                      |

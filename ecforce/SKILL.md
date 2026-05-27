---
name: ecforce
description: ecforce (EC構築プラットフォーム) の管理 API 連携ナレッジ。認証ヘッダー仕様、トークン管理、顧客一括更新エンドポイント、受注検索 / 決済再処理 (void / reauth / 支払い方法変更) / 顧客メモ / 倉庫連携待ち遷移、`tbc` (要対応) フラグが API では書けないこと、自動化ルールと GET ポーリングでの整合性確保、よくある落とし穴をまとめる。ecforce にリクエストを送る／ecforce から webhook を受ける処理を実装・デバッグするときに読む。
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
  - 別プロジェクト（決済再処理ツール）では歴史的経緯で `ECFORCE_API_KEY` を使っている
    ものもある。値の意味は同じなので、新規プロジェクトでは `ECFORCE_API_TOKEN` に
    寄せること。
- 失敗時の典型レスポンス：401 / 403 が返るときはトークン未設定 or 期限切れ or
  該当 API ユーザーに権限がない。`Token token=""`（空）でもサーバーは 401 を返す。
- ベース URL は `https://<ショップドメイン>/api/v2/admin`。**末尾スラッシュは正規化**
  してから連結すること（`RAW_BASE_URL.replace(/\/+$/, "")` 等）。

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

## レスポンス形式

- ほとんどのエンドポイントは [JSON:API](https://jsonapi.org/) 形式
  （`data` / `included` / `meta`）。
- `data` は単一なら `JsonApiResource`、コレクションなら `JsonApiResource[]`。
- 関連リソース（顧客の住所など）は `relationships` から id を取り、`included` 配列の
  中から `type` + `id` で引き当てる必要がある。

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

### 受注検索 `GET /orders.json`

決済再処理ツールでの実運用パターン:

```
GET /api/v2/admin/orders.json?
  include=billing_address
  &per=100                          # per は 100 で頭打ち
  &page=N                           # 1 始まり
  &q[scheduled_to_be_shipped_at_gteq]=YYYY-MM-DD
  &q[scheduled_to_be_shipped_at_lt]=YYYY-MM-DD   # 翌日
  &q[payment_payment_method_id_eq]=58
  &q[state_eq]=complete
  &q[payment_state_in][]=auth_failed
  &q[payment_state_in][]=update_failed
  &q[payment_state_in][]=credit_exam_failed
```

#### 重要な落とし穴

- `scheduled_to_be_shipped_at` は **datetime 型** なので `_eq` を使うと
  `00:00:00` 完全一致になり、時刻成分が `00:00:00` でない受注（自動再スケジュール
  された受注など）を取りこぼす。**必ず `_gteq` + `_lt` の半開区間で当日全体を拾う**。
- `meta.total_pages` は欠落・`0` で返ることがある。
  「最終ページが `per` 未満なら終了」＋「`meta.total_pages` を信頼できるなら
  `page >= total_pages` で打ち切り」＋ハード上限（例: 1,000 ページ = 100,000 件）
  の三段で守る。
- `billing_address` は `relationships.billing_address.data.id` 経由で `included`
  内の `type: "address"` を引く必要がある。氏名は `full_name`、無ければ
  `name01 + " " + name02`。

#### `payment_state` 値の対応表（運用上頻出のもの）

| payment_state              | 日本語          |
| -------------------------- | --------------- |
| `auth_failed`              | 仮売上失敗      |
| `update_failed`            | 取引修正失敗    |
| `credit_exam_failed`       | 与信審査エラー  |
| `authed`                   | 仮売上完了      |
| `captured`                 | 売上確定        |
| `voided`                   | 取引キャンセル  |
| `credit_exam_completed`    | 与信審査完了    |
| `credit_exam_processing`   | 与信審査中      |
| `credit_exam_hold`         | 与信保留        |
| `paid`                     | 入金済み        |

### 決済再処理 `POST /orders/payment_status/bulk_update.json`

決済キャンセル / 再オーソリ共通の入口。`method` で挙動が切り替わる。

#### 決済キャンセル (`method=void`)

```
POST /api/v2/admin/orders/payment_status/bulk_update.json
{
  "method": "void",
  "order_ids": [<id>],
  "decrement_subs_order_times": 0,   // 定期回数を -1 しない
  "recalculate_subs_order": 0        // 定期受注を再計算しない
}
```

- 上の 2 フラグは「単発のリカバリで定期受注を壊さない」ために**必須**。落とすと
  定期回数や次回お届け日が意図せず動く。

#### 再オーソリ (`method=reauth`)

```
POST /api/v2/admin/orders/payment_status/bulk_update.json
{ "method": "reauth", "order_ids": [<id>] }
```

- `decrement_subs_order_times` / `recalculate_subs_order` は **`reauth` では無効**
  なので送らないこと。

### 支払い方法変更 / 注文確定 / 受注備考

```
PUT /api/v2/admin/orders/:id.json
{ "order": { "payment_attributes": { "payment_method_id": <id> } } }   # 支払い方法変更
{ "order": { "state": "complete", "memo01": "バモス決済変更" } }       # 注文確定 + メモ
{ "order": { "state": "wmswait" } }    # 倉庫連携待ち（FJロジ）
{ "order": { "state": "cooolawait" } } # 倉庫連携待ち（塚本郵便逓送）
```

- `memo01` (受注備考1) は **API で即書き換え可能**。再処理済みの目印（マーカー文字列）
  として使い、ecforce 管理画面の検索条件に流用するのが定石。既存値は上書きされる。
- `label_ids`（受注ラベル）は **API から付け外し不可**。代替に `memo01` を使う。
- 倉庫連携待ちへの遷移は、決済が `credit_exam_completed` であることを確認したあとに
  行うこと（早すぎると未与信のまま倉庫へ流れる）。

### 単一受注の取得 `GET /orders/:id.json`

再オーソリ後の `payment_state` 確認や、顧客メモ追加に必要な `customer_id` 取得に使う。

- `payment_state` は `data.attributes.payment_state`。
- `customer_id` は **2 系統フォールバック必須**:
  1. `data.attributes.customer_id`（数値 or 数字文字列）。
  2. なければ `data.relationships.customer.data.id`。

### 顧客メモ追加 `PUT /customers/:id.json`

公式仕様（Customer API - 顧客更新）:

```
PUT /api/v2/admin/customers/:customer_id
{
  "customer": {
    "notes_attributes": [
      {
        "content":     "<本文>",
        "operated_at": "YYYY/MM/DD HH:MM:SS",   // 例: "2019/06/08 05:47:17"
        "operated_by": <管理者ID>
      }
    ]
  }
}
```

- `id` を指定しないと新規追加される。
- **過去 2 回踏んだ罠**:
  1. トップレベル `{ "note": { ... } }` で送る → strong_parameters で破棄され、
     HTTP 200 でもメモは作成されない。
  2. `customer.customer_notes_attributes` というキー名 → 正しくは
     `notes_attributes`。
- `operated_at` は公式例どおり **`YYYY/MM/DD HH:MM:SS`** （`-` ではなく `/`）。
  Asia/Tokyo の現在時刻を
  `Intl.DateTimeFormat("ja-JP", { timeZone: "Asia/Tokyo", … })` で作ると確実。

## ⚠️ `tbc`（要対応）フラグは API では書き込めない

これは公式ドキュメントに明示されない**最重要トラップ**。

- `PUT /orders/:id.json` の `{ order: { tbc: false } }`、
  `PUT /subs_orders/:id.json` の `{ subs_order: { tbc: false } }`、
  `PUT /subs_orders/bulk_update.json` の `tbc` フィールド、いずれも
  **HTTP 200 / errors=None で成功したように見えるが、再 GET すると `tbc` は元のまま**。
- Rails の strong_parameters で silently 弾かれていると推定される（同じペイロード
  形式で `memo01` などは persist する）。
- **唯一の正解**: ecforce 管理画面側で **自動化ルール** を仕込み、
  payment_state の遷移をトリガーに ecforce 自身に `tbc` を落とさせる。
  運用中のルール例:
  > **ルール #9**: 受注の決済状況が「与信審査完了」になったとき → 定期受注の要対応を解除する。
- 自動化ルールは **非同期**。実測では payment_state を `credit_exam_completed` に
  遷移させてから `GET /subs_orders/:id.json` で `tbc=false` を読み戻せるまで
  **約 24 秒** かかる。
- したがってクライアント側のリカバリは **GET ポーリングで反映を待つ**。
  ラウンド方式（受注 1 件単位ではなくバッチ末尾に集約）が運用上効率的:
  ```
  round 1: wait 0s  → 全件 GET
  round 2: wait 5s  → 未反映分のみ GET
  round 3: wait 10s → 未反映分のみ GET
  round 4: wait 15s → 未反映分のみ GET   (累計 30s)
  ```
- `tbc` の真偽判定は防御的に: `false / 0 / "false" / "0" / null / undefined` を
  すべて「解除済み」とみなす（ecforce が型を揺らすため）。

### 偽陰性（false negative）事例

本番ログで 22 件中 8 件が「tbc 解除未反映」とエラーになったが、後刻 GET し直すと
**全件 `tbc=false`** だった。原因は (1) 無効な PUT を投げていた、(2) 反映遅延を
待ち切れていなかった、の 2 点。上記ラウンド方式で恒久対応。

## 再オーソリ後の与信審査ポーリング

`reauth` 直後の `payment_state` は `credit_exam_processing` （与信審査中）であることが
多く、`credit_exam_completed` まで数秒〜十数秒の遅延がある。

推奨パターン:

1. `reauth` 後に固定で **5 秒** 待機（`POST_REAUTH_INITIAL_WAIT_MS=5000`）。
2. `GET /orders/:id.json` でポーリング:
   - `credit_exam_completed` → 成功。
   - `credit_exam_processing` → **2 秒 sleep** 後にリトライ（最大 15 回 ≈ 30 秒、
     `VERIFY_POLL_INTERVAL_MS=2000` / `VERIFY_POLL_MAX_ATTEMPTS=15`）。
   - それ以外（`credit_exam_failed` 等）→ 与信審査エラーとして上位で分岐。

### 旧形式エラー文言にも要注意

ecforce のバージョンによっては「与信審査完了でない」状態を以下のような **エラー
メッセージ文字列** で返すことがある:

> 「決済状況が credit_exam_completed ではありません…」

これも `credit_exam_failed` 相当として扱うこと（純粋な状態値だけ見ているとリカバリ
パスが起動しない事故になる）。

## ショップドメイン

- 「ショップドメイン」は店舗ごとに違う（例: `shop.example.com`）。施策ごとに保存して
  テンプレートに差し込む運用にする。
- このプロジェクトでは campaign の `config.shop_domains.ecforce` に保存し、
  テンプレ URL の `<ショップドメイン>` / `<ecforce-domain>` プレースホルダを
  実行前に差し替えている（`artifacts/api-server/src/routes/campaigns.ts` の
  `applyShopDomainsToSteps`）。
- 入力は `https://` 付き / `/` 末尾付き / 裸ドメイン のどれでも受け、`normalizeDomain`
  で `shop.example.com` 形式に揃える。

## レート制限・タイムアウト・リトライ

- ecforce 公式の RPS は非公開。経験則:
  - **1 RPS 程度に絞ると安定**（webhook 施策側ではこちらで運用中）。
  - 決済再処理ツール側では **リクエスト間隔の下限を 2,000 ms（=0.5 RPS）** に置いた
    ところ 429 がほぼ消えた。`bulk_update` 系を含む書き込み比率が高い場合は
    こちらの設定の方が安全。
- バーストすると 502 / 504 / Cloudflare の遮断が時々起きる。並列化はせず**逐次**で
  叩くこと（ecforce 側の負荷を上げない）。
- HTTP は `AbortController` で 30 秒タイムアウト推奨。
- **429 / 500 リトライ**:
  - 5xx / 429 は指数バックオフでリトライ（webhook 側 `HostRateLimiter` ＋
    `WEBHOOK_HTTP_DEFAULT_MAX_RETRIES`）。
  - 決済再処理ツールでの実運用値: **試行ごとの待機 `[3s, 5s, 15s]`、最大 3 回**。
  - `Retry-After` ヘッダーがあれば常に優先。
  - 500 系は `AOR9999` のような一時的内部エラーが混じるので、429 と同じテーブルで
    リトライ対象に含めている。
- レスポンスが HTML（Cloudflare のブロックページ等）で返ったら、`<title>` だけ
  抜き出してログに残す（生 HTML を吐くとログが汚れる）。

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

## 推奨される処理ステップ設計（決済再処理ツール例: NP → バモス 切替）

成功パスと自動リカバリパスを併記:

1. **対象抽出**: 配送予定日 + `payment_method=58` + 失敗系 `payment_state` で検索。
2. **① 決済キャンセル** (`bulk_update method=void`, 定期保護フラグ 0 / 0)。
3. **② 支払い方法変更** (`PUT /orders/:id`, `payment_method_id` を切替先へ)。
4. **③ 再オーソリ** (`bulk_update method=reauth`)。
5. **④ 与信審査完了確認** (5s 初期待機 → 2s ポーリング)。
   - `credit_exam_completed` → 成功パスへ。
   - `credit_exam_failed`（旧文言含む）→ **自動リカバリパスへ分岐**。
6. **⑤ 注文確定 + メモ書き込み** (`state=complete, memo01="<マーカー>"`)。
   - 注意: `tbc` は送らない（送っても無視される）。
   - 同時に ecforce 側の自動化ルール #9 が非同期で `tbc` をクリアし始める。
7. **⑥ 倉庫連携待ちへ遷移** (`state=wmswait` or `cooolawait`)。
8. **⑦ 顧客メモ追加** (`notes_attributes` で追記)。
9. **⑧ バッチ末尾で `subs_order.tbc` の反映をラウンド方式 GET ポーリング** で検証。

### 自動リカバリパス（④ が credit_exam_failed のとき）

切替後の決済をキャンセルし、元の支払い方法に戻して再オーソリ → 与信審査完了確認 →
**「注文確定のみ」（要対応フラグは維持し、人間レビューに回す）**。
このとき `state=complete` のみを PUT し、`tbc` は触らない（自動化ルール #9 は
発火しないので、要対応は維持される — これが正しい挙動）。

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
- **`scheduled_to_be_shipped_at_eq` で日付絞り込み**：datetime 型なので
  `00:00:00` 完全一致になり取りこぼす。`_gteq` + `_lt` の半開区間で当日全体を拾う。
- **`bulk_update void` で定期保護フラグを送り忘れる**：定期回数が `-1` され、
  次回お届け日が動く事故になる。`decrement_subs_order_times: 0` /
  `recalculate_subs_order: 0` を必ず付ける（`reauth` では逆に送らない）。
- **`tbc` を API で書こうとする**：silently 無視される。GET ポーリング + 自動化
  ルール側で解消する設計に倒す。
- **顧客メモを `note` トップレベルや `customer_notes_attributes` で送る**：
  HTTP 200 でもメモは作成されない。正しいキーは
  `customer.notes_attributes[]`。
- **受注ラベル (`label_ids`) を API から付け外ししようとする**：不可。`memo01`
  でマーカー文字列を書いて検索に流用する。
- **`meta.total_pages` を盲信する**：欠落・0 が混じる。最終ページ判定とハード
  上限の両方でガードする。

## デバッグ手順

1. まず `curl` で素のリクエストが通るか。401 ならトークン or 権限の問題。
2. 通ったら body に `{{...}}` を入れて、サーバーログのリクエストペイロードを確認。
   テンプレ置換後の値が想定どおりかを最優先で見る。
3. ecforce 側で更新されたかは ecforce 管理画面の顧客詳細を直接確認。
   API が 200 を返しても反映タイミングのズレで一見更新されないことがある。
4. **`tbc` 系で「反映されない」と言われたら**まず `GET /subs_orders/:id.json` を
   `[0, 5, 10, 15]` 秒の累計 30 秒スパンで叩き直す。自動化ルール経由なので
   即時反映ではない。

## このプロジェクトを参考にしたい場合

- `artifacts/api-server/src/lib/jobs.ts` — シークレット解決・認証ヘッダー自動付与
- `artifacts/api-server/src/routes/campaigns.ts` — テンプレ施策生成・ドメイン差し込み
- `artifacts/api-server/src/routes/app-settings.ts` — `ECFORCE_API_TOKEN` の有無判定

### 決済再処理ツール側のリファレンス実装

別プロジェクト「ecforce 決済再処理ツール」での実装例:

- `artifacts/api-server/src/lib/ecforceClient.ts` — 認証ヘッダー / 2,000ms レート制御 /
  `[3s, 5s, 15s]` リトライ / `getTargetOrders` の半開区間ページング / `bulk_update`
  (void / reauth) / `PUT /orders/:id` (支払い方法変更・注文確定・倉庫連携待ち) /
  `getSubscriptionTbc` / `addCustomerNote` 公式仕様準拠ペイロード。
- `artifacts/api-server/src/lib/postVerify.ts` — バッチ末尾の `tbc` ラウンド方式
  GET ポーリングで「成功確定 / 失敗降格」を切り替える純粋ロジック。
- `artifacts/api-server/src/routes/orders.ts` — 上記を組み合わせた ① 〜 ⑧ ステップ
  オーケストレーションと、`credit_exam_failed` 検出時の自動リカバリ分岐。

## 参考: 関連定数（決済再処理ツール実装値）

| 名前                                  | 値                              | 用途                                                       |
| ------------------------------------- | ------------------------------- | ---------------------------------------------------------- |
| `RATE_LIMIT_MS`                       | 2000                            | リクエスト間隔の下限                                       |
| `RETRY_DELAYS_MS`                     | `[3000, 5000, 15000]`           | 429 / 500 リトライ間隔                                     |
| `PAGE_SIZE`                           | 100                             | `per` パラメータ（ecforce 側上限）                         |
| `MAX_PAGES`                           | 1000                            | 受注検索の安全上限（=最大 100,000 件）                     |
| `POST_REAUTH_INITIAL_WAIT_MS`         | 5000                            | 再オーソリ後の初期待機                                     |
| `VERIFY_POLL_INTERVAL_MS`             | 2000                            | 与信審査完了ポーリング間隔                                 |
| `VERIFY_POLL_MAX_ATTEMPTS`            | 15                              | 与信審査完了ポーリング最大試行                             |
| `POST_BATCH_TBC_RETRY_DELAYS_MS`      | `[0, 5000, 10000, 15000]`       | バッチ末尾 `tbc` 反映ラウンドの待機列                      |

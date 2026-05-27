# ecforce API ナレッジ（決済再処理ツール由来）

本ドキュメントは、社内の「ecforce 決済再処理ツール」開発を通じて実機検証で確定した
ecforce Admin API v2 の実装ノウハウをまとめたものです。公式ドキュメントの記述だけでは
判明しない strong_parameters の挙動や、非同期な自動化ルール、レート/リトライ運用値などを
中心に記録します。

最終更新: 2026-05

---

## 1. 認証・エンドポイント基盤

- ベース URL: `${ECFORCE_API_BASE_URL}/api/v2/admin`
- 認証ヘッダー: `Authorization: Token token="<API_KEY>"`
  - HTTP Basic ではなく Rails 風 `Token token="..."` 形式。クォートも必須。
- `Content-Type: application/json` / `Accept: application/json`
- レスポンスは原則 [JSON:API](https://jsonapi.org/) 形式（`data` / `included` / `meta`）。

### レート制御 (実運用値)

- リクエスト間隔の下限: **2,000 ms**（社内実測で 429 を抑えられた値）。
- 並列化は ecforce 側へ負荷をかけるため避け、逐次（直列）で叩く。

### リトライ (429 / 500)

- 対象ステータス: `429`（レート超過）, `500`（`AOR9999` などの内部一時エラー）。
- 試行ごとの待機: `[3s, 5s, 15s]`、最大 3 回。
- `Retry-After` ヘッダーがあれば最優先で従う。
- それ以外の `!res.ok` は即時例外。レスポンスが HTML の場合は `<title>` だけ抜き出し
  ログを汚さないようにする。

---

## 2. 受注検索 `GET /orders.json`

### よく使うクエリ

```
include=billing_address
per=100                          # 上限 100 で頭打ち
page=N                           # 1 始まり
q[scheduled_to_be_shipped_at_gteq]=YYYY-MM-DD
q[scheduled_to_be_shipped_at_lt] =YYYY-MM-DD (翌日)
q[payment_payment_method_id_eq]=58
q[state_eq]=complete
q[payment_state_in][]=auth_failed
q[payment_state_in][]=update_failed
q[payment_state_in][]=credit_exam_failed
```

### 重要な落とし穴

- `scheduled_to_be_shipped_at` は **datetime 型** なので `_eq` を使うと
  `00:00:00` 完全一致になり、自動再スケジュール等で時刻成分が `00:00:00` でない
  受注を取りこぼす。**必ず `_gteq` + `_lt` の半開区間で当日全体を拾うこと。**
- `meta.total_pages` は欠落/`0` のことがある。
  「最終ページが `per` 未満なら終了」「`meta.total_pages` 信頼可能なら `page >= total_pages` で打ち切り」の
  二段ロジックを入れた上で、ハード上限（例: 1000 ページ = 100,000 件）を必ず設ける。
- `billing_address` は `relationships.billing_address.data.id` 経由で `included` 内の
  `type: "address"` を引く必要がある。氏名は `full_name`、無ければ `name01 + " " + name02`。

### `payment_state` 値の対応表（運用上頻出のもの）

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

---

## 3. 決済再処理エンドポイント

### 3-1. 決済キャンセル (`method=void`)

```
POST /orders/payment_status/bulk_update.json
{
  "method": "void",
  "order_ids": [<id>],
  "decrement_subs_order_times": 0,  // 定期回数を -1 しない
  "recalculate_subs_order": 0       // 定期受注を再計算しない
}
```

上記 2 つのフラグは「単発のリカバリ操作で定期受注を壊さないため」に必須。

### 3-2. 支払い方法変更

```
PUT /orders/:id.json
{ "order": { "payment_attributes": { "payment_method_id": <id> } } }
```

### 3-3. 再オーソリ (`method=reauth`)

```
POST /orders/payment_status/bulk_update.json
{ "method": "reauth", "order_ids": [<id>] }
```

`decrement_subs_order_times` / `recalculate_subs_order` は **`reauth` では無効** なので
送らないこと。

### 3-4. 受注確定 / 受注備考

```
PUT /orders/:id.json
{ "order": { "state": "complete", "memo01": "バモス決済変更" } }
```

- `state: "complete"` で「注文確定」に戻す。
- `memo01` (受注備考1) は **API から即書き換え可能**。本ツールでは
  「再処理済み」のマーカーとして固定文字列 `"バモス決済変更"` を書き込み、
  ecforce 管理画面側の検索条件として再利用している（既存値は単純上書き）。
- `label_ids`（受注ラベル）は **API から付け外し不可**。代替として上記 `memo01` を使う。

### 3-5. 倉庫連携待ち遷移

```
PUT /orders/:id.json
{ "order": { "state": "wmswait" } }     // FJロジ
{ "order": { "state": "cooolawait" } }  // 塚本郵便逓送
```

決済が `credit_exam_completed` であることを確認した後に行う。

---

## 4. ⚠️ `tbc`（要対応フラグ）は API で書き込めない

これは公式ドキュメントに明示されない最重要トラップ。

- `PUT /orders/:id.json` の `{ order: { tbc: false } }`、
  `PUT /subs_orders/:id.json` の `{ subs_order: { tbc: false } }`、
  `PUT /subs_orders/bulk_update.json` の `tbc` フィールド、いずれも
  **HTTP 200 / errors=None で成功したように見えるが、再 GET すると `tbc` は元のまま**。
- Rails の strong_parameters で silently 弾かれていると推定される
  （`memo01` などは同じ呼び出し方で persist する）。
- **唯一の正解**: ecforce 管理画面側の **自動化ルール** を仕込み、
  payment_state の遷移をトリガーに ecforce 自身に `tbc` を落とさせる。
  運用中のルール例:
  > **ルール #9**: 受注の決済状況が「与信審査完了」になったとき → 定期受注の要対応を解除する。
- 自動化ルールは **非同期**。実測では payment_state を `credit_exam_completed` に
  遷移させてから `subs_order.tbc=false` を `GET /subs_orders/:id.json` で
  読み戻せるまで **約 24 秒** かかる。
- したがってクライアント側のリカバリは **GET ポーリングで反映を待つ**。
  ラウンド方式（受注 1 件単位ではなくバッチ末尾に集約）が運用上効率的:
  ```
  round 1: wait 0s  → 全件 GET
  round 2: wait 5s  → 未反映分のみ GET
  round 3: wait 10s → 未反映分のみ GET
  round 4: wait 15s → 未反映分のみ GET  (累計 30s)
  ```
- `tbc` の真偽判定は防御的に: `false / 0 / "false" / "0" / null / undefined` を
  すべて「解除済み」とみなす（ecforce が型を揺らすため）。

### 偽陰性事例（実ログ）

本番ログで 22 件中 8 件が「tbc 解除未反映」となったが、後刻 GET し直すと
**全件 `tbc=false`**。原因は (1) 無効な PUT を投げていた、(2) 反映遅延を待ち切れていなかった、
の 2 点だった。上記ラウンド方式で恒久対応。

---

## 5. 再オーソリ後の与信審査ポーリング

`reauth` 直後の `payment_state` は `credit_exam_processing` （与信審査中）であることが多く、
完了まで数秒〜十数秒の遅延がある。

推奨パターン:

1. `reauth` 後に固定で **5 秒** 待機。
2. `GET /orders/:id.json` でポーリング。
   - `credit_exam_completed` → 成功。
   - `credit_exam_processing` → **2 秒 sleep** 後にリトライ（最大 15 回 ≈ 30 秒）。
   - それ以外（`credit_exam_failed` 等）→ 与信審査エラーとして上位で分岐。

### 旧形式エラー文言にも注意

ecforce のバージョンによっては「与信審査完了でない」状態を以下のような
エラーメッセージ文字列で返してくることがある:

> 「決済状況が credit_exam_completed ではありません…」

これも `credit_exam_failed` 相当として扱うこと（純粋な状態値だけ見ていると
リカバリパスが起動しない事故になる）。

---

## 6. 顧客メモ追加 `PUT /customers/:id.json`

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

- `id` を指定しないと新規追加。
- 過去にハマった誤りパターン:
  - トップレベル `{ "note": { ... } }` で送る → strong_parameters で破棄され
    HTTP 200 でもメモ作成されない。
  - `customer.customer_notes_attributes` というキー名 → 正しくは `notes_attributes`。
- `operated_at` の **`YYYY/MM/DD HH:MM:SS`** フォーマットは公式例準拠。
  Asia/Tokyo の現在時刻を `Intl.DateTimeFormat("ja-JP", { timeZone: "Asia/Tokyo", … })` で
  生成すると確実。

### 顧客 ID の取得

`GET /orders/:id.json` のレスポンスから引く。

- 通常は `data.attributes.customer_id` に入っている。
- 入っていない場合は `data.relationships.customer.data.id` を見る。

両方を必ずフォールバックすること（ecforce のレスポンス差異あり）。

---

## 7. 推奨される処理ステップ設計（NP→バモス 切替フロー例）

決済再処理ツールでの実フロー（成功パスと自動リカバリパスを併記）:

1. **対象抽出**: 配送予定日 + payment_method=58 + 失敗系 payment_state で検索。
2. **① 決済キャンセル** (`bulk_update method=void`, 定期保護フラグ 0/0)。
3. **② 支払い方法変更** (`PUT /orders/:id`, payment_method_id を切替先へ)。
4. **③ 再オーソリ** (`bulk_update method=reauth`)。
5. **④ 与信審査完了確認** (5s 初期待機 → 2s ポーリング)。
   - `credit_exam_completed` → 成功パスへ。
   - `credit_exam_failed`（旧文言含む） → **自動リカバリパスへ分岐**。
6. **⑤ 注文確定 + メモ書き込み** (`state=complete, memo01="バモス決済変更"`)。
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

---

## 8. 実装上のチェックリスト

- [ ] `Authorization: Token token="..."` 形式で叩く（HTTP Basic ではない）。
- [ ] レート制御 2s／429・500 リトライ `[3s, 5s, 15s]`／`Retry-After` 優先。
- [ ] 受注検索の `scheduled_to_be_shipped_at` は `_gteq` + `_lt` の半開区間。
- [ ] ページング: `per` 上限 100、`meta.total_pages` を信用しすぎず最終ページ判定併用。
- [ ] `bulk_update method=void` には `decrement_subs_order_times=0` /
      `recalculate_subs_order=0` を必ず付ける（reauth では付けない）。
- [ ] `tbc` は **絶対に API で書こうとしない**。GET ポーリング + 自動化ルールで解決。
- [ ] `payment_state` の検証は値だけでなく、エラーメッセージ
      「決済状況が credit_exam_completed ではありません…」も `credit_exam_failed` 扱い。
- [ ] 顧客メモは `customer.notes_attributes[].{ content, operated_at, operated_by }`。
      キー名を絶対に間違えない（過去 2 回踏んだ罠）。
- [ ] 顧客 ID は `attributes.customer_id` → `relationships.customer.data.id` の順で引く。
- [ ] `memo01` は API で即書き換え可能。受注ラベルは API 不可、代替に `memo01` を使う。

---

## 9. 参考: 関連定数（社内ツール実装値）

| 名前                                  | 値                              | 用途                                                       |
| ------------------------------------- | ------------------------------- | ---------------------------------------------------------- |
| `RATE_LIMIT_MS`                       | 2000                            | リクエスト間隔の下限                                       |
| `RETRY_DELAYS_MS`                     | `[3000, 5000, 15000]`           | 429/500 リトライ間隔                                       |
| `PAGE_SIZE`                           | 100                             | `per` パラメータ                                           |
| `MAX_PAGES`                           | 1000                            | 受注検索の安全上限（=最大 100,000 件）                     |
| `POST_REAUTH_INITIAL_WAIT_MS`         | 5000                            | 再オーソリ後の初期待機                                     |
| `VERIFY_POLL_INTERVAL_MS`             | 2000                            | 与信審査完了ポーリング間隔                                 |
| `VERIFY_POLL_MAX_ATTEMPTS`            | 15                              | 与信審査完了ポーリング最大試行                             |
| `POST_BATCH_TBC_RETRY_DELAYS_MS`      | `[0, 5000, 10000, 15000]`       | バッチ末尾 `tbc` 反映ラウンドの待機列                      |
| `FINALIZE_MEMO01_VALUE`               | `"バモス決済変更"`              | 再処理済みマーカー                                         |
| `WAREHOUSE_STATE_MAP.komarobo`        | `"wmswait"`                     | 倉庫連携待ち（FJロジ）                                     |
| `WAREHOUSE_STATE_MAP.cooola`          | `"cooolawait"`                  | 倉庫連携待ち（塚本郵便逓送）                               |

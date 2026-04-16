---
name: boundary-parse-readiness-check-v2
description: Lambda handler に zod .parse() を配置する適切な箇所を判定するチェックリスト。Entry 境界（event.body/pathParam/queryString 直後→400）と DB 取得直後（rows[N]→500）の 2 箇所限定ルール、Exit は log-only、AP001-006（TINYINT/dateStrings/key mismatch/二重バリデ/re-select gap/BIGINT coerce）との全連動方針、coerce/omit/camelCase 変換境界の明確化を含む。新規 handler 追加時・AP 再発疑惑時・shared スキーマ変更後の .parse() 配置再点検時に使用。
---

# Boundary .parse() Readiness Check v2

## Overview

Lambda handler における zod `.parse()` の**適用箇所を Entry + DB 取得直後の 2 箇所に限定**し、
それ以外での乱用（handler 内中間層、Exit 境界での parse+replace 等）を防ぐ判断フローを定式化する。

**解決する問題**:
- `.parse()` を handler 内の任意箇所に打つと、wire format が変わり downstream が壊れる
- Exit 境界で `.parse()` 戻り値を response に使うと、フィールド欠落・型変換が invisible になる
- AP001-006 の mysql2 型 drift を handler 側で個別処理すると修正漏れが発生する
- coerce・omit・camelCase 変換の責務層が曖昧なまま実装すると、スキーマ変更時に多箇所修正が必要になる

**v1 → v2 の差分（本書が v2 たる所以）**:

| 項目 | v1 (初期 boundary_parse_norm) | v2 (本書) |
|------|-------------------------------|-----------|
| 境界定義 | Entry / DB / Exit の 3 区分 | 同左 + 適用可否 Y/N フロー |
| coerce 責務 | 「DAO 側で対処」と記述のみ | DAO スキーマに閉じ込める根拠 + AP001/006 連動 |
| omit 責務 | 記述なし | API スキーマの .omit() 派生は Layer 2 限定 + AP003 例外明示 |
| camelCase 変換 | case-converter.js 参照のみ | DB 直後 .parse()→toCamelCase の順序を確定 + AP002 対処 |
| 除外 handler | なし | auth-authorizer（JWT verify のみ）は .parse() 対象外と明記 |
| AP001-006 | 各 AP に個別記述 | 「.parse() 打つか / 打たぬか」を一覧で明記 |

---

## When to Use

以下の状況で使用する:

- 新規 Lambda handler を追加し、`.parse()` をどこに置くか判断する時
- AP001-006 の再発疑惑（BIGINT string エラー・TINYINT boolean 誤変換・key mismatch 等）が生じた時
- `shared/schemas` を変更した後、handler の `.parse()` 配置を再点検する時
- `re-select gap`（INSERT/UPDATE 直後に DB 再取得せず古い値を返す問題 = AP005）を発見した時
- handler 内で `.parse()` を 3 箇所以上書いており、適切かレビューしたい時

**トリガーとなる指示の例**:
「handler に .parse() を追加せよ」「BIGINT が string になる」「AP006 対処」「境界型検査を整備せよ」「re-select gap の修正」

---

## Instructions

### Step 1: 境界 Y/N 判定フロー

handler のある一箇所に `.parse()` を追加する前に、以下のフローで判定する:

```
対象箇所は「外部データが handler 内部に入ってくる wire format 境界」か?
          │
     NO ──┤ → .parse() 不要
          │   (handler 内の中間変数・関数呼び出し間の受け渡しは対象外)
          │
         YES
          │
          ▼
    入力元は event.body / pathParameters / queryStringParameters か?
          │
         YES → [Entry 境界] .parse() 必須 → 失敗時 400
          │
         NO
          │
          ▼
    mysql2 の query 結果 rows[N] か?
          │
         YES → [DB 取得直後] .parse() 必須 → 失敗時 500
          │
         NO
          │
          ▼
    JSON.stringify 直前 (response 生成直前) か?
          │
         YES → [Exit 境界] safeParse + log-only
          │    .parse() 戻り値を response に使ってはならない
          │    (wire format preservation: raw DB 値または toCamelCase(raw) を使う)
          │
         NO → .parse() 不要
```

**handler 内中間処理での .parse() 禁止の理由**:
中間 `.parse()` は型を絞り込む代わりに、フィールド欠落や型変換が silent に起きるリスクがある。
handler のロジック内では TypeScript の型推論で十分。`.parse()` は wire format の「入口」と「DB 出口」の 2 点のみ。

---

### Step 2: Entry 境界の実装

**対象**: `event.body`・`event.pathParameters`・`event.queryStringParameters`

```javascript
// ✅ Entry 境界: event.body → API camelCase スキーマで .parse()
const body = JSON.parse(event.body ?? '{}');
const params = StaffUpdateApiRequestSchema.parse(body);  // 失敗 → ZodError → 400

// ✅ pathParameter
const staffId = z.coerce.number().int().parse(event.pathParameters?.id);  // 失敗 → 400

// ✅ queryStringParameters (optional パラメータ)
const query = StaffListQuerySchema.parse(event.queryStringParameters ?? {});
```

**スキーマ選択**: Entry では**Layer 3 (API camelCase) スキーマ**を使う。
`apps/functions/src/shared/case-converter.js` の `toSnakeCase()` で DAO 層に変換してから DB 操作に渡す。

---

### Step 3: DB 取得直後の実装

**対象**: `mysql2` の `query()` または `execute()` が返す `rows[N]`

```javascript
// ✅ DB 取得直後: rows[0] → DAO スキーマで .parse()
const [rows] = await conn.execute('SELECT * FROM staffs WHERE id = ?', [staffId]);
if (rows.length === 0) return { statusCode: 404, body: JSON.stringify({ error: 'Not found' }) };

const staff = StaffWithRoleSchema.parse(rows[0]);  // 失敗 → ZodError → 500
// ↑ この時点で staff は型付き。BIGINT coerce・TINYINT int 等が吸収済み

// ✅ response は toCamelCase(raw) — parse 戻り値ではなく raw 値を変換
return {
  statusCode: 200,
  body: JSON.stringify(toCamelCase(rows[0])),  // wire format preservation
};
```

**wire format preservation 原則**:
`.parse()` の目的は「型安全な取り出し」であり、「response 生成」ではない。
response には必ず `toCamelCase(rows[0])` 等 raw 値を使う（`.parse()` 戻り値を stringify しない）。

---

### Step 4: Exit 境界の実装（log-only）

**Exit 境界では `.parse()` を response 生成に使ってはならない**。
使う場合は `safeParse` + ログ出力のみとする（response shape 検証目的）:

```javascript
// ✅ Exit 境界: safeParse log-only (オプション)
const responseShape = StaffApiResponseSchema.safeParse(responseBody);
if (!responseShape.success) {
  console.error('[EXIT_SHAPE_MISMATCH]', responseShape.error.flatten());
  // response は変えない — log-only
}
return { statusCode: 200, body: JSON.stringify(responseBody) };
```

---

### Step 5: coerce 配置の判断

**coerce はスキーマ定義層（DAO スキーマ）に閉じ込める。handler に書かない。**

| 状況 | 配置場所 | 理由 |
|------|---------|------|
| BIGINT → number (AP006) | `shared/schemas/db/*.ts` の `z.coerce.number().int()` | 全 handler が恩恵を受ける |
| pathParameter id の文字列→数値 | Entry 境界の inline `z.coerce.number().int()` | handler 固有、schema 化不要 |
| TINYINT(1) → boolean (AP001) | DAO スキーマの `z.number().int().min(0).max(1)` | normalizeDbRow + boolean 変換はアプリ層の責務 |

---

### Step 6: テストでの境界検証

```typescript
// DB 取得直後 .parse() のテスト — mysql2 型 drift を模擬する
test('BIGINT id は string で来ても StaffSchema.parse が coerce する', () => {
  const rawRow = { id: '42', staff_name: 'テスト', is_active: 1, ... };  // mysql2 が返す形
  const parsed = StaffSchema.parse(rawRow);
  assert.strictEqual(parsed.id, 42);       // coerce で number に
  assert.strictEqual(typeof parsed.id, 'number');
});

// Entry .parse() のテスト — 不正入力で ZodError
test('Entry: 不正 body は ZodError を throw する', () => {
  assert.throws(
    () => StaffUpdateApiRequestSchema.parse({ name: 123 }),  // name は string 必須
    (e) => e instanceof ZodError
  );
});
```

---

## Examples

### cmd_213: staffs handler — Entry + DB 直後の 2 箇所 .parse() 配置

**staffs.put handler の boundary .parse() 実装（cmd_213 Phase 1 成果）**:

```javascript
// src/staffs.put/index.js

import { StaffUpdateLegacyApiRequestSchema } from './shared/schemas/api/staffs/index.js';
import { StaffSchema } from './shared/schemas/db/staffs.js';

export const handler = async (event) => {
  // ── Entry 境界 .parse() ──────────────────────────────
  const body = JSON.parse(event.body ?? '{}');
  const params = StaffUpdateLegacyApiRequestSchema.parse(body);
  // 失敗時: ZodError → catch → { statusCode: 400 }

  const staffId = z.coerce.number().int().parse(event.pathParameters?.id);

  // ── DB 操作（中間処理: .parse() 不要）──────────────────
  await conn.execute(
    'UPDATE staffs SET name = ?, email = ? WHERE id = ?',
    [params.name, params.email, staffId]
  );

  // ── DB 取得直後 .parse() ─────────────────────────────
  const [rows] = await conn.execute('SELECT * FROM staffs WHERE id = ?', [staffId]);
  const staff = StaffSchema.parse(rows[0]);
  // 失敗時: ZodError → catch → { statusCode: 500 }
  // ↑ AP006: id が BIGINT string でも z.coerce.number() が吸収済み

  // ── Exit: raw 値を toCamelCase して response ─────────
  return {
    statusCode: 200,
    body: JSON.stringify(toCamelCase(rows[0])),  // parse 戻り値ではなく raw
  };
};
```

---

### cmd_216: BIGINT coerce — before/after

**Before (AP006 未対処 — BIGINT string エラー)**:

```javascript
// ❌ Before: id の型を handler 内で個別 coerce
const staff = z.object({
  id: z.number().int(),          // ← mysql2 は BIGINT を "42" で返すため ZodError
  staff_name: z.string(),
}).parse(rows[0]);
```

**After (AP006 対処済み — DAO スキーマに coerce を集約)**:

```typescript
// ✅ After: shared/schemas/db/staffs.ts (DAO スキーマ側で coerce 吸収)
export const StaffSchema = z.object({
  id: z.coerce.number().int(),   // ← BIGINT string → number を DAO 層で吸収
  staff_name: z.string(),
  is_active: z.number().int().min(0).max(1),
  // ...
});
```

```javascript
// handler 側は何も変えなくていい — DAO スキーマが吸収済み
const staff = StaffSchema.parse(rows[0]);  // id: "42" → 42 (coerce 済)
```

**効果**: 全 handler が StaffSchema を使えば、BIGINT coerce は一箇所で管理される。
AP006 が再発した場合も `shared/schemas/db/staffs.ts` を修正するだけで全 handler に反映。

---

## Guidelines

### AP001-006 × .parse() 方針一覧

| AP # | 問題 | .parse() 打つか | 配置場所 | 補足 |
|------|------|----------------|---------|------|
| **AP001** | TINYINT(1) が `0`/`1` (number) で返る — boolean 期待 | ✅ DB 直後 | DAO スキーマ `z.number().int().min(0).max(1)` | boolean 変換は `normalizeDbRow()` でアプリ側に委ねる。DAO は int のまま |
| **AP002** | `dateStrings: true` で DATE/DATETIME が string 返却 | ✅ DB 直後 | DAO スキーマ `z.string()` | `new Date()` 変換は handler 任意。DAO は string で受けて parse |
| **AP003** | company/tenant の key 差異（Legacy API 契約）| ✅ Entry | Legacy `z.object()` 独立定義 | `.omit()/.partial()` 派生不可。Legacy は別スキーマとして定義する |
| **AP004** | `validateRequest()` と zod の二重バリデーション | ✅ Entry (zod のみ残す) | Entry 境界 | zod で型付き値に昇格させる。`validateRequest` は型情報を返さないため削除可 |
| **AP005** | re-select gap: INSERT/UPDATE 後に DB 再取得せず古い値を返す | ✅ DB 直後 (再取得後) | DB 取得直後 | INSERT/UPDATE 後は必ず SELECT で再取得してから parse。推測値を return 禁止 |
| **AP006** | BIGINT が string で返る (mysql2 精度制限) | ✅ DB 直後 | DAO スキーマ `z.coerce.number().int()` | handler ではなく DAO スキーマで吸収。全 handler に自動適用 |

### C005: analytics handler は .parse() 対象外

`analytics.*` handler は集計 SQL の結果を集計型として返すため、
固定の DAO スキーマに縛れない。`.parse()` は任意（推奨: safeParse log-only のみ）。

### auth-authorizer は .parse() 対象外

`auth-authorizer` は JWT を verify するだけで DB アクセスがない。
Entry 境界・DB 取得直後の .parse() ともに不要。

### 「.parse() 打たぬ」が正解のケース

- handler 内のローカル変数間受け渡し（型推論で十分）
- zod で型付け済みの変数を別関数に渡す前（既に型安全）
- Exit 境界（response 生成直前）— safeParse log-only のみ可

### shared スキーマ変更後の .parse() 配置再点検手順

```bash
# 1. 変更された DAO スキーマの型シグネチャを確認
npm --prefix shared run typecheck

# 2. 各 handler で .parse() が使われている箇所を一覧
grep -r '\.parse(' apps/functions/src/ --include='*.js' -l

# 3. Entry + DB 直後の 2 箇所のみか確認 (3 箇所以上は要レビュー)
grep -c '\.parse(' apps/functions/src/*/index.js

# 4. 全 Lambda rebuild で shared/dist を最新化
cd apps/functions && rm -rf dist && npm run build
```

---

## References

- `skills/dao-zod-schema-with-test/SKILL.md` — DAO スキーマ定義の基礎（AP001/AP006 coerce 実装手順）
- `skills/api-schema-dao-derivation/SKILL.md` — Layer 2 API スキーマの .omit()/.partial() 派生と wire format preservation
- `skills/api-schema-layer-separation/SKILL.md` — 四層分離アーキテクチャとデータフロー全体図
- `skills/lambda-shared-zod-delivery/SKILL.md` — shared/dist を Lambda zip に同梱する手順（AP006 fix が Lambda に届くまでの経路）
- `shared/schemas/README.md` — 三層スキーマ規約・命名規則・JOIN 結果スキーマ（HearProSupport 固有）
- `docs/20_DetailDasign/boundary_parse_norm.md` — boundary .parse() 正規化ルール原典（AP001-006 全文・10 handler マトリクス）

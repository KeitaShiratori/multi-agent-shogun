---
name: mysql-driver-type-drift-boundary-coerce
description: mysql2 ドライバが返す型ブレ（BIGINT→string, TINYINT→0/1 number, DATETIME/DATE→string）を shared/schemas/db/*.ts の DAO スキーマ側で z.coerce により吸収し、handler 以降を型安定に保つ境界設計パターン。AP001 (TINYINT) / AP006 (BIGINT) の class-of-problem を一般化し、driver 型ブレ一覧表・coerce 選択基準・nullable BIGINT の helper 必要性（cmd_217 予告）を含む。新規テーブル DAO スキーマ追加時・AP001/AP006 類似症状発現時・driver 設定変更後の互換検証時に使用。
---

# MySQL Driver Type Drift — Boundary Coerce

## Overview

`mysql2` ドライバは接続オプション設定によって、MySQL の型をそのまま JavaScript 型に
マップせず、string や number に「ブレた」状態で返すことがある。
このスキルは「**driver 特有の型ブレを DAO スキーマ層で z.coerce により吸収し、
handler 以降の型安定を保証する**」境界設計パターンを定式化する。

**driver 設定と型ブレの関係**:

```
apps/functions/src/shared/db-connection.js の createConnection() 設定:
  supportBigNumbers: true   ← BIGINT を number 化する前提で必要 (設定だけでは不完全)
  bigNumberStrings:  true   ← BIGINT を string で返す (AP006 の根因)
  dateStrings:       true   ← DATE/DATETIME を string で返す (AP002 の根因)
```

これらは**接続設定として固定されており変更しない**（理由は Guidelines 参照）。
driver が string で返すなら、DAO スキーマで `z.coerce` を使って number/date に変換する。

**解決する問題**:
- `z.number().int()` は mysql2 が BIGINT を `"42"` (string) で返すと ZodError → handler 500
- `z.date()` は `dateStrings: true` で DATETIME が `"2026-04-01 10:00:00"` (string) で来ると ZodError
- `z.boolean()` は TINYINT(1) が `0`/`1` (number) で返ると ZodError
- handler ごとに個別に型変換を書くと修正漏れが発生し、AP 再発の温床となる

**v1 (AP001/AP006 個別対処) → 本スキル（型ブレ一般化）の位置づけ**:

| 視点 | 従来 | 本スキル |
|------|------|---------|
| スコープ | AP001 (TINYINT)、AP006 (BIGINT) を個別 ticket で対処 | driver 型ブレをクラスとして一般化し DAO 基盤で統一対処 |
| 駆動力 | 症状発現後のリアクティブ対処 | 新規テーブル追加時のプロアクティブ予防 |
| 管理場所 | handler 側に個別 coerce が散在するリスク | `shared/schemas/db/` に集約、全 handler へ自動適用 |

---

## When to Use

以下の状況で使用する:

- 新規 MySQL テーブルの DAO スキーマ (`shared/schemas/db/*.ts`) を作成する時
- `ZodError: expected number, received string` が BIGINT カラムで発生した時 (AP006)
- `ZodError: expected boolean, received number` が TINYINT(1)/BOOLEAN カラムで発生した時 (AP001)
- `ZodError: expected date, received string` が DATETIME/DATE カラムで発生した時 (AP002)
- driver バージョンアップ後に型互換を検証する時
- `shared/schemas/db/` 配下のスキーマに `z.number().int()` / `z.date()` / `z.boolean()` が残っていないか棚卸しする時

**トリガーとなる指示の例**:
「DAO スキーマに BIGINT がある」「mysql2 型エラーが出た」「AP001/AP006 対処」
「新テーブルの DAO schema 追加」「driver 型ブレ一覧表が欲しい」

---

## Instructions

### Step 1: driver 設定と型ブレ一覧の確認

まず接続設定を確認して、適用される型ブレを特定する:

```bash
grep -A5 "createConnection\|createPool" apps/functions/src/shared/db-connection.js
# bigNumberStrings: true → BIGINT は string
# dateStrings: true      → DATE/DATETIME は string
# supportBigNumbers: true → BIGINT 許容 (ただし bigNumberStrings:true 優先)
```

**driver 設定別の型ブレ一覧表** (Aurora MySQL 8.0 + mysql2、HearProSupport 設定前提):

| MySQL 型 | mysql2 出力 (HPS 設定) | coerce 後 TS 型 | DAO zod 定義 |
|---------|----------------------|----------------|------------|
| `BIGINT NOT NULL` | `string` (bigNumberStrings:true) | `number` | `z.coerce.number().int()` |
| `BIGINT NULL` | `string \| null` | `number \| null` | ※ helper 必要 (§nullable BIGINT) |
| `INT NOT NULL` | `number` | `number` | `z.number().int()` (coerce 不要) |
| `INT NULL` | `number \| null` | `number \| null` | `z.number().int().nullable()` |
| `TINYINT(1) NOT NULL` (フラグ) | `number` (0 or 1) | `number` (0/1 保持) | `z.number().int().min(0).max(1)` |
| `TINYINT(1) NULL` (フラグ) | `number \| null` (0/1 or null) | `number \| null` | `z.number().int().min(0).max(1).nullable()` |
| `BOOLEAN NOT NULL` | `number` (0 or 1) | `number` (0/1 保持) | `z.number().int().min(0).max(1)` |
| `DATE NOT NULL` | `string` (dateStrings:true) | `string` | `z.string()` |
| `DATETIME NOT NULL` | `string` (dateStrings:true) | `string` | `z.string()` |
| `DATETIME NULL` | `string \| null` | `string \| null` | `z.string().nullable()` |
| `VARCHAR NOT NULL` | `string` | `string` | `z.string().max(N)` |
| `VARCHAR NULL` | `string \| null` | `string \| null` | `z.string().max(N).nullable()` |
| `DECIMAL NOT NULL` | `string` | `number` | `z.coerce.number()` |
| `JSON NULL` | `object \| null` (mysql2 が自動 parse) | 対応型 | `z.array(...).nullable()` 等 |

> **INT vs BIGINT**: `INT` は `Number.MAX_SAFE_INTEGER` 内に収まるため、mysql2 は number で返す。
> `BIGINT` のみが string 化の対象。見分け方: DDL の `BIGINT` を grep する。

---

### Step 2: DAO スキーマの棚卸し

既存 DAO スキーマのうち、型ブレが起きているフィールドを全件洗い出す:

```bash
cd shared/schemas/db

# BIGINT NOT NULL → z.coerce.number().int() に要変換
grep -rn "z\.number()\.int()" *.ts | grep -v coerce

# z.date() → z.string() に要変換 (dateStrings:true 環境)
grep -rn "z\.date()" *.ts

# z.boolean() → z.number().int().min(0).max(1) に要変換
grep -rn "z\.boolean()" *.ts
```

出力結果をリストし、DDL (migration SQL) と照合して BIGINT / TINYINT / DATETIME 判定を行う。

---

### Step 3: NOT NULL BIGINT への z.coerce 適用

BIGINT NOT NULL のフィールドを `z.coerce.number().int()` に変更する:

```diff
// shared/schemas/db/staffs.ts
 export const StaffSchema = z.object({
-  id: z.number().int(),
+  id: z.coerce.number().int(),          // BIGINT NOT NULL AUTO_INCREMENT

-  tenant_id: z.number().int(),
+  tenant_id: z.coerce.number().int(),   // BIGINT NOT NULL FK
```

**coerce の動作**:
- `z.coerce.number()` は `Number(value)` 相当。`"42"` → `42`、`42` → `42` (idempotent)
- `.int()` は変換後に整数チェック。小数点付き文字列は失敗する (意図的)
- null 値に注意: `Number(null)` は `0` → nullable BIGINT には使えない (次 Step 参照)

---

### Step 4: nullable BIGINT の扱い (helper 必要 — cmd_217 予告)

**nullable BIGINT** (`BIGINT NULL`) に `z.coerce.number().int().nullable()` は**使えない**:

```javascript
Number(null)  // → 0 (JavaScript の仕様)
// z.coerce.number().int().nullable() が null を 0 に変換してしまう
// → store_id: null のレコードが store_id: 0 に化ける
```

現時点の暫定対処は以下の 2 択:

```typescript
// 暫定 (A): z.union で null を先に捌く
store_id: z.union([z.null(), z.coerce.number().int()]),

// 暫定 (B): nullable カラムは coerce 非適用のまま残す (string が来たら 500 を許容)
store_id: z.number().int().nullable(),  // TODO: cmd_217 helper 適用待ち
```

**Phase 2 で cmd_217 が提供する helper** (予告):
```typescript
// cmd_217 で shared/schemas/common/coerce.ts として定義予定
export const coerceNullableInt = z.preprocess(
  (val) => (val === null || val === undefined ? null : Number(val)),
  z.number().int().nullable()
);

// 使い方
store_id: coerceNullableInt,
created_by: coerceNullableInt,
updated_by: coerceNullableInt,
```

---

### Step 5: DATETIME/DATE への z.string() 適用 (AP002)

`dateStrings: true` 設定下では DATETIME が string で返る。DAO スキーマで `z.string()` を使う:

```diff
// shared/schemas/db/staffs.ts
-  last_login_at: z.date().nullable(),
+  last_login_at: z.string().nullable(),   // DATETIME NULL (dateStrings:true → string)

-  created_at: z.date(),
+  created_at: z.string(),                 // DATETIME NOT NULL (dateStrings:true → string)
```

**handler 側での Date 変換は任意**:
DAO スキーマは string で受け取り、handler が必要なら `new Date(staff.created_at)` で変換する。
DAO 層では string のまま保持 — wire format preservation 原則。

---

### Step 6: TINYINT(1)/BOOLEAN への z.number().int().min(0).max(1) 適用 (AP001)

mysql2 は TINYINT(1) および BOOLEAN を `0`/`1` (number) で返す。`z.boolean()` は使えない:

```diff
// shared/schemas/db/staffs.ts
-  is_deleted: z.boolean(),
+  is_deleted: z.number().int().min(0).max(1),   // BOOLEAN NOT NULL (mysql2 → 0/1)
```

**handler 側での boolean 変換**:
`normalizeDbRow()` や inline で `staff.is_deleted === 1` として判定する。
DAO スキーマは `0`/`1` のまま — 意味の変換はアプリケーション層の責務。

---

### Step 7: テストで実際の mysql2 出力を模擬

テストは **mysql2 が実際に返す型**でフィクスチャを組む:

```typescript
// shared/schemas/db/__tests__/staffs.test.ts

describe('AP006: BIGINT coerce', () => {
  it('id が string (mysql2 bigNumberStrings:true) でも coerce で number 化される', () => {
    const mysqlRow = {
      ...validStaff,
      id: '42',          // mysql2 は BIGINT を string で返す
      tenant_id: '10',   // 同上
    };
    const result = StaffSchema.parse(mysqlRow);
    assert.strictEqual(result.id, 42);
    assert.strictEqual(typeof result.id, 'number');
    assert.strictEqual(result.tenant_id, 10);
  });

  it('id が number でも parse 成功 (coerce は idempotent)', () => {
    const result = StaffSchema.parse({ ...validStaff, id: 42, tenant_id: 10 });
    assert.strictEqual(result.id, 42);
  });
});

describe('AP001: TINYINT(1) 0/1', () => {
  it('is_deleted が 0 でも parse 成功', () => {
    const result = StaffSchema.parse({ ...validStaff, is_deleted: 0 });
    assert.strictEqual(result.is_deleted, 0);
  });
  it('is_deleted が 2 は ZodError', () => {
    assert.throws(() => StaffSchema.parse({ ...validStaff, is_deleted: 2 }));
  });
});

describe('AP002: DATETIME dateStrings', () => {
  it('created_at が string でも parse 成功', () => {
    const result = StaffSchema.parse({
      ...validStaff,
      created_at: '2026-04-01 10:00:00',   // mysql2 dateStrings:true の出力形式
    });
    assert.strictEqual(typeof result.created_at, 'string');
  });
});
```

---

## Examples

### cmd_216: BIGINT 5 件への z.coerce.number().int() 適用 (before/after)

**対象 5 件** (staffs / tenants / roles の NOT NULL BIGINT):

```
staffs.id         (BIGINT NOT NULL AUTO_INCREMENT)
staffs.tenant_id  (BIGINT NOT NULL FK → tenants.id)
tenants.id        (BIGINT NOT NULL AUTO_INCREMENT)
roles.id          (BIGINT NOT NULL AUTO_INCREMENT)
roles.tenant_id   (BIGINT NOT NULL FK → tenants.id)
```

**Before (AP006 未対処 — stg1 auth-me 死に体)**:

```typescript
// shared/schemas/db/staffs.ts — Before
export const StaffSchema = z.object({
  id: z.number().int(),         // ← BIGINT だが string が来て ZodError
  tenant_id: z.number().int(),  // ← 同上
  // ...
});

// stg1 でのエラーログ:
// ZodError: [ { code: 'invalid_type', expected: 'number', received: 'string', path: ['id'] } ]
// → auth-me handler が 500 で死に体
```

**After (AP006 対処済 — z.coerce で吸収)**:

```typescript
// shared/schemas/db/staffs.ts — After (cmd_216)
export const StaffSchema = z.object({
  id: z.coerce.number().int(),         // ✅ "42" → 42 に coerce
  tenant_id: z.coerce.number().int(),  // ✅ "10" → 10 に coerce
  // ...
});
```

```typescript
// shared/schemas/db/tenants.ts — After (cmd_216)
export const TenantSchema = z.object({
  id: z.coerce.number().int(),         // ✅ BIGINT coerce
  // ...
});
```

```typescript
// shared/schemas/db/roles.ts — After (cmd_216)
export const RoleSchema = z.object({
  id: z.coerce.number().int(),         // ✅ BIGINT coerce
  tenant_id: z.coerce.number().int(),  // ✅ BIGINT FK coerce
  // ...
});
```

**変更規模**: 各ファイル 1〜2 行の `z.number().int()` → `z.coerce.number().int()` のみ。
handler 側の変更は不要 — DAO スキーマ修正が全 handler に自動適用される。

---

### AP001: TINYINT(1) → z.number().int().min(0).max(1) (before/after)

**Before (AP001 未対処)**:

```typescript
is_deleted: z.boolean(),  // ← mysql2 は 0/1 を返すため ZodError
// ZodError: expected boolean, received number
```

**After (AP001 対処済)**:

```typescript
is_deleted: z.number().int().min(0).max(1),  // ✅ 0/1 を受容
// handler 側: if (staff.is_deleted === 1) { ... }
```

---

### AP002: DATETIME dateStrings → z.string() (before/after)

**Before (AP002 未対処)**:

```typescript
created_at: z.date(),  // ← dateStrings:true で "2026-04-01 10:00:00" が来て ZodError
// ZodError: expected date, received string
```

**After (AP002 対処済)**:

```typescript
created_at: z.string(),  // ✅ string のまま受容
// handler 側で変換が必要なら: new Date(staff.created_at)
```

---

## Guidelines

### driver 接続設定は変更しない (AP006 方針 A 却下の記録)

```
方針 A: bigNumberStrings: false に変更 → BIGINT を number として返す
却下理由: Number.MAX_SAFE_INTEGER (2^53-1 ≈ 9兆) を超える BIGINT 値で
          silent 精度喪失が発生する。Aurora MySQL 8.0 で BIGINT を採用した
          設計は 2^63-1 までを許容しており、方針 A は設計意図を破壊する。

方針 B: z.union([z.number().int(), z.string().regex(/^\d+$/).transform(Number)])
却下理由: schema 記述量増大 + 可読性低下 + Phase 1 の z.coerce 流儀と不整合。
          2 分岐で conditional logic が増え、テストケースも倍増する。

採用: 方針 C — z.coerce.number().int() — 1 トークン変更のみ、Phase 1 流儀と一貫
```

### coerce は DAO 境界のみ (handler 中間層での coerce は禁)

```
✅ DAO スキーマ (shared/schemas/db/*.ts) での z.coerce → 全 handler に自動適用
❌ handler の途中 (中間変数代入) での z.coerce → AP 再発の温床

理由: handler で個別 coerce を書くと:
  1. 別 handler が同じカラムを使った時に修正漏れが生じる
  2. shared スキーマ変更時に handler 側を追随して変更する負債が積み上がる
  3. "DAO スキーマが型の単一真実源" という設計原則が崩れる
```

### nullable BIGINT は coerce 単独不可 — cmd_217 helper 待ち

```
z.coerce.number().int().nullable() は null を 0 に変換してしまう (Number(null)===0)。
nullable BIGINT (store_id, created_by, updated_by 等) は:
  - Phase 1 暫定: z.union([z.null(), z.coerce.number().int()]) で対処
  - Phase 2 cmd_217: shared/schemas/common/coerce.ts の coerceNullableInt helper で統一

nullable BIGINT に coerce 未対応のままにするのは許容 (暫定 B)。
ただし TODO コメントで cmd_217 対応待ちと明記すること。
```

### C004: Aurora MySQL 8.0 前提

本スキルのすべての型ブレ仕様は **Aurora MySQL 8.0 + mysql2 v3.x** 環境を前提とする。
異なる DB/driver 組み合わせでは型ブレの内容が変わるため、本一覧表を適用しないこと。

### 新規テーブル追加時のチェックリスト

DAO スキーマ (`shared/schemas/db/`) に新テーブルを追加する際は必ず確認:

```
□ BIGINT NOT NULL 列 → z.coerce.number().int()
□ BIGINT NULL 列     → z.union([z.null(), z.coerce.number().int()]) (cmd_217 helper 待ち)
□ TINYINT(1)/BOOLEAN 列 → z.number().int().min(0).max(1) (NOT NULL) / .nullable() (NULL)
□ DATETIME/DATE 列  → z.string() (dateStrings:true 前提)
□ INT/SMALLINT 列   → z.number().int() (coerce 不要、mysql2 は number で返す)
□ DECIMAL 列        → z.coerce.number() (driver によっては string で返す)
□ テストは mysql2 実挙動シミュレート (BIGINT は string, BOOLEAN は 0/1 でフィクスチャを組む)
```

---

## References

- `skills/dao-zod-schema-with-test/SKILL.md` — DAO スキーマ作成手順全般（本スキルと組み合わせて使用）
- `skills/boundary-parse-readiness-check-v2/SKILL.md` — DAO スキーマで coerce を定義した後、どこで .parse() を打つかの判断フロー
- `apps/functions/src/shared/db-connection.js` — mysql2 接続設定 (bigNumberStrings/dateStrings の実値)
- `shared/schemas/db/staffs.ts` / `tenants.ts` / `roles.ts` — cmd_216 coerce 適用後の実装例
- `docs/20_DetailDasign/boundary_parse_norm.md` — AP001/AP002/AP006 の詳細仕様と全 handler マトリクス
- cmd_216 計画書 (`queue/work/cmd_216_plan.md`) — 方針 A/B/C 比較と却下理由の記録

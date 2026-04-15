---
name: dao-zod-schema-with-test
description: MySQL テーブルの DDL から shared/schemas/db/*.ts に zod v3 DAO スキーマを実装し、__tests__/*.test.ts を同時作成するパターン。mysql2 の型ドリフト（BIGINT→string、TINYINT→number、DATE→string）への coerce 対処と Node.js built-in test runner 形式のテスト雛形を含む。HearProSupport 等の monorepo で新規テーブルの DAO 境界を追加する際に使用。
---

# DAO Zod Schema with Test

## Overview

MySQL テーブル定義 (DDL) を正ソースとして、`shared/schemas/db/` 配下に zod v3 DAO スキーマと
対応するテストファイルを同時実装するパターン。

**ゴール**: DB 境界でのデータ形状を型安全に保証し、`npm run build` (prebuild フック) が
型エラー・テスト退行を自動検出できる状態を確立すること。

---

## When to Use

以下の状況で使用する:

- 新規 MySQL テーブルに対して `shared/schemas/db/{table}.ts` を追加する時
- 既存 DAO スキーマに nullable 対応・coerce 修正を加える時
- `mysql2` の型ドリフト (BIGINT→string 等) への対処が必要な時
- Phase 展開で DAO スキーマを横展開する際（cases/stores/appointments 等）

**トリガーとなる指示の例**: 「{テーブル名} の DAO スキーマを追加せよ」「DDL から zod schema を作れ」

---

## Instructions

### Step 1: DDL 参照と列型の棚卸し

対象テーブルの DDL (migration ファイルまたは `scripts/migrate/*.sql`) を読み、
以下の観点で各列を棚卸しする:

| MySQL 型 | mysql2 の返却型 | zod 対処 |
|---------|--------------|---------|
| `BIGINT` | `string` (※) | `z.coerce.number().int()` |
| `INT`, `TINYINT`, `SMALLINT` | `number` | `z.number().int()` |
| `TINYINT(1)` (フラグ) | `number` (0/1) | `z.number().int().min(0).max(1)` |
| `VARCHAR`, `TEXT` | `string` | `z.string()` |
| `DATE`, `DATETIME` | `string` (dateStrings: true 時) | `z.string()` |
| `DECIMAL`, `FLOAT` | `string` or `number` | `z.coerce.number()` |
| NOT NULL | — | そのまま |
| DEFAULT NULL | — | `.nullable()` |
| AUTO_INCREMENT | — | Insert schema から除外 |

> ※ mysql2 は BIGINT を文字列で返す (JavaScript Number の精度限界のため)。
>   `z.coerce.number()` で自動変換し、境界での型安全を確保する。

### Step 2: DAO スキーマファイルの作成

`shared/schemas/db/{table}.ts` を新設する:

```typescript
import { z } from 'zod';

// テーブル全列を網羅した DAO スキーマ (DB からの SELECT 結果の形)
export const {Table}Schema = z.object({
  id: z.coerce.number().int(),          // BIGINT AUTO_INCREMENT
  column_a: z.string(),                 // VARCHAR NOT NULL
  column_b: z.number().int().min(0).max(1),  // TINYINT(1) NOT NULL
  column_c: z.string(),                 // DATETIME (dateStrings: true)
  nullable_col: z.string().nullable(),  // VARCHAR DEFAULT NULL
});

export type {Table} = z.infer<typeof {Table}Schema>;
```

**命名規則**:
- エクスポート名: `{Table}Schema`（PascalCase テーブル名 + Schema）
- 型エクスポート: `export type {Table} = z.infer<typeof {Table}Schema>`

### Step 3: INSERT 用部分スキーマの作成 (必要時)

AUTO_INCREMENT id と DB 管理の created_at/updated_at を除く:

```typescript
export const {Table}InsertSchema = {Table}Schema.omit({ id: true, created_at: true, updated_at: true });
export type {Table}Insert = z.infer<typeof {Table}InsertSchema>;
```

### Step 4: テストファイルの作成

`shared/schemas/db/__tests__/{table}.test.ts` を新設する。
テストは Node.js built-in test runner (`import { describe, it } from 'node:test'`) を使用:

```typescript
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { {Table}Schema } from '../{table}.js';

describe('{Table}Schema', () => {
  describe('正常系', () => {
    it('全フィールド正常値で parse 成功', () => {
      const raw = {
        id: 1,
        column_a: 'value',
        column_b: 0,
        column_c: '2024-01-01 00:00:00',
        nullable_col: null,
      };
      const result = {Table}Schema.parse(raw);
      assert.strictEqual(result.id, 1);
    });

    it('BIGINT が文字列で来ても coerce で parse 成功', () => {
      const raw = { id: '999999999999', /* ... */ };
      const result = {Table}Schema.parse(raw);
      assert.strictEqual(typeof result.id, 'number');
    });

    it('nullable_col が null で parse 成功', () => {
      const raw = { /* ..., */ nullable_col: null };
      assert.doesNotThrow(() => {Table}Schema.parse(raw));
    });
  });

  describe('異常系', () => {
    it('必須フィールド欠落で ZodError', () => {
      assert.throws(() => {Table}Schema.parse({}), { name: 'ZodError' });
    });

    it('nullable_col が undefined (欠落) で ZodError', () => {
      const raw = { id: 1, column_a: 'x', column_b: 0, column_c: '2024-01-01' };
      assert.throws(() => {Table}Schema.parse(raw), { name: 'ZodError' });
    });
  });
});
```

**テストケース必須項目** (最低 8〜12 件):
1. 全フィールド正常値で parse 成功
2. BIGINT が string で来ても coerce で通る (該当列がある場合)
3. nullable 列が null で通る
4. nullable 列が有効値で通る
5. 必須フィールド欠落で ZodError
6. nullable 列が undefined (欠落) で ZodError
7. 型違反 (string を int 列に) で ZodError
8. TINYINT(1) フラグが 0/1 で通る (該当列がある場合)

### Step 5: テスト実行と確認

```bash
# 個別テスト実行
cd shared && node --test --import tsx/esm schemas/db/__tests__/{table}.test.ts

# 全体テスト (既存を含む)
npm test
```

Pass count が以前より増えていること、fail 0 であることを確認する。

---

## Examples

### 実装例: staffs テーブル (cmd_213 Phase 1 実績)

**DDL (抜粋)**:
```sql
CREATE TABLE staffs (
  id BIGINT NOT NULL AUTO_INCREMENT,
  email VARCHAR(255) NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  staff_name VARCHAR(100) NOT NULL,
  role_id TINYINT UNSIGNED NOT NULL,
  is_active TINYINT(1) NOT NULL DEFAULT 1,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id)
);
```

**shared/schemas/db/staffs.ts**:
```typescript
import { z } from 'zod';

export const StaffSchema = z.object({
  id: z.coerce.number().int(),           // BIGINT → coerce
  email: z.string(),
  password_hash: z.string(),
  staff_name: z.string(),
  role_id: z.number().int(),             // TINYINT UNSIGNED
  is_active: z.number().int().min(0).max(1),  // TINYINT(1) フラグ
  created_at: z.string(),                // DATETIME (dateStrings: true)
  updated_at: z.string(),
});

export type Staff = z.infer<typeof StaffSchema>;

export const StaffInsertSchema = StaffSchema.omit({
  id: true,
  created_at: true,
  updated_at: true,
});
export type StaffInsert = z.infer<typeof StaffInsertSchema>;
```

**shared/schemas/db/__tests__/staffs.test.ts (抜粋)**:
```typescript
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { StaffSchema } from '../staffs.js';

const validStaff = {
  id: 1,
  email: 'test@example.com',
  password_hash: 'hashed',
  staff_name: 'テストスタッフ',
  role_id: 1,
  is_active: 1,
  created_at: '2024-01-01 00:00:00',
  updated_at: '2024-01-01 00:00:00',
};

describe('StaffSchema', () => {
  describe('正常系', () => {
    it('全フィールド正常値で parse 成功', () => {
      assert.doesNotThrow(() => StaffSchema.parse(validStaff));
    });

    it('id が BIGINT 文字列で来ても coerce で parse 成功', () => {
      const result = StaffSchema.parse({ ...validStaff, id: '9007199254740993' });
      assert.strictEqual(typeof result.id, 'number');
    });

    it('is_active が 0 で parse 成功 (非アクティブ)', () => {
      assert.doesNotThrow(() => StaffSchema.parse({ ...validStaff, is_active: 0 }));
    });
  });

  describe('異常系', () => {
    it('email が欠落すると ZodError', () => {
      const { email, ...rest } = validStaff;
      assert.throws(() => StaffSchema.parse(rest), { name: 'ZodError' });
    });

    it('is_active が 2 だと ZodError (max(1) 制約)', () => {
      assert.throws(() => StaffSchema.parse({ ...validStaff, is_active: 2 }), { name: 'ZodError' });
    });
  });
});
```

---

## Guidelines

### AP001〜006 対処原則 (cmd_213 確立)

| コード | 原則 | 適用場面 |
|--------|------|---------|
| **AP001** | `TINYINT(1)` は `z.number().int().min(0).max(1)` — `z.boolean()` は使わない | mysql2 は boolean を 0/1 数値で返す |
| **AP002** | `DATE`/`DATETIME` は `z.string()` — dateStrings option 前提 | mysql2 の dateStrings: true 設定が必須 |
| **AP003** | `BIGINT` は `z.coerce.number().int()` — 素の `z.number()` は不可 | mysql2 は BIGINT を文字列で返す |
| **AP004** | `.parse()` の戻り値を response に使わない — raw DB 値 (または toCamelCase(raw)) を使う | wire format preservation 原則 |
| **AP005** | `DEFAULT NULL` 列は `.nullable()` 付与 — 欠落と null を区別する | nullable でも `.optional()` は付けない |
| **AP006** | INSERT schema は `AUTO_INCREMENT` id と DB 管理の timestamp を `.omit()` で除く | re-select 方式でも同様 |

### ファイル配置ルール

```
shared/schemas/db/
├── {table}.ts              # DAO スキーマ本体
└── __tests__/
    └── {table}.test.ts     # 対応テスト
```

- schema ファイルと test ファイルは必ずセット。片方だけは禁止。
- import パスは `.js` 拡張子で記述 (ESM 解決の都合: `../staffs.js`)。

### shared/package.json の test スクリプト確認

テスト glob が新規ファイルを自動カバーするか確認する:

```json
"test": "node --test --import tsx/esm schemas/db/__tests__/*.test.ts schemas/api/__tests__/*.test.ts"
```

`*.test.ts` glob は自動で新規ファイルをカバーする。明示追加は不要。

### アンチパターン

- ❌ `z.boolean()` を TINYINT(1) に使う → mysql2 は 0/1 を返すため parse 失敗
- ❌ `z.number()` を BIGINT に使う → 文字列が来て parse 失敗
- ❌ INSERT schema で id を omit し忘れる → DB 側の自動採番と衝突
- ❌ test で `assert.equal` を使う → `assert.strictEqual` / `assert.deepStrictEqual` を使う
- ❌ schema ファイルのみ追加してテストを省略する → prebuild の test カバレッジが不完全になる

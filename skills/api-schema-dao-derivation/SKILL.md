---
name: api-schema-dao-derivation
description: shared/schemas/db/*.ts の DAO zod スキーマを正ソースとして、shared/schemas/api/{entity}/index.ts に API Request/Response zod スキーマを .omit/.partial/.extend 等で派生定義するパターン。新規エンドポイントの API スキーマ追加時、または DAO スキーマと API スキーマの重複宣言を解消する際に使用。HearProSupport 等の monorepo で共有スキーマ層を持つ構成に適用可能。
---

# API Schema DAO Derivation

## Overview

DAO スキーマ（DB 境界のデータ形状）を正ソースとして、API 境界のスキーマを派生定義する。

**ゴール**: API スキーマと DAO スキーマの二重管理を避け、DAO が変われば API スキーマに
自動的に型エラーが伝播する構造を確立すること。

**三層の関係**:
```
DAO 層 (db/*.ts)        → DB の SELECT 結果そのもの (snake_case、DDL 準拠)
API snake 派生層        → DAO から .omit/.partial 等で派生 (Request/ResponseSchema)
API camelCase 独立層    → toCamelCase() 後の shape (z.object() 新規定義が必要)
```

---

## When to Use

以下の状況で使用する:

- 新規 MySQL テーブルに対して CRUD エンドポイントの API スキーマを追加する時
- `shared/schemas/api/{entity}/index.ts` に Request/Response スキーマを定義する時
- DAO スキーマ変更を API スキーマに自動反映させたい時
- 既存コードで DAO と API が重複定義されており、それを解消する時

**トリガーとなる指示の例**: 「{entity} の API スキーマを追加せよ」「DAO 派生で Request スキーマを定義せよ」

---

## Instructions

### Step 1: DAO スキーマの確認

`shared/schemas/db/{entity}.ts` を読み込み、以下を把握する:

- 全フィールドと型
- サーバー管理フィールド（`id`, `created_at`, `updated_at`, `created_by`, `updated_by`, `is_deleted` 等）
- nullable フィールド
- ENUM フィールド

### Step 2: 派生メソッドの選択

API スキーマの種類に応じて派生メソッドを選択する:

| スキーマ種別 | 典型的な派生方法 | 判断基準 |
|-------------|----------------|---------|
| Create (Insert) Request | `.omit({ id, *_at, *_by, is_deleted })` | サーバー管理フィールドを除外 |
| Update (PATCH) Request | `.omit({...}).partial({...})` | 除外後に変更可能フィールドを任意化 |
| Get/List Response | `z.object({ entity: EntitySchema })` | DAO スキーマをそのまま包む |
| List Request (クエリパラメータ) | `z.object({ ... z.coerce.number() ... })` | queryString は全て string で届く |
| camelCase API Request | `z.object({ ... })` 新規定義 | キー名が変わるため派生不可 |
| Legacy 互換 Request | `z.object({ ... })` 新規定義 | 旧 API 契約と DAO が不一致のケース |

#### .omit() の使用

サーバー自動設定フィールドを除外する（作成 Request 等）:

```typescript
export const {Entity}CreateRequestSchema = {Entity}Schema.omit({
  id: true,
  created_at: true,
  updated_at: true,
  created_by: true,
  updated_by: true,
  is_deleted: true,
});
```

#### .omit() + .partial() の組み合わせ

更新 Request（PATCH 相当）でサーバー管理フィールド除外 + 残りを任意化する:

```typescript
export const {Entity}UpdateRequestSchema = {Entity}Schema.omit({
  tenant_id: true,
  created_at: true,
  updated_at: true,
  created_by: true,
  updated_by: true,
  is_deleted: true,
}).partial({
  field_a: true,
  field_b: true,
  // 変更可能フィールドのみ partial
});
```

#### .extend() の使用

DAO にない追加フィールドを API スキーマに加える（JOIN 結果等）:

```typescript
export const {Entity}WithRelationSchema = {Entity}Schema.extend({
  role_name: z.string().nullable(),  // JOIN で追加される列
});
```

### Step 3: camelCase API 層の定義 (必要時)

フロントエンド向けに camelCase で返す場合、`z.object()` で新規定義する。
**DAO からは key 名が変わるため `.omit()` 等では派生できない**:

```typescript
export const {Entity}ApiSchema = z.object({
  id: z.number().int(),
  tenantId: z.number().int(),         // tenant_id → tenantId
  firstName: z.string().max(50),       // first_name → firstName
  familyName: z.string().max(50),
  createdAt: z.date(),                // created_at → createdAt
  // ...
});
```

### Step 4: クエリパラメータの coerce 対応

List 系エンドポイントのクエリパラメータはすべて `string` で届く（API Gateway の仕様）。
数値パラメータには `z.coerce.number()` を必ず使用する:

```typescript
export const {Entity}ListRequestSchema = z.object({
  limit: z.coerce.number().int().positive().optional(),
  offset: z.coerce.number().int().nonnegative().optional(),
  storeId: z.coerce.number().int().optional(),
});
```

### Step 5: ファイル構成とエクスポート

```typescript
// shared/schemas/api/{entity}/index.ts

import { z } from 'zod';
import { {Entity}Schema } from '../../db/{entity}.js';

// 1. DAO 派生 snake_case 版 (内部 API 層)
export const {Entity}CreateRequestSchema = {Entity}Schema.omit({ ... });
export type {Entity}CreateRequest = z.infer<typeof {Entity}CreateRequestSchema>;

export const {Entity}CreateResponseSchema = z.object({ entity: {Entity}Schema });
export type {Entity}CreateResponse = z.infer<typeof {Entity}CreateResponseSchema>;

// 2. camelCase 版 (フロントエンド向け、必要時のみ)
export const {Entity}ApiSchema = z.object({ ... });
export type {Entity}Api = z.infer<typeof {Entity}ApiSchema>;
```

### Step 6: テスト追加

`shared/schemas/api/__tests__/{entity}.test.ts` を新設または追記する:

```typescript
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { {Entity}CreateRequestSchema, {Entity}UpdateRequestSchema } from '../{entity}/index.js';

describe('{Entity}CreateRequestSchema', () => {
  it('必須フィールド全て込みで parse 成功', () => {
    const body = { field_a: 'value', field_b: 1 };
    assert.doesNotThrow(() => {Entity}CreateRequestSchema.parse(body));
  });

  it('サーバー管理フィールド (id) を含んでいても parse 成功 (strip 動作)', () => {
    // zod のデフォルトは strip — 余分なフィールドは除去して parse 成功する
    const body = { id: 999, field_a: 'value', field_b: 1 };
    assert.doesNotThrow(() => {Entity}CreateRequestSchema.parse(body));
  });

  it('必須フィールド欠落で ZodError', () => {
    assert.throws(() => {Entity}CreateRequestSchema.parse({}), { name: 'ZodError' });
  });
});
```

---

## Examples

### 実装例: staffs エンドポイント API スキーマ (cmd_213 Phase 1 実績)

**DAO スキーマ (shared/schemas/db/staffs.ts)**:
```typescript
export const StaffSchema = z.object({
  id: z.number().int(),
  tenant_id: z.number().int(),
  code: z.string().max(50),
  first_name: z.string().max(50),
  family_name: z.string().max(50),
  first_name_kana: z.string().max(50).nullable(),
  store_id: z.number().int().nullable(),
  employment_status: z.enum(['active', 'retired', 'suspended']),
  email: z.string().email().max(255),
  password_hash: z.string().max(255).nullable(),
  is_deleted: z.boolean(),
  created_at: z.date(),
  updated_at: z.date(),
  created_by: z.number().int().nullable(),
  updated_by: z.number().int().nullable(),
  // ...
});
```

**API スキーマ (shared/schemas/api/staffs/index.ts) — 抜粋**:

```typescript
import { StaffSchema } from '../../db/staffs.js';

// ✅ .omit() で DAO 派生 — Create Request
export const StaffCreateRequestSchema = StaffSchema.omit({
  id: true,
  last_login_at: true,
  is_deleted: true,
  created_at: true,
  updated_at: true,
  created_by: true,
  updated_by: true,
});
export type StaffCreateRequest = z.infer<typeof StaffCreateRequestSchema>;

// ✅ .omit() + .partial() — Update Request
export const StaffUpdateRequestSchema = StaffSchema.omit({
  tenant_id: true,
  last_login_at: true,
  is_deleted: true,
  created_at: true,
  updated_at: true,
  created_by: true,
  updated_by: true,
}).partial({
  code: true,
  first_name: true,
  family_name: true,
  email: true,
  password_hash: true,
});
export type StaffUpdateRequest = z.infer<typeof StaffUpdateRequestSchema>;

// ✅ z.object() 新規定義 — camelCase API Request (キー名が変わるため派生不可)
export const StaffCreateApiRequestSchema = z.object({
  lastName: z.string().max(50),
  firstName: z.string().max(50),
  email: z.string().email().max(255),
  storeId: z.coerce.number().int().nullable().optional(),
  employmentStatus: z.enum(['active', 'retired', 'suspended']).optional(),
});
export type StaffCreateApiRequest = z.infer<typeof StaffCreateApiRequestSchema>;

// ✅ z.object() 新規定義 — camelCase Response (toCamelCase() 後の shape)
export const StaffApiSchema = z.object({
  id: z.number().int(),
  tenantId: z.number().int(),
  firstName: z.string().max(50),
  familyName: z.string().max(50),
  storeId: z.number().int().nullable(),
  employmentStatus: z.enum(['active', 'retired', 'suspended']),
  email: z.string().email().max(255),
  isDeleted: z.boolean(),
  createdAt: z.date(),
  updatedAt: z.date(),
});
export type StaffApi = z.infer<typeof StaffApiSchema>;
```

---

## Guidelines

### wire format preservation 原則 (最重要)

`.parse()` の戻り値を HTTP レスポンスボディに直接使ってはならない。
`parse()` は**バリデーション専用**であり、レスポンスには raw DB 値（または `toCamelCase(raw)`）を使う。

```typescript
// ❌ アンチパターン — parse() 戻り値をそのままレスポンスに
const validated = StaffSchema.parse(rows[0]);
return { staff: validated };  // ← zod が strip した値が返る

// ✅ 正しいパターン — raw 値を返す
StaffSchema.parse(rows[0]);   // バリデーションのみ (throws ZodError if invalid)
return { staff: rows[0] };    // raw DB 値をそのまま返す
```

### AP003: key mismatch 回避

DAO と API でキー名が食い違う場合（DynamoDB 旧 API 互換 等）は、
`z.object()` で **新規定義** する。`.omit()` は同一キー名での派生のみに使用する:

```typescript
// ❌ アンチパターン — DAO には name キーがないのに .extend() しようとする
const BadSchema = StaffSchema.extend({ name: z.string() }); // name は DAO に存在しない

// ✅ 正しいパターン — Legacy 契約は z.object() 新規定義
export const StaffUpdateLegacyApiRequestSchema = z.object({
  name: z.string().max(100).optional(),   // DynamoDB 時代の単一フィールド名
  role: z.string().optional(),            // role_id への変換はハンドラが担う
});
```

### queryString の coerce 原則

API Gateway の queryStringParameters はすべて `string` で届く。
数値クエリパラメータは `z.coerce.number()` を必ず使用する:

```typescript
// ❌ z.number() だと string '10' が来た時 ZodError
limit: z.number().int().optional()

// ✅ z.coerce.number() で string → number 自動変換
limit: z.coerce.number().int().positive().optional()
```

### ファイル構成ルール

```
shared/schemas/
├── db/
│   └── {entity}.ts               # DAO スキーマ (正ソース)
└── api/
    └── {entity}/
        └── index.ts              # API スキーマ (DAO 派生)
    └── __tests__/
        └── {entity}.test.ts      # API スキーマのテスト
```

- API スキーマは DAO スキーマを import する（循環参照禁止）。
- import パスは `.js` 拡張子で記述 (ESM 解決: `../../db/staffs.js`)。

### アンチパターン

- ❌ **DAO と API を独立した z.object() で重複定義する** → フィールド追加・変更時に両方修正が必要になる
- ❌ **camelCase 層を DAO から派生しようとする** → キー名が変わるため構造的に不可能
- ❌ **parse() の戻り値をそのままレスポンスに使う** → wire format preservation 違反
- ❌ **queryString の数値に z.number() を使う** → `'10'` が来て ZodError
- ❌ **Legacy 互換スキーマを DAO から派生しようとする** → key mismatch で意図しない型になる

## References

- `skills/dao-zod-schema-with-test/SKILL.md` — DAO スキーマ自体の作成手順
- `skills/api-schema-layer-separation/SKILL.md` — 三層分離（DAO/API snake/API camel）の設計原則
- `shared/schemas/api/staffs/index.ts` — 実装例（cmd_213 Phase 1 実績）
- `docs/20_DetailDasign/boundary_parse_norm.md` — 境界 .parse() 規範書

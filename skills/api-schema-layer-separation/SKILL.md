---
name: api-schema-layer-separation
description: shared/schemas/ を DAO snake_case 層・API snake_case 派生層・API camelCase 独立層・Legacy 互換層の四層に分離して管理するパターン。新規テーブルのスキーマ設計時、handler が wire format を崩しそうな状況、または AP003 class の key mismatch 問題を予防・解消する際に使用。HearProSupport 等の Aurora MySQL + Lambda monorepo に適用可能。
---

# API Schema Layer Separation

## Overview

`shared/schemas/` を責務の異なる四層に分離し、DAO 変更が API スキーマへ型安全に伝播する
構造を確立するパターン。

**解決する問題**: DAO とAPI が独立した z.object() で二重管理されると、テーブル変更時に
両方修正が必要になり、片方の修正漏れが型エラーとして表面化しない。

---

## When to Use

以下の状況で使用する:

- `shared/schemas/` に新規エンティティのスキーマ群を追加する時
- handler の request body parse / response 生成で key mismatch が発生している時
- snake_case ↔ camelCase 境界でデータ変換の責任が曖昧になっている時
- Legacy API 契約（旧 DB 時代の shape）を段階的に是正する計画を立てる時
- Phase 展開で 10+ テーブルのスキーマを横展開する時

**トリガーとなる指示の例**: 「{entity} のスキーマ三層を設計せよ」「API 境界を整理せよ」「camelCase 統一せよ」

---

## 三層（+Legacy）責務境界図

```
┌──────────────────────────────────────────────────────────────────────┐
│  Layer 3: API 境界 camelCase 層                                       │
│  ファイル: shared/schemas/api/{entity}/index.ts                       │
│  Schema 名: {Entity}{Action}ApiRequestSchema                          │
│            {Entity}ApiSchema (toCamelCase 後の shape)                 │
│            {Entity}{Action}ApiResponseSchema                          │
│  → ハンドラが JSON.parse(event.body) 直後に .parse()                  │
│  → toCamelCase(rows) 後のレスポンス shape 定義                        │
│  → z.object() で新規定義 (キー名が変わるため DAO 派生不可)             │
├──────────────────────────────────────────────────────────────────────┤
│  境界変換: apps/functions/src/shared/case-converter.js                │
│  ・toSnakeCase(body)  → Layer 2 の .parse() 可能形に変換              │
│  ・toCamelCase(rows)  → Layer 3 の API レスポンス shape に変換        │
├──────────────────────────────────────────────────────────────────────┤
│  Layer 2: API 境界 snake_case 派生層                                  │
│  ファイル: shared/schemas/api/{entity}/index.ts (同一ファイル)         │
│  Schema 名: {Entity}{Action}RequestSchema                             │
│            {Entity}{Action}ResponseSchema                             │
│  → DAO スキーマから .omit()/.partial()/.pick()/.extend() で派生        │
│  → DB 取得直後の parse に最適 (snake_case のまま扱う内部処理)           │
├──────────────────────────────────────────────────────────────────────┤
│  Layer 1: DAO 層 (DB 定義の単一真実源)                                 │
│  ファイル: shared/schemas/db/{entity}.ts                              │
│  Schema 名: {Entity}Schema                                            │
│  → Aurora MySQL 8.0 の DDL に完全準拠 (snake_case)                    │
│  → DDL 変更時のみ更新。それ以外は変更禁止                               │
│  → 1 ファイル = 1 テーブル (単一責任の原則)                             │
└──────────────────────────────────────────────────────────────────────┘
         ↕ 段階移行（Phase 2+ で是正予定）
┌──────────────────────────────────────────────────────────────────────┐
│  Legacy 互換層                                                        │
│  ファイル: shared/schemas/api/{entity}/index.ts (同一ファイル内)       │
│  Schema 名: {Entity}{Action}LegacyApiRequestSchema                    │
│  → 旧 DB (DynamoDB 等) 時代の API 契約を保持                          │
│  → DAO とは key 名・構造が不一致。z.object() で独立定義               │
│  → Phase 2 以降で段階的に Layer 3 へ移行予定                          │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 命名規則一覧

| 層 | Schema 名 | 型名 | 役割 |
|----|-----------|------|------|
| DAO (L1) | `{Entity}Schema` | `{Entity}` | DB 境界 parse、DDL 準拠 |
| API snake (L2) Request | `{Entity}{Action}RequestSchema` | `{Entity}{Action}Request` | DAO 派生、内部処理 |
| API snake (L2) Response | `{Entity}{Action}ResponseSchema` | `{Entity}{Action}Response` | DAO wrap、内部処理 |
| API camel (L3) Request | `{Entity}{Action}ApiRequestSchema` | `{Entity}{Action}ApiRequest` | 実 body parse |
| API camel (L3) Shape | `{Entity}ApiSchema` | `{Entity}Api` | toCamelCase 後の shape |
| API camel (L3) Response | `{Entity}{Action}ApiResponseSchema` | `{Entity}{Action}ApiResponse` | 実 response shape |
| Legacy | `{Entity}{Action}LegacyApiRequestSchema` | — | 旧 API 契約 (移行予定) |

---

## Instructions

### Step 1: DAO 層 (Layer 1) の配置

`shared/schemas/db/{entity}.ts` に DDL 準拠スキーマを作成する（詳細は `dao-zod-schema-with-test` スキル参照）。

**配置ルール**:
- 1 ファイル = 1 テーブル（単一責任）
- JOIN 結果などの複合スキーマは `.extend()` で DAO を拡張し **同一ファイルに置く**

```typescript
// shared/schemas/db/staffs.ts
export const StaffSchema = z.object({ ... });           // テーブル全列
export const StaffWithRoleSchema = StaffSchema.extend({  // LEFT JOIN 追加列
  role_name: z.string().nullable(),
});
```

### Step 2: API snake_case 派生層 (Layer 2) の配置

`shared/schemas/api/{entity}/index.ts` に DAO から派生定義する:

```typescript
// shared/schemas/api/staffs/index.ts
import { StaffSchema } from '../../db/staffs.js';

// Create: サーバー管理フィールドを除外
export const StaffCreateRequestSchema = StaffSchema.omit({
  id: true, created_at: true, updated_at: true, created_by: true,
  updated_by: true, is_deleted: true, last_login_at: true,
});

// Update: 除外 + 変更可能フィールドを任意化
export const StaffUpdateRequestSchema = StaffSchema
  .omit({ tenant_id: true, created_at: true, updated_at: true, ... })
  .partial({ code: true, first_name: true, email: true, ... });

// Response: DAO スキーマをそのまま包む
export const StaffGetResponseSchema = z.object({ staff: StaffSchema });
```

### Step 3: API camelCase 独立層 (Layer 3) の配置

camelCase 版は **キー名が変わるため DAO から派生不可**。`z.object()` で新規定義する:

```typescript
// camelCase Request (フロントエンド送信 body)
export const StaffCreateApiRequestSchema = z.object({
  lastName: z.string().max(50),
  firstName: z.string().max(50),
  email: z.string().email().max(255),
  storeId: z.coerce.number().int().nullable().optional(),
});

// camelCase Response shape (toCamelCase(rows) 後の shape)
export const StaffApiSchema = z.object({
  id: z.number().int(),
  tenantId: z.number().int(),
  firstName: z.string().max(50),
  familyName: z.string().max(50),
  // ...
});
```

### Step 4: 境界変換器の配置

handler の中で case-converter.js を使い、層間の変換を担う:

```typescript
// apps/functions/src/staffs.post/index.js

// ① リクエスト受信 (camelCase body → parse)
const body = JSON.parse(event.body);
const apiRequest = StaffCreateApiRequestSchema.parse(body);    // Layer 3 parse

// ② DAO 境界 (snake_case 変換 → Layer 2 parse → DB insert)
const snakeBody = toSnakeCase(apiRequest);
StaffCreateRequestSchema.parse(snakeBody);                     // Layer 2 parse (バリデーション)

// ③ DB 取得後 (Layer 1 parse → wire format preservation)
const rows = await db.query('SELECT ...');
StaffSchema.parse(rows[0]);                                    // Layer 1 parse (バリデーションのみ)
return { staff: toCamelCase(rows[0]) };                       // raw 値を camelCase で返す
```

### Step 5: Legacy 層の段階移行戦略

Legacy スキーマが存在する場合、以下の移行フローで対応する:

```
現状                           移行フロー
───────────────────            ───────────────────────────────────
LegacyApiRequestSchema         Phase 2+: Layer 3 に正規 ApiRequestSchema を追加
  name (単一フィールド)    →     → handler の parse 対象を Layer 3 に切替
  role (文字列)           →     → Legacy handler を新 handler に置換
                                → LegacyApiRequestSchema を削除
```

**移行判断基準**:
- Legacy スキーマが使われている handler の数を棚卸しする
- 移行コストが高い場合は、Layer 3 への wrapper を handler 側で作り段階移行する
- 移行前は `LegacyApiRequestSchema` に `@deprecated` コメントと移行予定 Phase を記載する

```typescript
/**
 * @deprecated Phase 2 以降で StaffUpdateApiRequestSchema に移行予定 (Q3 殿裁可)
 * DynamoDB 時代の API 契約。DAO とは key 名・構造が不一致。
 */
export const StaffUpdateLegacyApiRequestSchema = z.object({
  name: z.string().max(100).optional(),   // DynamoDB 時代の単一フィールド
  role: z.string().optional(),
  password: z.string().optional(),
});
```

### Step 6: テスト追加

各層のスキーマに対してテストを追加する:

```typescript
// shared/schemas/api/__tests__/staffs.test.ts
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  StaffCreateRequestSchema,
  StaffCreateApiRequestSchema,
} from '../staffs/index.js';

describe('StaffCreateRequestSchema (Layer 2 snake)', () => {
  it('必須フィールド全て込みで parse 成功', () => {
    const body = { code: 'A001', first_name: '太郎', family_name: '山田',
                   email: 't@ex.com', tenant_id: 1 };
    assert.doesNotThrow(() => StaffCreateRequestSchema.parse(body));
  });
  it('必須フィールド欠落で ZodError', () => {
    assert.throws(() => StaffCreateRequestSchema.parse({}), { name: 'ZodError' });
  });
});

describe('StaffCreateApiRequestSchema (Layer 3 camelCase)', () => {
  it('camelCase body で parse 成功', () => {
    const body = { lastName: '山田', firstName: '太郎', email: 't@ex.com' };
    assert.doesNotThrow(() => StaffCreateApiRequestSchema.parse(body));
  });
});
```

---

## Examples

### 実装例: staffs 三層 minimal slice (cmd_213 Phase 1 実績)

```
shared/schemas/
├── db/
│   └── staffs.ts                   ← Layer 1: DAO (DDL 完全準拠)
└── api/
    ├── staffs/
    │   └── index.ts                ← Layer 2 + Layer 3 + Legacy (同一ファイル)
    └── __tests__/
        └── staffs.test.ts          ← 全層のテスト
```

**Layer 1 → Layer 2 → Layer 3 のデータフロー**:

```
[フロントエンド]
  body: { lastName: '山田', firstName: '太郎', email: 't@ex.com' }
          ↓ StaffCreateApiRequestSchema.parse(body)  [Layer 3 入口 parse]
          ↓ toSnakeCase(body)
  body_snake: { last_name: '山田', first_name: '太郎', email: 't@ex.com' }
          ↓ StaffCreateRequestSchema.parse(body_snake)  [Layer 2 バリデーション]
          ↓ INSERT INTO staffs ...
[DB]
  rows: [{ id: 1, tenant_id: 2, first_name: '太郎', ..., created_at: Date }]
          ↓ StaffSchema.parse(rows[0])  [Layer 1 exit parse — バリデーションのみ]
          ↓ toCamelCase(rows[0])
[レスポンス]
  { staff: { id: 1, tenantId: 2, firstName: '太郎', ..., createdAt: '...' } }
```

---

## Guidelines

### wire format preservation 原則（最重要）

`.parse()` の戻り値をレスポンスに使わない。バリデーション専用で使い、
レスポンスには raw 値（または `toCamelCase(raw)`）を使う:

```typescript
// ❌ parse() 戻り値をレスポンスに使う
const staff = StaffSchema.parse(rows[0]);
return { staff };  // zod が strip した値が返る可能性がある

// ✅ raw 値を返す
StaffSchema.parse(rows[0]);           // バリデーションのみ（throws ZodError if invalid）
return { staff: toCamelCase(rows[0]) };  // raw DB 値を camelCase で返す
```

### AP003: key mismatch — 層間の責任分担

DAO のキー名と API のキー名が一致しない場合（旧 API 互換 等）は、
**Layer 2 の派生を諦めて Layer 3/Legacy 独立定義**にする:

```typescript
// ❌ DAO に 'name' がないのに派生しようとする
const Bad = StaffSchema.pick({ name: true });  // TS エラー: 'name' は DAO に存在しない

// ✅ Legacy 独立定義
export const StaffUpdateLegacyApiRequestSchema = z.object({
  name: z.string().optional(),   // DynamoDB 時代の key (DAO は first_name/family_name)
  role: z.string().optional(),   // DAO は role_id (BIGINT)
});
// コメント: handler が name → family_name 変換、role → role_id 変換を担う
```

### AP006: BIGINT coerce は DAO 層で吸収する

`z.coerce.number()` を DAO 層で定義することで、Layer 2/3 は coerce を気にしなくてよい:

```typescript
// ✅ Layer 1 (DAO) で coerce
export const StaffSchema = z.object({
  id: z.coerce.number().int(),        // ← ここで BIGINT string → number 変換を吸収
  store_id: z.number().int().nullable(),
});

// Layer 2 は coerce を意識せず派生できる
export const StaffGetResponseSchema = z.object({ staff: StaffSchema });
// StaffSchema が coerce を持つため、rows[0].id が string でも通る
```

### Response は全 handler で camelCase 統一

```typescript
// ✅ 正しい
return { statusCode: 200, body: JSON.stringify({ staff: toCamelCase(rows[0]) }) };

// ❌ deprecated (snake_case レスポンス)
return { statusCode: 200, body: JSON.stringify({ staff: rows[0] }) };
```

> 例外: `auth-login` / `auth-me` は現状 toCamelCase 未適用（Phase 2 対応予定の既知問題）。

### Layer 1 の単一責任原則

1 テーブル = 1 ファイル。複数テーブルのカラムを混在させない:

```
✅ db/staffs.ts    → staffs テーブルのみ
✅ db/tenants.ts   → tenants テーブルのみ

❌ db/auth.ts      → staffs + roles + staff_auth_tokens を混在
```

JOIN 結果は DAO ファイル内で `.extend()` する（別ファイル新設は不要）:

```typescript
// db/staffs.ts 内に共置
export const StaffWithRoleSchema = StaffSchema.extend({
  role_name: z.string().nullable(),  // LEFT JOIN roles r ON ... r.name AS role_name
});
```

### アンチパターン

- ❌ **DAO と API を独立した z.object() で二重定義** → DAO 変更時に API が取り残される
- ❌ **camelCase 層を DAO から派生しようとする** → key 名変換は構造的に不可能
- ❌ **境界変換 (toSnakeCase/toCamelCase) を各 handler に直書き** → case-converter.js に集約する
- ❌ **Legacy スキーマを永続化する** → 移行 Phase と担当を明記して技術的負債として管理する
- ❌ **複数テーブルを 1 つの DAO ファイルに混在** → 変更影響が広がり単一責任を破る

## References

- `skills/dao-zod-schema-with-test/SKILL.md` — Layer 1 DAO スキーマの作成手順
- `skills/api-schema-dao-derivation/SKILL.md` — Layer 2/3 の派生メソッド詳細
- `shared/schemas/README.md` — プロジェクト固有の命名規則と DDL マッピング表
- `docs/20_DetailDasign/boundary_parse_norm.md` — 境界 .parse() 規範書（AP001-006 全文）

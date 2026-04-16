---
name: lambda-shared-zod-delivery
description: monorepo の shared/schemas (zod) を各 Lambda handler の zip artifact に自動同梱するパターン。apps/functions/scripts/ensure-shared-deps.js による shared/node_modules 自動復旧 + build-all.js による shared/dist 同梱 + prebuild フックによる verify 連鎖を設計する際に使用。HearProSupport 等の「Aurora MySQL + Lambda + monorepo shared スキーマ」構成に適用可能。
---

# Lambda Shared Zod Delivery

## Overview

monorepo の `shared/schemas` (zod) は Lambda の実行環境（zip artifact）に同梱しなければ
handler が実行時に import できない。このスキルは「build 時に shared/dist を各 handler の
zip 内へ自動配布し、その整合性を prebuild フックで保証する」パターンを定式化する。

**解決する問題**:
- Lambda handler は zip 単体で実行されるため、monorepo の `shared/` には実行時アクセス不可
- `shared/schemas` の変更が Lambda artifact に反映されていないまま deploy されると、
  handler のバリデーションが古いスキーマを使い続ける（AP006 class の問題が再発し得る）
- CI/手動 build 環境で `shared/node_modules` が未整備のまま build が走ると、
  verify が素通りして壊れた artifact が生成される

---

## When to Use

以下の状況で使用する:

- `apps/functions/src/` に新規 Lambda handler を追加し、`shared/schemas` を利用する時
- `shared/schemas` を変更した後、全 Lambda handler を rebuild して artifact を最新化する時
- `shared/node_modules` が未整備で `prebuild` が失敗した時の診断・復旧
- AP006 (BIGINT coerce) 等の shared スキーマ修正が Lambda に届いていない疑いが生じた時

**トリガーとなる指示の例**: 「handler に shared スキーマを同梱せよ」「shared 変更後に rebuild せよ」「ensure-shared-deps を設定せよ」

---

## アーキテクチャ概要図

```
monorepo/
├── shared/                              ← 共有スキーマ層
│   ├── package.json                     ← build / verify / test スクリプト
│   ├── node_modules/  ←─────────────── ensure-shared-deps.js が自動復旧
│   ├── schemas/                         ← zod スキーマ本体 (TS)
│   └── dist/          ←─────────────── build:shared が生成 (CJS)
│       └── schemas/
│           ├── db/staffs.js
│           └── api/staffs/index.js
│
└── apps/functions/
    ├── package.json                     ← prebuild/pretest フック定義
    ├── scripts/
    │   ├── ensure-shared-deps.js        ← shared/node_modules 自動復旧 (idempotent)
    │   └── build-all.js                 ← 各 handler の zip 生成 + shared/dist 同梱
    ├── src/
    │   └── auth-me.get/
    │       ├── index.js                 ← require('./shared/schemas/db/staffs.js') 等
    │       └── package.json             ← zod: ^3.23.0 (handler ローカル)
    └── dist/
        └── auth-me.get.zip              ← Lambda artifact
            ├── index.js
            ├── node_modules/zod/        ← handler ローカルの zod
            └── shared/schemas/          ← shared/dist を同梱 (CJS)
                ├── db/staffs.js
                └── api/staffs/index.js
```

---

## ensure-shared-deps.js の役割

```
apps/functions の prebuild/pretest 実行時
           │
           ▼ node scripts/ensure-shared-deps.js
           │
    shared/node_modules 存在?
           │
    ┌──────┴──────┐
   Yes             No
    │               │
    ▼               ▼
  即 exit 0      package-lock.json 存在?
  (数 ms)          │
           ┌──────┴──────┐
          Yes             No
           │               │
           ▼               ▼
       npm ci          npm install
       (lockfile       (fallback)
        尊重)
           │
           ▼
      shared/node_modules 整備完了
      → verify (typecheck + test) へ続行
```

**設計原則**:
- `existsSync` 1 回判定のみ — 存在時は数 ms で即スキップ (通常運用でほぼゼロコスト)
- `npm ci` 優先 (lockfile 整合)、lockfile 不在時は `npm install` fallback
- 失敗時は exit code で prebuild を止め、明示エラーを handler に出す
- `shell: true` で WSL / macOS / CI 互換性を確保

---

## Instructions

### Step 1: shared/package.json の verify スクリプト確認

`shared/package.json` に `verify` スクリプトが存在することを確認する:

```json
{
  "scripts": {
    "build": "tsc -p tsconfig.build.json && node scripts/mark-dist-commonjs.js",
    "typecheck": "tsc --noEmit",
    "test": "node --test --import tsx/esm schemas/db/__tests__/*.test.ts schemas/api/__tests__/*.test.ts",
    "verify": "npm run typecheck && npm test"
  }
}
```

`verify` がない場合は追加する（`dao-zod-schema-with-test` スキル参照）。

### Step 2: ensure-shared-deps.js の配置

`apps/functions/scripts/ensure-shared-deps.js` を新設する:

```javascript
#!/usr/bin/env node
// shared/node_modules が未整備な場合のみ npm ci/install を走らせる (idempotent)
// 責務: apps/functions の prebuild/pretest 時、shared 依存の自動復旧のみ
// 非責務: apps/functions 自身の node_modules は root scripts/setup.js 担当
import { existsSync } from 'fs';
import { spawnSync } from 'child_process';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));

const sharedDir = resolve(__dirname, '../../../shared');
const nodeModules = resolve(sharedDir, 'node_modules');

if (existsSync(nodeModules)) {
  process.exit(0);  // 存在時即スキップ (数 ms)
}

const hasLock = existsSync(resolve(sharedDir, 'package-lock.json'));
const cmd = hasLock ? 'ci' : 'install';
console.log(`[ensure-shared-deps] shared/node_modules 未整備、npm ${cmd} 実行中...`);
const r = spawnSync('npm', [cmd], { cwd: sharedDir, stdio: 'inherit', shell: true });
process.exit(r.status ?? 1);
```

> **注**: `apps/functions/package.json` が `"type": "module"` の場合、`require()` は使えない。
> ESM `import` + `fileURLToPath` で `__dirname` を再現すること（既存 `build-all.js` と同一パターン）。

### Step 3: apps/functions/package.json の prebuild/pretest フック設定

```json
{
  "scripts": {
    "prebuild": "node scripts/ensure-shared-deps.js && npm --prefix ../../shared run verify",
    "build": "npm run build:shared && npm run build:functions",
    "build:shared": "npm --prefix ../../shared run build",
    "build:functions": "node scripts/build-all.js",
    "pretest": "node scripts/ensure-shared-deps.js && npm --prefix ../../shared run verify",
    "test": "echo 'No apps/functions tests yet' && exit 0"
  }
}
```

**フック順序（build 実行時の全連鎖）**:

```
npm run build
    │
    ▼ [自動: prebuild]
    1. ensure-shared-deps.js     → shared/node_modules 存在確認・自動復旧
    2. shared verify             → typecheck (0 errors) + test (全件 PASS)
    │
    ▼ [build:shared]
    3. shared tsc build          → shared/dist/ 生成 (CJS)
    │
    ▼ [build:functions]
    4. build-all.js              → handler ごとに:
       a. npm install --omit=dev (handler ローカル依存)
       b. shared/schemas 利用を detect
       c. shared/dist/ を zip 内 shared/schemas/ として同梱
       d. .zip 生成
```

### Step 4: handler の package.json に zod を明記

各 Lambda handler ディレクトリの `package.json` に `zod` を明示的に依存として記載する:

```json
{
  "name": "auth-me-get",
  "version": "1.0.0",
  "dependencies": {
    "zod": "^3.23.0",
    "mysql2": "^3.11.0"
  }
}
```

> **理由**: Lambda 実行環境では `zod` は handler の `node_modules/` から解決される。
> `shared/schemas/` (zip 内の CJS モジュール) が import する `zod` も同じ handler の
> `node_modules/zod` が使われるため、バージョン不一致による実行時エラーを防ぐ。

### Step 5: build-all.js の shared/dist 同梱ロジック確認

`build-all.js` が以下を行うことを確認する（または実装する）:

```javascript
// handler の index.js 内の require('./shared/schemas/...') を検出
const schemasDeps = detectSharedDependencies(functionPath)
  .filter(d => d.startsWith('schemas/'));

// shared/schemas を使う handler には shared/dist/ を同梱
if (schemasDeps.length > 0) {
  if (!fs.existsSync(sharedSchemasDistDir)) {
    throw new Error(
      `handler uses shared/schemas but shared/dist not found. ` +
      `Run 'npm run build:shared' first.`
    );
  }
  archive.directory(sharedSchemasDistDir, 'shared/schemas');
}
```

### Step 6: 品質確認

```bash
# clean state から完全 build
cd apps/functions
rm -rf dist
npm run build

# 確認: 85 zip が生成され、auth-me.get.zip に shared/schemas が同梱
unzip -l dist/auth-me.get.zip | grep shared/schemas | head -5

# 確認: shared verify が通ること
npm --prefix ../../shared run verify
```

---

## Examples

### auth-me handler の shared 同梱 (cmd_215 実績)

**handler 側の import パターン** (`src/auth-me.get/index.js`):
```javascript
// shared/schemas を handler 内で参照
const { StaffWithRoleSchema } = require('./shared/schemas/db/staffs.js');
const { AuthLoggedInUserSchema } = require('./shared/schemas/api/auth/index.js');
```

**build 後の zip 構造**:
```
auth-me.get.zip
├── index.js
├── package.json
├── node_modules/
│   ├── zod/          ← handler ローカルの zod (実行時はここから解決)
│   ├── jsonwebtoken/
│   └── mysql2/
└── shared/schemas/   ← shared/dist/ をコピー (CJS 形式)
    ├── package.json  ← {"type": "commonjs"} (mark-dist-commonjs.js が設定)
    ├── db/
    │   ├── staffs.js
    │   └── roles.js
    └── api/
        └── auth/
            └── index.js
```

**ensure-shared-deps.js の実行ログ** (shared/node_modules 不在時):
```
> lambda-functions@1.0.0 prebuild
> node scripts/ensure-shared-deps.js && npm --prefix ../../shared run verify

[ensure-shared-deps] shared/node_modules 未整備、npm ci 実行中...
added 9 packages, audited 10 packages in 2s
found 0 vulnerabilities

> hps-shared@1.0.0 verify
> npm run typecheck && npm test

# pass 144
# fail 0
```

**shared/node_modules 存在時のスキップ**:
```
> node scripts/ensure-shared-deps.js

real 0m0.047s   ← 47ms で即 exit 0、通常運用でほぼゼロコスト
```

---

## Guidelines

### shared 変更時は全 Lambda handler を rebuild する

`shared/schemas` を変更した場合、**全 handler の zip を rebuild** しなければ
古いスキーマが Lambda に残り続ける:

```bash
# shared スキーマ変更後の正しい手順
cd apps/functions
rm -rf dist                          # 古い artifact を完全削除
npm run build                        # 全連鎖で rebuild
# → prebuild: ensure-shared-deps + verify
# → build:shared: shared/dist 再生成
# → build:functions: 全 zip に最新 shared/dist を同梱
```

partial rebuild（特定 handler のみ）は、他の handler が古いスキーマを持つため原則禁止。

### AP006: BIGINT coerce — shared 配布ミスが class-of-problem の誘因

`shared/schemas/db/*.ts` で `z.coerce.number().int()` (AP006) を正しく定義しても、
以下の状況では Lambda に届かず handler が古いスキーマで動き続ける:

```
問題ケース:
  1. shared スキーマを修正 (BIGINT → z.coerce.number() に修正)
  2. shared/dist を再 build する
  3. しかし apps/functions の dist/ を rebuild しない
  4. Lambda artifact は古い shared/schemas を同梱したまま deploy される
  5. BIGINT の string が来ても ZodError が起きなくなる（古い zod 型が残る）

→ 結果: AP006 を修正したつもりが Lambda では無効
```

**防止策**: shared スキーマ変更後は必ず `rm -rf dist && npm run build` (全 handler 再生成)。

### ensure-shared-deps.js の責務境界

| 責務 | 担当 |
|------|------|
| `shared/node_modules` 自動復旧 | `ensure-shared-deps.js` ✅ |
| `apps/functions/node_modules` のセットアップ | プロジェクトルート `scripts/setup.js` |
| 各 handler `node_modules` のセットアップ | `build-all.js` 内の `npm install --omit=dev` |
| `shared/dist` の最新化 | `build:shared` (`npm --prefix ../../shared run build`) |

> `apps/functions/node_modules` が未整備の場合、`ensure-shared-deps.js` は対象外。
> プロジェクトルートの `scripts/setup.js` を実行するか、手動で `npm ci` すること。
> （詳細は `build_deploy_quality_gate.md` §4.4 責務分担参照）

### アンチパターン

- ❌ **shared/dist を git commit する** → build artifact をリポジトリ管理すると dist が stale になる
- ❌ **handler の package.json から zod を省略する** → Lambda 実行時に zod が解決できず実行時エラー
- ❌ **shared スキーマ修正後に dist/ を残したまま build** → 古い artifact が混入する
- ❌ **ensure-shared-deps.js に apps/functions 側の復旧も追加する** → 責務境界違反、root scripts/setup.js が担当
- ❌ **`"type": "module"` の package.json 下で require() を使う** → ReferenceError。ESM import + fileURLToPath で書くこと

## References

- `skills/dao-zod-schema-with-test/SKILL.md` — shared/schemas/db の作成手順
- `skills/api-schema-layer-separation/SKILL.md` — 三層分離設計原則
- `docs/20_DetailDasign/build_deploy_quality_gate.md` — build/deploy 品質ゲート全体図と §4.4 責務分担
- `apps/functions/scripts/ensure-shared-deps.js` — 実装本体 (cmd_215)
- `apps/functions/scripts/build-all.js` — shared/dist → zip 同梱ロジック

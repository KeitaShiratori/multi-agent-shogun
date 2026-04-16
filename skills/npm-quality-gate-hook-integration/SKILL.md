---
name: npm-quality-gate-hook-integration
description: npm lifecycle hook (prebuild/pretest/predeploy) に quality gate (shared 依存整合検証 + typecheck + test) を組込み、手動実行に頼らず build/deploy の品質を強制保証するパターン。ensure-shared-deps.js による shared/node_modules 自動復旧・hook 連鎖図・失敗時 exit code 伝搬・--ignore-scripts 迂回注意を含む。新規 apps/functions パッケージ追加時・CI/CD pipeline 刷新時・shared 配布ミスによる stg 障害再発予防時・deploy 前 gate が任意だった旧運用刷新時に使用。
---

# npm Quality Gate Hook Integration

## Overview

`npm run build` や `npm run deploy:stg` を呼ぶだけで、**typecheck → test → shared/dist 生成 →
全 handler zip 生成** の連鎖が自動で走り、どれか 1 つでも失敗すれば後続が止まる仕組みを
`npm lifecycle hook` で実現するパターン。

```
「手動で npm run verify を忘れた」「shared スキーマ変更後に build し直さなかった」
→ これらを全て npm hook の強制力で封じる。
```

**解決する問題**:
- deploy 前の `shared verify` が任意実行だった → TS エラーや test 失敗が検知されないまま Lambda に壊れたコードが上がる
- `shared/node_modules` 未整備時に `npm run build` を呼ぶと `shared verify` が即失敗 → build 不能
- CI 環境・クリーン環境で `shared/node_modules` が存在しないことがある → build 失敗の再現性不安定
- shared スキーマ変更後に `apps/functions/dist/` を rebuild せず deploy すると、古いスキーマが Lambda に残り続ける (AP006 類の class-of-problem)

**4/7 との役割分担**:

| スキル | 焦点 | 担当範囲 |
|--------|------|---------|
| `lambda-shared-zod-delivery` (4/7) | **配布パターン本体** | shared/dist を Lambda zip に同梱する build-all.js ロジック |
| **本スキル (7/7)** | **hook 強制機構** | npm prebuild/pretest/predeploy で shared 検証を強制実行させる仕組み |

4/7 が「何を zip に入れるか」を設計し、7/7 が「それを必ず最新化させる gate」を提供する。
両スキルを組み合わせて初めて「shared スキーマ変更が確実に Lambda に届く」が実現する。

---

## When to Use

以下の状況で使用する:

- 新規 `apps/functions` パッケージを monorepo に追加し、npm scripts 設計をゼロから行う時
- CI/CD pipeline を整備・刷新し、build/deploy の品質ゲートを自動化する時
- `shared/schemas` 変更後に deploy し忘れ rebuild せず古いスキーマが stg で生き続ける問題が発生した時
- `npm run deploy` 前の `verify` が「開発者の記憶頼み」だった旧運用を刷新する時
- `shared/node_modules` 未整備で `npm run build` が失敗する問題 (CI クリーン環境等) を解決する時

**トリガーとなる指示の例**:
「prebuild に verify を組み込め」「build hook の設計」「ensure-shared-deps を設定せよ」
「deploy gate 強制化」「CI で shared build が通らない」

---

## Instructions

### Step 1: npm scripts 全体設計

`apps/functions/package.json` の scripts を以下の設計で構成する:

```json
{
  "scripts": {
    "prebuild":      "node scripts/ensure-shared-deps.js && npm --prefix ../../shared run verify",
    "build":         "npm run build:shared && npm run build:functions",
    "build:shared":  "npm --prefix ../../shared run build",
    "build:functions": "node scripts/build-all.js",

    "pretest":       "node scripts/ensure-shared-deps.js && npm --prefix ../../shared run verify",
    "test":          "echo 'No unit tests (Phase 2 で integration test 追加予定)' && exit 0",

    "predeploy":     "npm run build && npm test",
    "deploy":        "node scripts/deploy.js",
    "deploy:stg":    "node scripts/deploy.js --env=stg1",
    "deploy:prd":    "node scripts/deploy.js --env=prd0"
  }
}
```

**設計原則**:
- `pre<script>` hook は npm が**自動的に**対応する `<script>` の直前に実行する — 手動呼出不要
- `predeploy` で `npm run build && npm test` を呼ぶことで、deploy 系 (`deploy:stg`/`deploy:prd`) すべてに gate が前置される
- `build:shared` と `build:functions` を分割することで、`shared verify` 失敗時に dist 生成を止められる

---

### Step 2: hook 連鎖の設計

**フル連鎖図** (`npm run build` 実行時):

```
npm run build
      │
      ▼ [自動: prebuild フック]
      ├─ 1. node scripts/ensure-shared-deps.js
      │       │
      │  shared/node_modules 存在?
      │       ├── YES → 即 exit 0 (数 ms スキップ)
      │       └── NO  → npm ci (package-lock.json あり) or npm install (なし)
      │                 失敗なら exit !0 → build 中断
      │
      ├─ 2. npm --prefix ../../shared run verify
      │       ├── tsc --noEmit  (型エラー検出)     → 失敗なら exit !0 → build 中断
      │       └── node --test   (スキーマ test 全件) → 失敗なら exit !0 → build 中断
      │
      ▼ [build:shared]
      3. npm --prefix ../../shared run build
              → shared/dist/ 生成 (CJS、mark-dist-commonjs.js)
              → 失敗なら build 中断
      │
      ▼ [build:functions]
      4. node scripts/build-all.js
              → 各 handler で npm install --omit=dev
              → shared/dist/ を zip 内 shared/schemas/ に同梱
              → .zip 生成 (85 個)
              → 失敗なら build 中断
      │
      ▼
  apps/functions/dist/*.zip (85 個) 完成
```

**deploy 時のフル連鎖** (`npm run deploy:stg` 実行時):

```
npm run deploy:stg
      │
      ▼ [自動: predeploy:stg フック → predeploy フック]
      npm run build  (上記全連鎖、全緑が必須)
      npm test       (pretest → shared verify → echo exit 0)
      │
      ▼ [deploy:stg]
      node scripts/deploy.js --env=stg1
              → dist/*.zip を terraform/stg1/50.functions/dist/ にコピー
              → terraform apply (実機 deploy)
```

---

### Step 3: ensure-shared-deps.js の配置

`apps/functions/scripts/ensure-shared-deps.js` を新設する。
`apps/functions/package.json` が `"type": "module"` の場合は **ESM 形式**で記述する:

```javascript
#!/usr/bin/env node
// shared/node_modules が未整備な場合のみ npm ci/install を走らせる (idempotent)
// 責務: prebuild/pretest 時の shared/node_modules 自動復旧のみ
// 非責務: apps/functions 自身の node_modules → root scripts/setup.js が担当
import { existsSync } from 'fs';
import { spawnSync } from 'child_process';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const sharedDir = resolve(__dirname, '../../../shared');
const nodeModules = resolve(sharedDir, 'node_modules');

if (existsSync(nodeModules)) {
  process.exit(0);  // 存在時: 数 ms で即スキップ (通常運用のほぼゼロコスト)
}

const hasLock = existsSync(resolve(sharedDir, 'package-lock.json'));
const cmd = hasLock ? 'ci' : 'install';
console.log(`[ensure-shared-deps] shared/node_modules 未整備、npm ${cmd} 実行中...`);
const r = spawnSync('npm', [cmd], { cwd: sharedDir, stdio: 'inherit', shell: true });
process.exit(r.status ?? 1);
```

> **注**: `"type": "module"` な package.json 配下では `require()` が使えない。
> `import` + `fileURLToPath` で `__dirname` を再現する (CJS 環境なら `require`/`__dirname` でも可)。
> 詳細は `lambda-shared-zod-delivery` スキル §Step 2 参照。

---

### Step 4: exit code 伝搬の確認

npm hook の失敗が正しく伝搬するかを確認する:

```bash
# prebuild 内のコマンドが exit !0 なら build 全体が止まること
cd apps/functions

# Case A: shared/node_modules を削除 → ensure-shared-deps.js が復旧して build 成功
rm -rf ../../shared/node_modules
npm run build
# → [ensure-shared-deps] ... npm ci 実行 → shared verify → 85 zip 生成

# Case B: shared スキーマに型エラーを混入 → prebuild で検出して build 中断
# (確認後、型エラーを元に戻す)
npm run build
# → prebuild: tsc --noEmit failed → BUILD_EXIT:1 (zip 生成なし)
```

**exit code 伝搬の仕組み**:
- `&&` で連結したコマンドは、前のコマンドが exit !0 なら後続は実行されない
- npm は `pre<script>` が exit !0 なら本体 `<script>` を実行しない
- `spawnSync` は子プロセスの exit code を `r.status` で取得 → `process.exit(r.status ?? 1)` で伝搬

---

### Step 5: CI 対応

GitHub Actions 等での利用例:

```yaml
# .github/workflows/build.yml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '22' }

      # apps/functions の依存インストール
      - run: npm ci
        working-directory: apps/functions

      # npm run build が prebuild で ensure-shared-deps.js を自動実行するため
      # shared/node_modules のセットアップは不要 (ensure-shared-deps.js が担当)
      - run: npm run build
        working-directory: apps/functions

      # dry-run deploy で zip コピーまで確認
      - run: node scripts/deploy.js --dry-run --env=stg1
        working-directory: apps/functions
```

**CI 上のポイント**:
- `shared/node_modules` は `ensure-shared-deps.js` が自動復旧するため、CI 側で事前インストール不要
- `apps/functions/node_modules` は `npm ci` で明示インストールが必要 (自動化対象外)
- dry-run 後の `terraform/*/dist/*.zip` 汚染を CI では `git checkout -- terraform/` で除去する

---

## Examples

### cmd_215: apps/functions/package.json の before/after

**Before (cmd_215 適用前 — shared 依存チェックなし)**:

```json
{
  "scripts": {
    "prebuild": "npm --prefix ../../shared run verify",
    "build":    "npm run build:shared && npm run build:functions && npm test"
  }
}
```

```
問題: shared/node_modules が未整備なら prebuild で tsc --noEmit が即失敗
      CI クリーン環境・新メンバーの初回 clone 後などで再現性不安定
```

**After (cmd_215 適用後 — ensure-shared-deps.js が前置)**:

```json
{
  "scripts": {
    "prebuild": "node scripts/ensure-shared-deps.js && npm --prefix ../../shared run verify",
    "build":    "npm run build:shared && npm run build:functions",
    "pretest":  "node scripts/ensure-shared-deps.js && npm --prefix ../../shared run verify",
    "test":     "echo 'No apps/functions tests yet' && exit 0"
  }
}
```

```
改善: shared/node_modules が未整備でも ensure-shared-deps.js が自動復旧
      shared/node_modules 存在時は 47ms で即スキップ (通常運用コストゼロ)
      npm test 単独呼出時も pretest で shared verify が走る
```

---

### build_deploy_quality_gate.md との対応関係

本スキルの npm hook は `docs/20_DetailDasign/build_deploy_quality_gate.md` に記述された
品質ゲート全体図を実装する。以下の対応で読み替えること:

| docs §2 のボックス | npm scripts の実体 |
|-------------------|-------------------|
| `[自動: prebuild フック]` | `package.json → prebuild` |
| `shared verify (typecheck + test)` | `npm --prefix ../../shared run verify` |
| `[build:shared]` | `package.json → build:shared` |
| `[build:functions]` | `package.json → build:functions` (build-all.js) |
| `apps/functions/dist/*.zip (85 個)` | `lambda-shared-zod-delivery` スキルが担う成果物 |
| `predeploy:stg フック` | `package.json → predeploy` → `npm run build && npm test` |

---

## Guidelines

### --ignore-scripts による gate 迂回への注意

`npm install --ignore-scripts` や `npm run build --ignore-scripts` を使うと、
`pre<script>` hook が**スキップされ**品質 gate が機能しなくなる:

```bash
# ❌ hook をスキップ — gate が無効化される
npm run build --ignore-scripts
npm install --ignore-scripts   # インストール時の hook もスキップ

# ✅ 常に hook 付きで実行
npm run build
```

**CI/CD pipeline で `--ignore-scripts` が使われていないか必ず確認する。**
特に package manager の locking 系ツール (npm ci は問題ない、Yarn/pnpm 移行時は要確認)。

### hook は npm 標準を使い、独自スクリプト管理を最小化する

独自 gate スクリプトを別途管理するより、npm lifecycle hook に組み込む方が:
- `npm run build` 1 コマンドで全 gate が走る
- CI pipeline が `npm run build` を呼ぶだけでよい (CI 側に gate ロジック不要)
- 新メンバーが ops ドキュメントを読まずとも gate が強制実行される

独自スクリプト (`Makefile` / `scripts/build.sh` 等) にしたい場合も、
内部で `npm run build` を呼ぶ形にして hook の強制力を活かすこと。

### apps/functions/node_modules は gate 対象外

`ensure-shared-deps.js` は **shared/node_modules のみ** を対象とする:

```
✅ ensure-shared-deps.js が担う:  shared/node_modules 自動復旧
❌ ensure-shared-deps.js が担わない: apps/functions/node_modules のセットアップ
                                    (プロジェクトルート scripts/setup.js が担当)
```

`apps/functions/node_modules` が未整備だと `build-all.js` が `fs-extra not found` で失敗する。
この状態では `npm ci` を手動で実行してから `npm run build` を呼ぶこと
(詳細は `build_deploy_quality_gate.md` §4.4 責務分担参照)。

### shared スキーマ変更後は必ず全 handler rebuild

shared スキーマを変更した場合、hook 連鎖が確実に動作するよう**全 artifact を再生成**する:

```bash
cd apps/functions
rm -rf dist                # 古い artifact を完全削除
npm run build              # hook 連鎖で全 handler 再生成
```

`dist/` を残したまま `npm run build` すると、一部 zip が古いスキーマを保持したまま
deploy される場合がある。`rm -rf dist` からの clean build を習慣化すること。

### CI pipeline 移植容易性

本スキルの hook 設計は以下を考慮して CI 移植を容易にしている:

- `npm run build` 1 コマンドで完結 → CI の `run:` に 1 行追記するだけ
- `ensure-shared-deps.js` が shared/node_modules を自動整備 → CI での事前準備最小化
- `--dry-run` フラグで zip 生成まで実行し terraform apply のみスキップ → CI での疎通確認が安全
- exit code が正しく伝搬 → CI の `fail-fast` や `if: failure()` が期待通り動く

---

## References

- `skills/lambda-shared-zod-delivery/SKILL.md` — 4/7: shared/dist を Lambda zip に同梱する配布パターン本体（本スキルの補完対象）
- `skills/boundary-parse-readiness-check-v2/SKILL.md` — 5/7: hook gate が守る shared スキーマ境界 .parse() の配置規則
- `skills/mysql-driver-type-drift-boundary-coerce/SKILL.md` — 6/7: hook gate で確認する DAO スキーマの coerce 設計
- `apps/functions/scripts/ensure-shared-deps.js` — gate 本体の実装 (cmd_215 TICKET-091)
- `apps/functions/package.json` — hook 連鎖の定義 (prebuild/pretest/predeploy)
- `docs/20_DetailDasign/build_deploy_quality_gate.md` — 品質ゲート全体図・コマンド一覧・トラブルシュート手順
- cmd_215 計画書 (`queue/work/cmd_215_plan.md`) — 責務分担判断と idempotent 設計選択の記録

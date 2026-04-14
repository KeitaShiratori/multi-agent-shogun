---
name: ticket-batch-issuer
description: 計画書（Markdown）の詳細仕様セクションから、既存チケット体裁に合わせて複数チケットを一括起票するパターン。Phase構成・受入条件・絶対制約・Frozen状態管理の4点を横断的に扱える。プロジェクト横断（HPS/multi-agent-shogun 等）で転用可能。
---

# Ticket Batch Issuer

## Overview

計画書1枚 → 複数チケットmd一括生成。体裁統一と絶対制約の各頁再掲を保証する。

本スキルは「レビュー済の計画書 Markdown を正ソースとし、そこに含まれる各チケット詳細仕様セクションを tickets/todo/ 等の起票先ディレクトリへ体裁統一済み md ファイル群として転記する」機械的バッチ処理パターンを定式化したものである。計画書段階で意思決定が完了していることを前提とし、スキル側では解釈を加えない。

## When to Use

以下の状況でこのスキルを使用する:

- Phase構成のある大型タスクで、フェーズ毎・サブタスク毎にチケットを切り出したい時
- 計画書のレビューは終わっており、あとは tickets/todo/ に転記するだけの段階
- 既存チケット体裁（メタ表＋受入条件＋絶対制約＋関連リソース）を踏襲したい時
- 3 回以上再現されたパターン（cmd_211=7枚 / cmd_208=5枚 / cmd_213=11枚）

### 適用を見送るべきケース

- 計画書がまだドラフトでレビュー未了（起票は意思決定後にすべき）
- チケット 1〜2 枚の少量起票（バッチ化のメリットが薄い。手作業のほうが速い）
- 複数計画書を横断する再編成（本スキルは 1 計画書 → 複数チケットの単方向を扱う）

## Prerequisites

- 正ソースとなる計画書 Markdown（各チケット詳細仕様セクションが分離されていること）
- 起票先のチケット体裁参考ファイル 1 枚
- 起票先ディレクトリ（tickets/todo/ 等）
- 起票先ディレクトリに既存の TICKET-XXX 番号と衝突しない開始番号の確認手段（`ls` / `git log` 等）

## Inputs

| パラメータ | 必須 | 説明 |
|-----------|------|------|
| plan_path | ✓ | 計画書 Markdown の絶対パス |
| output_dir | ✓ | チケット md の出力先ディレクトリ |
| reference_ticket | ✓ | 既存チケット体裁の参考ファイル |
| starting_ticket_number | ✓ | TICKET-XXX の開始番号 |
| constraints_list |  | 絶対制約リスト（C001, C002...）|
| frozen_tickets |  | Frozen 状態にするチケット番号リスト |

### 計画書フォーマットの前提

計画書は以下の構造を持つことを前提とする。満たさない場合は本スキル適用前に計画書側を整えること:

```
# {計画書タイトル}

## Phase 構成（全 N チケット: TICKET-XXX 〜 YYY）
{Phase・担当・見積・依存の表}

## 絶対制約
- **C001**: {制約内容}
- **C002**: {制約内容}
...

## 各チケット詳細仕様

### TICKET-XXX: {タイトル}
- **Phase**: ...
- **優先度**: 🔴/🟡/🟢/⚪
- **見積**: ...
- **依存**: ...
- **状態**: 🔲/🧊

**説明**: ...
**受入条件**: ...
**対象ファイル**: ...
**絶対制約の再掲**: C001 / C002 / ...
```

## Outputs

- output_dir 配下に個別 TICKET-XXX_*.md ファイル群
- 起票サマリレポート（作成件数、ファイルパス一覧、品質ゲート判定結果）

### 生成される TICKET-XXX_*.md の構造

```
# TICKET-XXX: {タイトル}

| 項目 | 内容 |
|------|------|
| **チケットID** | TICKET-XXX |
| **Phase** | ... |
| **優先度** | 🔴/🟡/🟢/⚪ |
| **見積もり** | N日 |
| **状態** | 🔲 Todo / 🧊 Frozen |
| **依存** | TICKET-YYY |
| **親コマンド** | cmd_NNN |

## 説明
{計画書からの転記}

## 受入条件
- [ ] {転記}
- [ ] {転記}

## 対象ファイル
- `{path}`

## 絶対制約（{親コマンド名} 共通）
- **C001**: ...
- **C002**: ...

## 関連リソース
- 親コマンド: ...
- 計画書: {plan_path}
- ブランチ: ...
```

## Processing Flow

1. **計画書をパース**（`## 各チケット詳細仕様` 配下のセクションごとに分割）
2. **メタ情報抽出**（各セクションから優先度・見積・依存・Phase・対象を抽出）
3. **参考チケットの体裁テンプレート抽出**（reference_ticket から表構造・セクション順序を確定）
4. **チケット番号を採番**（連番 or 計画書記載番号。starting_ticket_number と突合し衝突チェック）
5. **個別 md ファイル生成**（メタ表 → 説明 → 受入条件 → 対象ファイル → 絶対制約 → 関連リソース）
6. **品質ゲート判定**（下記 5 項目を全件チェック）
7. **サマリレポート出力**（作成ファイル一覧 + 品質ゲート結果）

### 実装ノート

- 計画書の `### TICKET-XXX:` 見出しで機械的に分割できる
- 受入条件の `- [ ]` チェックリストは行単位で完全一致転記（編集しない）
- 絶対制約は「計画書 `## 絶対制約` セクション全文」を constraints_list で指定された ID に絞って再掲する
- Frozen 判定は計画書状態欄の 🧊 マーカー、または frozen_tickets 引数の明示指定のいずれか

## Quality Gates

全 5 項目を必須チェック（cmd_213 で確立済パターン）:

1. **ファイル配置**: 全ファイルが output_dir 配下に存在する
2. **メタ表整合**: 各ファイルの冒頭メタ表が揃っている（チケットID / Phase / 優先度 / 見積 / 状態 / 依存 / 親コマンド）
3. **受入条件の完全転記**: 受入条件チェックリストが計画書から欠落なく転記されている
4. **絶対制約再掲**: 絶対制約（C001〜C005 等）が全ファイルに再掲されている（grep で件数確認可能）
5. **Frozen 状態の正しさ**: Frozen 指定チケットが 🧊 Frozen 状態になっている（他は 🔲 Todo）

品質ゲート検証の grep 例:

```bash
# (4) 絶対制約再掲の全件チェック
for f in output_dir/TICKET-*.md; do
  grep -c "C001" "$f" || echo "MISSING: $f"
done

# (5) Frozen 状態の突合
grep -l "🧊 Frozen" output_dir/TICKET-*.md
```

## Examples

### 実績例 1: cmd_213 (11 チケット)

| 項目 | 値 |
|------|-----|
| plan_path | queue/work/cmd_213_plan.md |
| output_dir | /mnt/d/dev/papapapapa/HearProSupport/tickets/todo/ |
| reference_ticket | TICKET-075 等の既存 Todo ファイル |
| starting_ticket_number | 076 |
| frozen_tickets | [TICKET-086] |
| 結果 | 11 枚起票、品質ゲート 5 項目 all green、commit a15ca3a |

- 構成: TICKET-076〜086 の 11 枚
- Phase 構成: Phase 0（設計・DDL 調査 1枚）/ Phase 1（認証系パイロット 4枚）/ Phase 2（主要トランザクション 2枚）/ Phase 3（全展開 3枚）/ Phase 4（将来課題 1枚・Frozen）
- 絶対制約: C001〜C005（stg0 禁止 / Prisma 却下 / analytics 参照禁止 / Aurora MySQL / 34 テーブル）
- 特徴: Frozen 指定（TICKET-086）混在の対応を初めて実装したケース

### 実績例 2: cmd_211 (7 チケット)

| 項目 | 値 |
|------|-----|
| plan_path | cmd_211 計画書（HPS ETL/DMS 基盤） |
| output_dir | /mnt/d/dev/papapapapa/HearProSupport/tickets/todo/ |
| starting_ticket_number | 064 |
| frozen_tickets | なし |
| 結果 | TICKET-064〜070 の 7 枚起票（ETL 共通基盤 / DMS CDC / processed schema CDC 等） |

- Phase 構成: Phase 6 レポート拡張基盤
- 絶対制約: C001（stg0 禁止）/ C005（analytics 参照禁止）中心
- 特徴: DMS CDC 方針採用に伴うスキーマ書換え案件。後続チケット（065〜070）との依存チェーンを含む

### 実績例 3: cmd_208 (5 チケット)

| 項目 | 値 |
|------|-----|
| plan_path | cmd_208 計画書（PowerBI 管理体系刷新） |
| output_dir | /mnt/d/dev/papapapapa/HearProSupport/tickets/todo/ |
| starting_ticket_number | 071 |
| frozen_tickets | なし |
| 結果 | TICKET-071〜075 の 5 枚起票（PowerBI データソース / 命名規則 / ロール体系 / 運用手順 / 移行計画） |

- Phase 構成: 単一 Phase（刷新作業一括）
- 絶対制約: C001（stg0 禁止）中心
- 特徴: 命名規則一括変更を含み、bulk-rename-changelog-safety-rule との併用実績あり

## Guidelines

- **計画書が正ソース**: チケット生成は機械的転記であり、解釈を加えない。意味判断が必要なら計画書側に戻る
- **絶対制約の同一文面再掲**: 全ファイルに同一文面で再掲する（grep 検証可能にする）。省略形や要約は禁止
- **Frozen 指定の自動抽出**: 計画書内の 🧊 マーカーから自動抽出を基本とする。frozen_tickets 引数は override 用
- **既存チケット番号との衝突チェック**: starting_ticket_number の整合性を必ず検証する。既存 tickets/todo/ と tickets/done/ の両方を確認する
- **独立 PR 推奨**: 大型展開（10+チケット）時は独立の feature ブランチで作業し、チケット起票専用 PR で早期 develop / main マージする（cmd_213 方針）
- **受入条件のコピー粒度**: 計画書の `- [ ]` を 1 行ずつ完全一致で転記する。まとめたり、文言を整えたりしない
- **変更履歴の安全性**: 計画書側を後から書き換える際は `bulk-rename-changelog-safety-rule` に従い、本文置換と変更履歴追記の順序を守る

## Anti-Patterns

- ❌ **計画書を読まずにスキーマだけから起票する** — 受入条件の欠落リスク。スキーマ（DDL やテーブル一覧）だけでは Phase 構成・依存・絶対制約が埋まらない
- ❌ **チケット番号の重複起票** — 既存番号チェックを怠ると、done/ 配下の歴史チケットと衝突する事故が起きる
- ❌ **絶対制約の省略** — 1 ファイルでも欠けると grep 検証が穴開きになり、将来のドキュメント一括検索で見落としが発生する
- ❌ **本体コード PR と起票 PR を混ぜる** — レビュー観点（設計 vs 実装）が混在し、差し戻しリスクが上がる
- ❌ **計画書をレビュー前にバッチ起票する** — 後から計画書を修正すると、起票済チケット側との乖離が発生する。計画書確定後に起票する
- ❌ **「一旦起票して後で整える」** — 起票直後に整形を後回しにすると、品質ゲート 5 項目のうち特に (3) 受入条件完全転記が崩れる。起票時に完成させる

## References

- `skills/feature-branch-finish/SKILL.md` — 起票 PR のコミット・プッシュ・PR 作成を自動化
- `skills/feature-branch-start/SKILL.md` — 起票前のブランチ作成
- `skills/skill-creator/SKILL.md` — 本スキル自体を含むスキル設計方針
- `skills/yaml-driven-batch-processor/SKILL.md` — バッチ処理パターンの参考（本スキルは Markdown を入力とする特殊ケース）
- Memory MCP `bulk-rename-changelog-safety-rule` — 計画書書き換え時の安全運用

# ticket-batch-issuer

計画書（Markdown）の詳細仕様セクションから、既存チケット体裁に合わせて複数チケットを一括起票するスキル。

詳細仕様は [SKILL.md](./SKILL.md) を参照せよ。

## クイックスタート

1. 計画書をレビュー済みの状態にする（`queue/work/cmd_XXX_plan.md` 等）
2. 起票先ディレクトリと既存チケット番号を確認（`ls tickets/todo/ tickets/done/`）
3. 参考チケットを 1 枚選定（体裁テンプレートとして使用）
4. 本スキルを呼び出し、下記 4 入力を指定:
   - `plan_path` — 計画書の絶対パス
   - `output_dir` — 起票先ディレクトリ
   - `reference_ticket` — 参考チケットファイル
   - `starting_ticket_number` — 開始番号（TICKET-XXX の XXX）
5. 品質ゲート 5 項目の判定結果を確認し、green でなければ計画書または生成ファイルを修正

## ファイル構成

```
skills/ticket-batch-issuer/
├── SKILL.md          # 仕様書（入力/出力/処理フロー/品質ゲート/実績例/ガイドライン）
├── example_plan.md   # 入力例（3 チケット構成の最小計画書サンプル）
└── README.md         # 本ファイル
```

## 適用実績

| コマンド | 起票件数 | 起票先 | 備考 |
|---------|---------|--------|------|
| cmd_213 | 11 枚（TICKET-076〜086） | HPS tickets/todo/ | Frozen 指定混在（TICKET-086）|
| cmd_211 | 7 枚（TICKET-064〜070） | HPS tickets/todo/ | ETL/DMS 基盤 |
| cmd_208 | 5 枚（TICKET-071〜075） | HPS tickets/todo/ | PowerBI 管理体系刷新 |

## 関連スキル

- [`skills/feature-branch-start`](../feature-branch-start/SKILL.md) — 起票用 feature ブランチの作成
- [`skills/feature-branch-finish`](../feature-branch-finish/SKILL.md) — 起票 PR のコミット・プッシュ・PR 作成

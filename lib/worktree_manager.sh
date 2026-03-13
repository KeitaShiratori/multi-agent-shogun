#!/usr/bin/env bash
# worktree_manager.sh — Git Worktree管理ライブラリ (B1: 足軽作業分離)
#
# 提供関数:
#   worktree_create(task_id, ashigaru_id)  → worktreeパスを作成してechoで返す
#   worktree_remove(task_id)              → worktreeを削除
#   worktree_list()                       → 既存worktree一覧（task_id付き）
#   worktree_path(task_id)                → task_idに対応するworktreeパス
#
# Worktree配置:
#   /tmp/shogun-worktrees/{task_id}/       ← 各足軽の作業空間
#   ブランチ名: worktree/{task_id}
#
# 設計方針:
#   - Docker不採用（Claude Code/MCP/tmux統合困難, WSL2パフォーマンス問題）
#   - Git worktreeで足軽専用作業空間を隔離
#   - タスク完了後に自動清掃
#   - git stash多発による競合を防ぐ

set -u

WORKTREE_MANAGER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_BASE_DIR="${WORKTREE_BASE_DIR:-/tmp/shogun-worktrees}"
PROJECT_ROOT="$(cd "${WORKTREE_MANAGER_DIR}/.." && pwd)"

# --- 内部ヘルパー ---

_wt_task_to_path() {
    local task_id="$1"
    echo "${WORKTREE_BASE_DIR}/${task_id}"
}

_wt_task_to_branch() {
    local task_id="$1"
    echo "worktree/${task_id}"
}

# --- 公開関数 ---

# worktree_create task_id [ashigaru_id]
# 足軽専用worktreeを作成する。
# Returns: worktreeのフルパス（stdout）
# task YAML の worktree: フィールドにこのパスを設定する。
worktree_create() {
    local task_id="$1"
    local ashigaru_id="${2:-unknown}"
    local wt_path
    wt_path=$(_wt_task_to_path "$task_id")
    local branch
    branch=$(_wt_task_to_branch "$task_id")

    # 既存チェック
    if [[ -d "$wt_path" ]]; then
        echo "worktree_create: ${task_id} already exists at ${wt_path}" >&2
        echo "$wt_path"
        return 0
    fi

    # ベースディレクトリ作成
    mkdir -p "$WORKTREE_BASE_DIR"

    # worktree作成（現在のHEADから新ブランチ）
    if ! git -C "$PROJECT_ROOT" worktree add "$wt_path" -b "$branch" 2>&1; then
        # ブランチが既存の場合はリセットして再作成
        echo "worktree_create: branch ${branch} exists, trying without -b" >&2
        if ! git -C "$PROJECT_ROOT" worktree add "$wt_path" "$branch" 2>&1; then
            echo "Error: worktree_create failed for ${task_id}" >&2
            return 1
        fi
    fi

    echo "worktree_create: ${task_id} → ${wt_path} (ashigaru: ${ashigaru_id})" >&2
    echo "$wt_path"
}

# worktree_remove task_id [--force]
# worktreeを削除し、ブランチも削除する。
worktree_remove() {
    local task_id="$1"
    local force_flag="${2:-}"
    local wt_path
    wt_path=$(_wt_task_to_path "$task_id")
    local branch
    branch=$(_wt_task_to_branch "$task_id")

    if [[ ! -d "$wt_path" ]]; then
        echo "worktree_remove: ${task_id} not found (already removed?)" >&2
        return 0
    fi

    # worktree削除
    if [[ "$force_flag" == "--force" ]]; then
        git -C "$PROJECT_ROOT" worktree remove --force "$wt_path" 2>&1 || rm -rf "$wt_path"
    else
        git -C "$PROJECT_ROOT" worktree remove "$wt_path" 2>&1 || {
            echo "worktree_remove: clean removal failed, use --force to override" >&2
            return 1
        }
    fi

    # ブランチ削除（マージ済みでない場合はスキップ）
    git -C "$PROJECT_ROOT" branch -d "$branch" 2>/dev/null \
        || echo "worktree_remove: branch ${branch} not deleted (unmerged or not found)" >&2

    echo "worktree_remove: ${task_id} removed"
}

# worktree_list
# 既存worktree一覧（task_id と パス）を表示
worktree_list() {
    git -C "$PROJECT_ROOT" worktree list --porcelain 2>/dev/null \
        | awk '/^worktree /{path=$2} /^branch /{branch=$2} /^$/{
            if (path ~ /shogun-worktrees/) {
                split(path, a, "/")
                task=a[length(a)]
                printf "%-30s %s\n", task, path
            }
            path=""; branch=""
        }'
}

# worktree_path task_id
# task_idに対応するworktreeパスを返す（存在しない場合は空文字）
worktree_path() {
    local task_id="$1"
    local wt_path
    wt_path=$(_wt_task_to_path "$task_id")
    if [[ -d "$wt_path" ]]; then
        echo "$wt_path"
    else
        echo ""
    fi
}

# worktree_exists task_id
# worktreeが存在するか確認（0=存在, 1=非存在）
worktree_exists() {
    local task_id="$1"
    local wt_path
    wt_path=$(_wt_task_to_path "$task_id")
    [[ -d "$wt_path" ]]
}

# worktree_cleanup_all
# 全shogunワークツリーを強制削除（緊急クリーンアップ用）
worktree_cleanup_all() {
    echo "worktree_cleanup_all: removing all shogun worktrees..." >&2
    local removed=0
    for dir in "${WORKTREE_BASE_DIR}"/*/; do
        [[ -d "$dir" ]] || continue
        local task_id
        task_id=$(basename "$dir")
        worktree_remove "$task_id" --force && (( removed++ )) || true
    done
    echo "worktree_cleanup_all: removed ${removed} worktrees"
}

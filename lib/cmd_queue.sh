#!/usr/bin/env bash
# cmd_queue.sh — コマンドキュー管理ライブラリ (B2: コマンドキュー分離)
#
# 提供関数:
#   cmd_write(cmd_id, yaml_content)   → queue/commands/pending/cmd_XXX.yaml を作成
#   cmd_activate(cmd_id, karo_id)     → pending → active に移動
#   cmd_done(cmd_id)                  → active → done に移動
#   cmd_list(state)                   → pending|active|done のcmd_id一覧
#   cmd_read(cmd_id)                  → cmd YAMLを読む（state問わず）
#   cmd_count(state)                  → pending|active のcmd数（バックプレッシャー用）
#   cmd_pending_for(karo_id)          → 指定家老宛のpending cmd一覧
#
# ディレクトリ構造:
#   queue/commands/pending/cmd_XXX.yaml  ← 将軍が書く
#   queue/commands/active/cmd_XXX.yaml   ← 家老が処理中
#   queue/commands/done/cmd_XXX.yaml     ← 完了（アーカイブ）
#
# バックプレッシャー:
#   pending が BACKPRESSURE_THRESHOLD (デフォルト3) 件超で警告

set -u

CMD_QUEUE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../queue/commands"
CMD_PENDING_DIR="${CMD_QUEUE_DIR}/pending"
CMD_ACTIVE_DIR="${CMD_QUEUE_DIR}/active"
CMD_DONE_DIR="${CMD_QUEUE_DIR}/done"
CMD_LOCK_FILE="${CMD_QUEUE_DIR}/.cmd_queue.lock"
CMD_LOCK_TIMEOUT=10

BACKPRESSURE_THRESHOLD="${BACKPRESSURE_THRESHOLD:-3}"

# --- 内部ヘルパー ---

_cmd_lock() {
    if command -v flock &>/dev/null; then
        exec 201>"$CMD_LOCK_FILE"
        if ! flock -w "$CMD_LOCK_TIMEOUT" 201; then
            echo "Error: cmd_queue lock timeout" >&2
            return 1
        fi
    fi
}

_cmd_unlock() {
    if command -v flock &>/dev/null; then
        flock -u 201 2>/dev/null || true
    fi
}

_cmd_find() {
    local cmd_id="$1"
    for dir in "$CMD_PENDING_DIR" "$CMD_ACTIVE_DIR" "$CMD_DONE_DIR"; do
        local f="${dir}/${cmd_id}.yaml"
        if [[ -f "$f" ]]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

# --- 公開関数 ---

# cmd_write cmd_id yaml_content
# pending にcmd YAMLを書く。バックプレッシャー警告付き。
cmd_write() {
    local cmd_id="$1"
    local yaml_content="$2"
    local target="${CMD_PENDING_DIR}/${cmd_id}.yaml"

    _cmd_lock

    # バックプレッシャーチェック
    local count
    count=$(cmd_count pending)
    if (( count >= BACKPRESSURE_THRESHOLD )); then
        echo "WARNING: cmd_queue backpressure — ${count} pending cmds (threshold: ${BACKPRESSURE_THRESHOLD})" >&2
        echo "BACKPRESSURE: Consider waiting for karo to process existing cmds." >&2
    fi

    printf '%s\n' "$yaml_content" > "$target"
    _cmd_unlock
    echo "cmd_write: ${cmd_id} → pending"
}

# cmd_activate cmd_id [karo_id]
# pending → active に移動。assigned_to フィールドを更新。
cmd_activate() {
    local cmd_id="$1"
    local karo_id="${2:-karo1}"
    local src="${CMD_PENDING_DIR}/${cmd_id}.yaml"
    local dst="${CMD_ACTIVE_DIR}/${cmd_id}.yaml"

    if [[ ! -f "$src" ]]; then
        echo "Error: cmd_activate — ${cmd_id} not found in pending" >&2
        return 1
    fi

    _cmd_lock
    mv "$src" "$dst"
    # status: pending → in_progress に更新
    sed -i 's/^status: pending$/status: in_progress/' "$dst"
    _cmd_unlock
    echo "cmd_activate: ${cmd_id} → active (${karo_id})"
}

# cmd_done cmd_id
# active → done に移動。
cmd_done() {
    local cmd_id="$1"
    local src="${CMD_ACTIVE_DIR}/${cmd_id}.yaml"
    local dst="${CMD_DONE_DIR}/${cmd_id}.yaml"

    if [[ ! -f "$src" ]]; then
        echo "Error: cmd_done — ${cmd_id} not found in active" >&2
        return 1
    fi

    _cmd_lock
    mv "$src" "$dst"
    sed -i 's/^status: in_progress$/status: done/' "$dst"
    _cmd_unlock
    echo "cmd_done: ${cmd_id} → done"
}

# cmd_list [state]
# state: pending|active|done|all (default: all)
cmd_list() {
    local state="${1:-all}"
    local dirs=()

    case "$state" in
        pending) dirs=("$CMD_PENDING_DIR") ;;
        active)  dirs=("$CMD_ACTIVE_DIR") ;;
        done)    dirs=("$CMD_DONE_DIR") ;;
        all)     dirs=("$CMD_PENDING_DIR" "$CMD_ACTIVE_DIR" "$CMD_DONE_DIR") ;;
        *)
            echo "Error: cmd_list — unknown state: $state" >&2
            return 1
            ;;
    esac

    for dir in "${dirs[@]}"; do
        for f in "${dir}"/*.yaml; do
            [[ -f "$f" ]] || continue
            basename "$f" .yaml
        done
    done
}

# cmd_read cmd_id
# cmd YAMLを読む（state問わず検索）
cmd_read() {
    local cmd_id="$1"
    local path
    path=$(_cmd_find "$cmd_id") || {
        echo "Error: cmd_read — ${cmd_id} not found" >&2
        return 1
    }
    cat "$path"
}

# cmd_count [state]
# pending|active のcmd数を返す
cmd_count() {
    local state="${1:-pending}"
    local count=0
    local dir

    case "$state" in
        pending) dir="$CMD_PENDING_DIR" ;;
        active)  dir="$CMD_ACTIVE_DIR" ;;
        done)    dir="$CMD_DONE_DIR" ;;
        *)       dir="$CMD_PENDING_DIR" ;;
    esac

    for f in "${dir}"/*.yaml; do
        [[ -f "$f" ]] && (( count++ )) || true
    done
    echo "$count"
}

# cmd_pending_for karo_id
# 指定家老宛のpending cmd_id一覧を返す
cmd_pending_for() {
    local karo_id="$1"

    for f in "${CMD_PENDING_DIR}"/*.yaml; do
        [[ -f "$f" ]] || continue
        local assigned
        assigned=$(grep -m1 '^assigned_to:' "$f" 2>/dev/null | awk '{print $2}' || true)
        # assigned_to 未設定はkaro1扱い
        if [[ -z "$assigned" && "$karo_id" == "karo1" ]] || [[ "$assigned" == "$karo_id" ]]; then
            basename "$f" .yaml
        fi
    done
}

# cmd_status cmd_id
# cmd の現在のstate (pending|active|done|not_found) を返す
cmd_status() {
    local cmd_id="$1"

    [[ -f "${CMD_PENDING_DIR}/${cmd_id}.yaml" ]] && echo "pending" && return
    [[ -f "${CMD_ACTIVE_DIR}/${cmd_id}.yaml" ]]  && echo "active"  && return
    [[ -f "${CMD_DONE_DIR}/${cmd_id}.yaml" ]]    && echo "done"    && return
    echo "not_found"
}

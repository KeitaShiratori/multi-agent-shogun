#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# PR Review Daemon - Copilot レビュー自動取得デーモン
# ═══════════════════════════════════════════════════════════════════════════════
#
# queue/pr/ready/ を監視し、PR作成後にCopilotレビューを自動取得する。
# 結果を queue/pr/done/ に出力し、tmux send-keys で家老に通知する。
#
# Usage:
#   ./scripts/pr_review_daemon.sh start        # バックグラウンド起動
#   ./scripts/pr_review_daemon.sh stop         # 停止
#   ./scripts/pr_review_daemon.sh restart      # 再起動
#   ./scripts/pr_review_daemon.sh status       # 稼働状況表示
#   ./scripts/pr_review_daemon.sh --foreground # フォアグラウンド実行（デバッグ用）

set -euo pipefail

# ディレクトリ設定
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PID_FILE="$SCRIPT_DIR/.pr_review_daemon.pid"
LOG_FILE="$BASE_DIR/logs/pr_review_daemon.log"

# キューディレクトリ
READY_DIR="$BASE_DIR/queue/pr/ready"
INPROGRESS_DIR="$BASE_DIR/queue/pr/inprogress"
DONE_DIR="$BASE_DIR/queue/pr/done"

# 設定
POLL_INTERVAL=30          # 監視間隔（秒）
COPILOT_WAIT=120          # Copilotレビュー待機時間（秒）
COPILOT_TIMEOUT=300       # Copilotレビュータイムアウト（秒）
STUCK_THRESHOLD=600       # inprogress滞留閾値（秒）
MAX_RETRY=3               # gh api リトライ回数

# ═══════════════════════════════════════════════════════════════════════════════
# ログ関数
# ═══════════════════════════════════════════════════════════════════════════════
log() {
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" >> "$LOG_FILE"
    if [ "${FOREGROUND:-false}" = true ]; then
        echo "[$timestamp] $1"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# ディレクトリ初期化
# ═══════════════════════════════════════════════════════════════════════════════
ensure_dirs() {
    mkdir -p "$READY_DIR" "$INPROGRESS_DIR" "$DONE_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
}

# ═══════════════════════════════════════════════════════════════════════════════
# PID管理
# ═══════════════════════════════════════════════════════════════════════════════
is_running() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        else
            # stale PID file
            log "WARN: Stale PID file detected (pid=$pid). Removing."
            rm -f "$PID_FILE"
            return 1
        fi
    fi
    return 1
}

write_pid() {
    echo $$ > "$PID_FILE"
}

remove_pid() {
    rm -f "$PID_FILE"
}

# ═══════════════════════════════════════════════════════════════════════════════
# シグナルハンドリング
# ═══════════════════════════════════════════════════════════════════════════════
cleanup() {
    log "INFO: Shutting down PR Review Daemon (pid=$$)"
    remove_pid
    exit 0
}

trap cleanup SIGTERM SIGINT SIGHUP

# ═══════════════════════════════════════════════════════════════════════════════
# tmux通知（家老に send-keys）
# ═══════════════════════════════════════════════════════════════════════════════
notify_karo() {
    local karo_id="$1"
    local message="$2"

    # tmuxセッションが存在するか確認
    if ! tmux has-session -t multiagent 2>/dev/null; then
        log "WARN: tmux session 'multiagent' not found. Skipping notification."
        return 0
    fi

    # karo_id から pane を特定
    local pane
    pane=$(tmux list-panes -t multiagent:agents -F '#{pane_index}' -f "#{==:#{@agent_id},${karo_id}}" 2>/dev/null | head -1)

    if [ -z "$pane" ]; then
        log "WARN: Could not find pane for ${karo_id}. Skipping notification."
        return 0
    fi

    tmux send-keys -t "multiagent:agents.${pane}" "$message" 2>/dev/null || true
    sleep 0.5
    tmux send-keys -t "multiagent:agents.${pane}" Enter 2>/dev/null || true
    log "INFO: Notified ${karo_id} (pane ${pane})"
}

# ═══════════════════════════════════════════════════════════════════════════════
# YAML値取得（軽量パーサ、外部依存なし）
# ═══════════════════════════════════════════════════════════════════════════════
yaml_get() {
    local file="$1"
    local key="$2"
    grep "^${key}:" "$file" 2>/dev/null | head -1 | sed "s/^${key}: *//; s/\"//g; s/'//g" | tr -d '[:space:]' || echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# Copilotレビュー取得（gh api + --jq）
# ═══════════════════════════════════════════════════════════════════════════════
fetch_copilot_review() {
    local repo="$1"
    local pr_number="$2"
    local retry=0
    local backoff=5

    while [ $retry -lt $MAX_RETRY ]; do
        local result
        result=$(gh api "repos/${repo}/pulls/${pr_number}/comments" --jq '
            [.[] | select(.user.login | test("copilot"; "i"))] |
            if length == 0 then
                { "has_review": false, "total_comments": 0, "comments": [] }
            else
                {
                    "has_review": true,
                    "total_comments": length,
                    "comments": [.[] | {
                        "file": .path,
                        "line": .line,
                        "body": .body
                    }]
                }
            end
        ' 2>/dev/null) && {
            echo "$result"
            return 0
        }

        retry=$((retry + 1))
        log "WARN: gh api failed (attempt ${retry}/${MAX_RETRY}). Retrying in ${backoff}s..."
        sleep $backoff
        backoff=$((backoff * 2))
    done

    log "ERROR: gh api failed after ${MAX_RETRY} retries for ${repo}#${pr_number}"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# PR処理メインロジック
# ═══════════════════════════════════════════════════════════════════════════════
process_pr() {
    local yaml_file="$1"
    local filename
    filename=$(basename "$yaml_file")

    log "INFO: Processing ${filename}"

    # YAML値読み取り
    local pr_number repo cmd_id notify created_by branch
    pr_number=$(yaml_get "$yaml_file" "pr_number")
    repo=$(yaml_get "$yaml_file" "repo")
    cmd_id=$(yaml_get "$yaml_file" "cmd_id")
    notify=$(yaml_get "$yaml_file" "notify")
    created_by=$(yaml_get "$yaml_file" "created_by")
    branch=$(yaml_get "$yaml_file" "branch")

    if [ -z "$pr_number" ] || [ -z "$repo" ]; then
        log "ERROR: Invalid YAML (missing pr_number or repo): ${filename}"
        mv "$yaml_file" "$DONE_DIR/${filename%.yaml}_error.yaml"
        return 1
    fi

    # inprogress に移動
    mv "$yaml_file" "$INPROGRESS_DIR/$filename"
    local inprogress_file="$INPROGRESS_DIR/$filename"

    # Copilotレビュー待機
    log "INFO: Waiting ${COPILOT_WAIT}s for Copilot review on ${repo}#${pr_number}"
    sleep $COPILOT_WAIT

    # レビュー取得（タイムアウトまでリトライ）
    local elapsed=$COPILOT_WAIT
    local review_json=""
    local has_review=false

    while [ $elapsed -lt $COPILOT_TIMEOUT ]; do
        review_json=$(fetch_copilot_review "$repo" "$pr_number") && {
            # has_review チェック
            local check
            check=$(echo "$review_json" | grep -o '"has_review": *true' || true)
            if [ -n "$check" ]; then
                has_review=true
                break
            fi
        }
        sleep 30
        elapsed=$((elapsed + 30))
        log "INFO: Still waiting for Copilot review... (${elapsed}s elapsed)"
    done

    # 結果YAML生成
    local reviewed_at
    reviewed_at=$(date "+%Y-%m-%dT%H:%M:%S")
    local done_file="$DONE_DIR/$filename"

    if [ "$has_review" = true ]; then
        # Copilotレビューあり
        local total_comments
        total_comments=$(echo "$review_json" | grep -o '"total_comments": *[0-9]*' | grep -o '[0-9]*' || echo "0")

        # YAML形式で結果を書き出し
        cat > "$done_file" << DONE_EOF
pr_number: ${pr_number}
repo: "${repo}"
cmd_id: ${cmd_id}
branch: "${branch}"
created_by: ${created_by}
notify: ${notify}
status: reviewed
reviewed_at: "${reviewed_at}"
review_summary:
  total_comments: ${total_comments}
  raw_json: |
$(echo "$review_json" | sed 's/^/    /')
DONE_EOF
        log "INFO: Copilot review found for ${repo}#${pr_number} (${total_comments} comments)"
    else
        # Copilotレビューなし（タイムアウト）
        cat > "$done_file" << DONE_EOF
pr_number: ${pr_number}
repo: "${repo}"
cmd_id: ${cmd_id}
branch: "${branch}"
created_by: ${created_by}
notify: ${notify}
status: no_review
reviewed_at: "${reviewed_at}"
review_summary:
  total_comments: 0
  note: "Copilot review not received within ${COPILOT_TIMEOUT}s timeout"
DONE_EOF
        log "INFO: No Copilot review for ${repo}#${pr_number} (timeout after ${COPILOT_TIMEOUT}s)"
    fi

    # inprogress ファイル削除
    rm -f "$inprogress_file"

    # 家老に通知
    local status_label
    if [ "$has_review" = true ]; then
        status_label="Copilotレビュー取得済み"
    else
        status_label="Copilotレビューなし（タイムアウト）"
    fi

    if [ -n "$notify" ]; then
        notify_karo "$notify" "PR#${pr_number}（${cmd_id}）の${status_label}。queue/pr/done/${filename} を確認せよ。"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# スタック回復（inprogress に滞留したファイルを ready に戻す）
# ═══════════════════════════════════════════════════════════════════════════════
recover_stuck() {
    local now
    now=$(date +%s)

    for file in "$INPROGRESS_DIR"/*.yaml; do
        [ -f "$file" ] || continue

        local file_mtime
        file_mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo "$now")
        local age=$((now - file_mtime))

        if [ $age -gt $STUCK_THRESHOLD ]; then
            local filename
            filename=$(basename "$file")
            log "WARN: Recovering stuck file: ${filename} (age=${age}s > threshold=${STUCK_THRESHOLD}s)"
            mv "$file" "$READY_DIR/$filename"
        fi
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# メインループ
# ═══════════════════════════════════════════════════════════════════════════════
daemon_loop() {
    log "INFO: PR Review Daemon started (pid=$$)"
    write_pid

    while true; do
        # スタック回復
        recover_stuck

        # ready/ 内のファイルを処理
        for yaml_file in "$READY_DIR"/*.yaml; do
            [ -f "$yaml_file" ] || continue
            process_pr "$yaml_file" || true
        done

        sleep $POLL_INTERVAL
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# CLI コマンド
# ═══════════════════════════════════════════════════════════════════════════════
cmd_start() {
    ensure_dirs
    if is_running; then
        local pid
        pid=$(cat "$PID_FILE")
        echo "PR Review Daemon is already running (pid=${pid})"
        return 0
    fi

    echo "Starting PR Review Daemon..."
    nohup "$0" --foreground >> "$LOG_FILE" 2>&1 &
    local daemon_pid=$!
    echo "$daemon_pid" > "$PID_FILE"
    echo "PR Review Daemon started (pid=${daemon_pid})"
    log "INFO: PR Review Daemon started via 'start' command (pid=${daemon_pid})"
}

cmd_stop() {
    if ! is_running; then
        echo "PR Review Daemon is not running"
        return 0
    fi

    local pid
    pid=$(cat "$PID_FILE")
    echo "Stopping PR Review Daemon (pid=${pid})..."
    kill "$pid" 2>/dev/null || true

    # 停止を待つ（最大10秒）
    local wait=0
    while [ $wait -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
        sleep 1
        wait=$((wait + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        echo "Force killing daemon..."
        kill -9 "$pid" 2>/dev/null || true
    fi

    remove_pid
    echo "PR Review Daemon stopped"
}

cmd_restart() {
    cmd_stop
    sleep 1
    cmd_start
}

cmd_status() {
    if is_running; then
        local pid
        pid=$(cat "$PID_FILE")
        echo "PR Review Daemon is running (pid=${pid})"
        echo ""
        echo "Queue status:"
        echo "  ready:      $(ls "$READY_DIR"/*.yaml 2>/dev/null | wc -l) files"
        echo "  inprogress: $(ls "$INPROGRESS_DIR"/*.yaml 2>/dev/null | wc -l) files"
        echo "  done:       $(ls "$DONE_DIR"/*.yaml 2>/dev/null | wc -l) files"
        echo ""
        echo "Last 5 log entries:"
        tail -5 "$LOG_FILE" 2>/dev/null | sed 's/^/  /'
    else
        echo "PR Review Daemon is not running"
    fi
}

cmd_foreground() {
    ensure_dirs
    if is_running; then
        local pid
        pid=$(cat "$PID_FILE")
        echo "PR Review Daemon is already running (pid=${pid})"
        exit 1
    fi

    FOREGROUND=true
    echo "PR Review Daemon starting in foreground mode (Ctrl+C to stop)..."
    daemon_loop
}

# ═══════════════════════════════════════════════════════════════════════════════
# エントリポイント
# ═══════════════════════════════════════════════════════════════════════════════
case "${1:-}" in
    start)
        cmd_start
        ;;
    stop)
        cmd_stop
        ;;
    restart)
        cmd_restart
        ;;
    status)
        cmd_status
        ;;
    --foreground)
        cmd_foreground
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|--foreground}"
        echo ""
        echo "Commands:"
        echo "  start        Start daemon in background"
        echo "  stop         Stop running daemon"
        echo "  restart      Stop and start daemon"
        echo "  status       Show daemon status and queue info"
        echo "  --foreground Run in foreground (for debugging)"
        exit 1
        ;;
esac

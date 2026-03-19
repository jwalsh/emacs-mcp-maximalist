#!/usr/bin/env bash
# emcp-daemon.sh — Daemon lifecycle management for emcp-stdio.el
# Usage: bin/emcp-daemon.sh {start|stop|restart|status|health|pid} [--json]
#
# Addresses daemon churn under concurrent agent load (see docs/data-layer/system-monitor.md):
# 3 different PIDs in ~2 minutes, decreasing uptime per restart.
#
# This script provides coordinated lifecycle management with timing instrumentation,
# a lockfile to prevent concurrent restarts, and JSON output for programmatic consumption.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration
DAEMON_NAME="server"                          # Default Emacs daemon name
LOCK_FILE="/tmp/emcp-daemon.lock"             # Prevents concurrent restart races
LOCK_TIMEOUT=30                               # Seconds before lock is considered stale
SOCKET_WAIT_MAX=10                            # Max seconds to wait for socket after start
EVAL_TIMEOUT=5                                # emacsclient --timeout for health checks
JSON_OUTPUT=false                             # --json flag

# Parse --json flag from any position
ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--json" ]]; then
        JSON_OUTPUT=true
    else
        ARGS+=("$arg")
    fi
done
set -- "${ARGS[@]:-}"

# ---- Utility functions ----

now_ms() {
    # Millisecond timestamp (macOS and Linux compatible)
    if command -v gdate &>/dev/null; then
        gdate +%s%3N
    elif date +%s%N &>/dev/null 2>&1; then
        echo $(( $(date +%s%N) / 1000000 ))
    else
        echo $(( $(date +%s) * 1000 ))
    fi
}

elapsed_ms() {
    local start=$1
    local end
    end=$(now_ms)
    echo $(( end - start ))
}

json_output() {
    # Output a JSON object from key=value pairs
    # Usage: json_output key1=val1 key2=val2 ...
    local first=true
    printf '{'
    for pair in "$@"; do
        local key="${pair%%=*}"
        local val="${pair#*=}"
        if [[ "$first" == "true" ]]; then
            first=false
        else
            printf ','
        fi
        # Detect type: numbers, booleans, null stay unquoted; strings get quoted
        case "$val" in
            true|false|null)
                printf '"%s":%s' "$key" "$val"
                ;;
            ''|*[!0-9.]*)
                # String — escape embedded quotes and backslashes
                val="${val//\\/\\\\}"
                val="${val//\"/\\\"}"
                printf '"%s":"%s"' "$key" "$val"
                ;;
            *)
                printf '"%s":%s' "$key" "$val"
                ;;
        esac
    done
    printf '}\n'
}

log() {
    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo "[emcp-daemon] $*" >&2
    fi
}

# ---- Lock management (prevents concurrent restart races) ----

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_age
        lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_FILE" 2>/dev/null || stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0) ))
        if (( lock_age > LOCK_TIMEOUT )); then
            log "Stale lock (${lock_age}s old), removing"
            rm -f "$LOCK_FILE"
        else
            log "Another daemon operation in progress (lock age: ${lock_age}s)"
            if [[ "$JSON_OUTPUT" == "true" ]]; then
                json_output status=error message="lock held by another process" lock_age_s="$lock_age"
            fi
            return 1
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
    return 0
}

# ---- Socket detection ----

find_socket() {
    # Try common socket locations
    # macOS: /tmp/emacs$(id -u)/$DAEMON_NAME or /var/folders/.../emacs$(id -u)/$DAEMON_NAME
    # Linux: /run/user/$(id -u)/emacs/$DAEMON_NAME or /tmp/emacs$(id -u)/$DAEMON_NAME
    local uid
    uid=$(id -u)
    local candidates=(
        "/tmp/emacs${uid}/${DAEMON_NAME}"
        "/run/user/${uid}/emacs/${DAEMON_NAME}"
    )
    # Also check for default daemon socket (no name)
    candidates+=(
        "/tmp/emacs${uid}/server"
        "/run/user/${uid}/emacs/server"
    )
    for sock in "${candidates[@]}"; do
        if [[ -S "$sock" ]]; then
            echo "$sock"
            return 0
        fi
    done
    # Check if TCP socket is in use (emacsclient will try TCP if no socket)
    if [[ -f "${HOME}/.emacs.d/server/server" ]]; then
        echo "tcp:${HOME}/.emacs.d/server/server"
        return 0
    fi
    return 1
}

# ---- Subcommands ----

do_start() {
    log "Starting Emacs daemon..."
    local start_t
    start_t=$(now_ms)

    # Check if already running
    if emacsclient --timeout "$EVAL_TIMEOUT" --eval '(emacs-pid)' &>/dev/null; then
        local pid
        pid=$(emacsclient --eval '(emacs-pid)' 2>/dev/null | tr -d '"')
        local elapsed
        elapsed=$(elapsed_ms "$start_t")
        log "Daemon already running (PID $pid)"
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            json_output status=already_running pid="$pid" elapsed_ms="$elapsed"
        else
            echo "Daemon already running (PID $pid)"
        fi
        return 0
    fi

    acquire_lock || return 1

    # Start daemon
    emacs --daemon 2>/dev/null

    # Wait for socket to appear and eval to work
    local waited=0
    while (( waited < SOCKET_WAIT_MAX )); do
        if emacsclient --timeout 2 --eval '(emacs-pid)' &>/dev/null; then
            break
        fi
        sleep 1
        waited=$(( waited + 1 ))
    done

    local elapsed
    elapsed=$(elapsed_ms "$start_t")

    if emacsclient --timeout "$EVAL_TIMEOUT" --eval '(emacs-pid)' &>/dev/null; then
        local pid
        pid=$(emacsclient --eval '(emacs-pid)' 2>/dev/null | tr -d '"')
        log "Daemon started (PID $pid) in ${elapsed}ms"
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            json_output status=started pid="$pid" elapsed_ms="$elapsed" waited_s="$waited"
        else
            echo "Daemon started (PID $pid) in ${elapsed}ms"
        fi
        return 0
    else
        log "Daemon failed to start after ${SOCKET_WAIT_MAX}s"
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            json_output status=error message="daemon failed to start" elapsed_ms="$elapsed"
        fi
        return 1
    fi
}

do_stop() {
    log "Stopping Emacs daemon..."
    local start_t
    start_t=$(now_ms)

    # Get PID before stopping
    local pid="unknown"
    if emacsclient --timeout "$EVAL_TIMEOUT" --eval '(emacs-pid)' &>/dev/null; then
        pid=$(emacsclient --eval '(emacs-pid)' 2>/dev/null | tr -d '"')
    else
        local elapsed
        elapsed=$(elapsed_ms "$start_t")
        log "No daemon running"
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            json_output status=not_running elapsed_ms="$elapsed"
        else
            echo "No daemon running"
        fi
        return 0
    fi

    # Graceful shutdown via emacsclient
    if emacsclient --eval '(kill-emacs)' &>/dev/null; then
        # Wait for process to exit
        local waited=0
        while (( waited < 5 )); do
            if ! kill -0 "$pid" 2>/dev/null; then
                break
            fi
            sleep 1
            waited=$(( waited + 1 ))
        done
    fi

    # Fallback: SIGTERM then SIGKILL
    if kill -0 "$pid" 2>/dev/null; then
        log "Graceful shutdown failed, sending SIGTERM to $pid"
        kill "$pid" 2>/dev/null || true
        sleep 2
    fi
    if kill -0 "$pid" 2>/dev/null; then
        log "SIGTERM failed, sending SIGKILL to $pid"
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi

    local elapsed
    elapsed=$(elapsed_ms "$start_t")
    local method="graceful"
    if kill -0 "$pid" 2>/dev/null; then
        method="failed"
    fi

    log "Daemon stopped (was PID $pid) in ${elapsed}ms"
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        json_output status=stopped pid="$pid" elapsed_ms="$elapsed" method="$method"
    else
        echo "Daemon stopped (was PID $pid) in ${elapsed}ms (${method})"
    fi
}

do_restart() {
    log "Restarting Emacs daemon..."
    local start_t
    start_t=$(now_ms)

    acquire_lock || return 1

    # Stop phase
    local stop_start
    stop_start=$(now_ms)
    # Inline stop (without lock, since we already hold it)
    local old_pid="none"
    if emacsclient --timeout "$EVAL_TIMEOUT" --eval '(emacs-pid)' &>/dev/null; then
        old_pid=$(emacsclient --eval '(emacs-pid)' 2>/dev/null | tr -d '"')
        emacsclient --eval '(kill-emacs)' &>/dev/null || true
        local waited=0
        while (( waited < 5 )); do
            if ! kill -0 "$old_pid" 2>/dev/null; then break; fi
            sleep 1
            waited=$(( waited + 1 ))
        done
        if kill -0 "$old_pid" 2>/dev/null; then
            kill -9 "$old_pid" 2>/dev/null || true
            sleep 1
        fi
    fi
    local stop_elapsed
    stop_elapsed=$(elapsed_ms "$stop_start")

    # Start phase
    local start_start
    start_start=$(now_ms)
    emacs --daemon 2>/dev/null
    local waited=0
    while (( waited < SOCKET_WAIT_MAX )); do
        if emacsclient --timeout 2 --eval '(emacs-pid)' &>/dev/null; then break; fi
        sleep 1
        waited=$(( waited + 1 ))
    done
    local start_elapsed
    start_elapsed=$(elapsed_ms "$start_start")

    local total_elapsed
    total_elapsed=$(elapsed_ms "$start_t")

    if emacsclient --timeout "$EVAL_TIMEOUT" --eval '(emacs-pid)' &>/dev/null; then
        local new_pid
        new_pid=$(emacsclient --eval '(emacs-pid)' 2>/dev/null | tr -d '"')
        log "Restarted: $old_pid -> $new_pid in ${total_elapsed}ms (stop=${stop_elapsed}ms, start=${start_elapsed}ms)"
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            json_output status=restarted old_pid="$old_pid" new_pid="$new_pid" \
                total_elapsed_ms="$total_elapsed" stop_elapsed_ms="$stop_elapsed" \
                start_elapsed_ms="$start_elapsed"
        else
            echo "Restarted: $old_pid -> $new_pid in ${total_elapsed}ms (stop=${stop_elapsed}ms, start=${start_elapsed}ms)"
        fi
        return 0
    else
        log "Restart failed after ${total_elapsed}ms"
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            json_output status=error old_pid="$old_pid" total_elapsed_ms="$total_elapsed" \
                stop_elapsed_ms="$stop_elapsed" start_elapsed_ms="$start_elapsed" \
                message="restart failed"
        fi
        return 1
    fi
}

do_status() {
    local start_t
    start_t=$(now_ms)

    if ! emacsclient --timeout "$EVAL_TIMEOUT" --eval '(emacs-pid)' &>/dev/null; then
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            json_output status=not_running daemon=false
        else
            echo "Daemon not running"
        fi
        return 1
    fi

    local pid uptime_sexp buffer_count socket_path
    pid=$(emacsclient --eval '(emacs-pid)' 2>/dev/null | tr -d '"')
    uptime_sexp=$(emacsclient --eval '(format "%.1f" (float-time (time-subtract (current-time) before-init-time)))' 2>/dev/null | tr -d '"')
    buffer_count=$(emacsclient --eval '(length (buffer-list))' 2>/dev/null | tr -d '"')
    socket_path=$(find_socket 2>/dev/null || echo "unknown")

    local elapsed
    elapsed=$(elapsed_ms "$start_t")

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        json_output status=running daemon=true pid="$pid" \
            uptime_s="$uptime_sexp" buffer_count="$buffer_count" \
            socket_path="$socket_path" query_elapsed_ms="$elapsed"
    else
        echo "Daemon running"
        echo "  PID:          $pid"
        echo "  Uptime:       ${uptime_sexp}s"
        echo "  Buffers:      $buffer_count"
        echo "  Socket:       $socket_path"
        echo "  Query time:   ${elapsed}ms"
    fi
}

do_health() {
    local start_t
    start_t=$(now_ms)

    local result
    result=$(emacsclient --timeout "$EVAL_TIMEOUT" --eval '(+ 1 1)' 2>/dev/null | tr -d '"') || true

    local elapsed
    elapsed=$(elapsed_ms "$start_t")

    if [[ "$result" == "2" ]]; then
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            json_output status=healthy eval_result="$result" elapsed_ms="$elapsed"
        else
            echo "Healthy (eval returned $result in ${elapsed}ms)"
        fi
        return 0
    else
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            json_output status=unhealthy eval_result="${result:-timeout}" elapsed_ms="$elapsed"
        else
            echo "Unhealthy (eval returned '${result:-timeout}' in ${elapsed}ms)"
        fi
        return 1
    fi
}

do_pid() {
    local pid
    pid=$(emacsclient --timeout "$EVAL_TIMEOUT" --eval '(emacs-pid)' 2>/dev/null | tr -d '"') || true

    if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]]; then
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            json_output pid="$pid"
        else
            echo "$pid"
        fi
        return 0
    else
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            json_output pid=null status=not_running
        else
            echo "No daemon running" >&2
        fi
        return 1
    fi
}

# ---- Main dispatch ----

case "${1:-}" in
    start)   do_start   ;;
    stop)    do_stop    ;;
    restart) do_restart ;;
    status)  do_status  ;;
    health)  do_health  ;;
    pid)     do_pid     ;;
    *)
        cat >&2 <<'USAGE'
Usage: bin/emcp-daemon.sh {start|stop|restart|status|health|pid} [--json]

Subcommands:
  start    Start daemon, wait for socket, report timing
  stop     Graceful shutdown via emacsclient, fallback to kill
  restart  Stop + start with timing (lock-protected)
  status   JSON: pid, uptime, buffer count, socket path
  health   Quick health check: can we eval (+ 1 1)?
  pid      Just the PID

Options:
  --json   Output JSON (default: human-readable)

Lock file: /tmp/emcp-daemon.lock (prevents concurrent restart races)
USAGE
        exit 1
        ;;
esac

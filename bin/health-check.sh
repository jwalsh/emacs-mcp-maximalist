#!/usr/bin/env bash
# health-check.sh — exit 0 ok, 1 degraded, 2 broken
set -euo pipefail

STATUS=0
OUT="{}"

check() {
    local key=$1 val=$2 required=$3
    if [[ "$val" == "false" && "$required" == "hard" ]]; then
        STATUS=2
    elif [[ "$val" == "false" ]]; then
        [[ $STATUS -lt 1 ]] && STATUS=1
    fi
    OUT=$(echo "$OUT" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); d['$key']=$val; print(json.dumps(d))")
}

# Hard requirements
emacsclient --eval '(emacs-pid)' &>/dev/null \
    && check emacs_daemon true  hard \
    || check emacs_daemon false hard

python3 -c 'import mcp' &>/dev/null \
    && check mcp_module true  hard \
    || check mcp_module false hard

[[ -f emacs-functions.json ]] \
    && check manifest true  hard \
    || check manifest false hard

# Soft requirements
[[ -f .mcp.json ]] \
    && check mcp_json true  soft \
    || check mcp_json false soft

echo "$OUT"
exit $STATUS

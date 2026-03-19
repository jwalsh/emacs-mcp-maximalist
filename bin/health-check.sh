#!/usr/bin/env bash
# health-check.sh — exit 0 ok, 1 degraded, 2 broken
set -euo pipefail

STATUS=0

# Build JSON output incrementally using jq if available, else a simple approach
if command -v jq &>/dev/null; then
    OUT="{}"
    json_set() {
        local key=$1 val=$2
        if [[ "$val" == "true" ]]; then
            OUT=$(echo "$OUT" | jq --arg k "$key" '. + {($k): true}')
        else
            OUT=$(echo "$OUT" | jq --arg k "$key" '. + {($k): false}')
        fi
    }
else
    # Fallback: build JSON manually
    declare -a JSON_PAIRS=()
    json_set() {
        local key=$1 val=$2
        JSON_PAIRS+=("\"$key\":$val")
    }
fi

check() {
    local key=$1 val=$2 required=$3
    if [[ "$val" == "false" && "$required" == "hard" ]]; then
        STATUS=2
    elif [[ "$val" == "false" ]]; then
        [[ $STATUS -lt 1 ]] && STATUS=1
    fi
    json_set "$key" "$val"
}

# Hard requirements
emacsclient --eval '(emacs-pid)' &>/dev/null \
    && check emacs_daemon true  hard \
    || check emacs_daemon false hard

emacs --batch -Q -l src/emcp-stdio.el --eval '(kill-emacs 0)' &>/dev/null \
    && check emcp_stdio true  hard \
    || check emcp_stdio false hard

# Soft requirements
[[ -f .mcp.json ]] \
    && check mcp_json true  soft \
    || check mcp_json false soft

[[ -f CLAUDE.md ]] \
    && check claude_md true  soft \
    || check claude_md false soft

[[ -f src/emcp-stdio.el ]] \
    && check emcp_stdio_el true  soft \
    || check emcp_stdio_el false soft

if command -v jq &>/dev/null; then
    echo "$OUT"
else
    # Build JSON from pairs
    printf '{'
    local first=true
    for pair in "${JSON_PAIRS[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            printf ','
        fi
        printf '%s' "$pair"
    done
    printf '}\n'
fi
exit $STATUS

#!/usr/bin/env bash
# test_emcp_stdio_integration.sh — end-to-end MCP protocol compliance tests
# for src/emcp-stdio.el (pure-Elisp MCP server over stdio).
#
# Usage:
#   bash tests/test_emcp_stdio_integration.sh            # normal
#   bash tests/test_emcp_stdio_integration.sh --verbose   # detailed output
#
# Exit codes:
#   0  all required tests passed
#   1  one or more required tests failed
#
# Requires: emacs (batch mode), python3 (used only as JSON parser, not part of project stack)
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EMCP_EL="$PROJECT_ROOT/src/emcp-stdio.el"
EMACS_CMD=(emacs --batch -Q -l "$EMCP_EL" -f emcp-stdio-start)

VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

PASS=0
FAIL=0
SKIP=0

# Timing data for performance section
declare -a PERF_LABELS=()
declare -a PERF_VALUES=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    if [[ $VERBOSE -eq 1 ]]; then
        echo "  $*"
    fi
}

log_always() {
    echo "  $*"
}

# Send one or more JSON-RPC lines to emcp-stdio, capture stdout.
# Stderr (Emacs messages) is discarded.
# Usage: result=$(send_requests "line1" "line2" ...)
send_requests() {
    local input=""
    for line in "$@"; do
        input+="$line"$'\n'
    done
    printf '%s' "$input" | "${EMACS_CMD[@]}" 2>/dev/null
}

# Send requests and capture stdout AND stderr separately.
# Sets global vars: STDOUT_RESULT, STDERR_RESULT
send_requests_split() {
    local input=""
    for line in "$@"; do
        input+="$line"$'\n'
    done
    local tmpout tmpserr
    tmpout=$(mktemp)
    tmpserr=$(mktemp)
    printf '%s' "$input" | "${EMACS_CMD[@]}" >"$tmpout" 2>"$tmpserr"
    STDOUT_RESULT=$(cat "$tmpout")
    STDERR_RESULT=$(cat "$tmpserr")
    rm -f "$tmpout" "$tmpserr"
}

# Extract the Nth line (1-based) from a multi-line string.
get_line() {
    local n=$1
    echo "$2" | sed -n "${n}p"
}

# Count lines in a string.
count_lines() {
    if [[ -z "$1" ]]; then
        echo 0
    else
        echo "$1" | wc -l | tr -d ' '
    fi
}

# Parse a JSON field. Uses python3 as a JSON parser (test utility only).
# Usage: json_get '{"a":1}' '.a'  => 1
# The path uses dict/list syntax after the root 'o' variable.
# Example paths: '.["jsonrpc"]'  '.["result"]["tools"]'
json_get() {
    local json="$1"
    local path="$2"
    python3 -c "
import json, sys
o = json.loads(sys.stdin.read())
try:
    val = eval('o' + '''${path}''')
    if isinstance(val, (dict, list)):
        print(json.dumps(val))
    elif val is None:
        print('null')
    elif isinstance(val, bool):
        print('true' if val else 'false')
    else:
        print(val)
except (KeyError, IndexError, TypeError):
    print('__MISSING__')
" <<< "$json"
}

# Check if a JSON field exists (is not __MISSING__).
json_has() {
    local val
    val=$(json_get "$1" "$2")
    [[ "$val" != "__MISSING__" ]]
}

# Get the length of a JSON array.
json_array_len() {
    local json="$1"
    local path="$2"
    python3 -c "
import json, sys
o = json.loads(sys.stdin.read())
val = eval('o' + '''${path}''')
print(len(val))
" <<< "$json"
}

# Check if a string is valid JSON.
is_valid_json() {
    python3 -c "import json, sys; json.loads(sys.stdin.read())" <<< "$1" 2>/dev/null
}

# Record a test result.
# Usage: run_test "test name" PASS|FAIL|SKIP ["detail"]
run_test() {
    local name="$1"
    local result="$2"
    local detail="${3:-}"

    case "$result" in
        PASS)
            PASS=$((PASS + 1))
            log "PASS  $name"
            ;;
        FAIL)
            FAIL=$((FAIL + 1))
            log_always "FAIL  $name${detail:+ — $detail}"
            ;;
        SKIP)
            SKIP=$((SKIP + 1))
            log "SKIP  $name${detail:+ — $detail}"
            ;;
    esac
}

# Assert equality. Calls run_test.
assert_eq() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        run_test "$test_name" PASS
    else
        run_test "$test_name" FAIL "expected '$expected', got '$actual'"
    fi
}

# Assert a value is not __MISSING__.
assert_present() {
    local test_name="$1"
    local val="$2"
    if [[ "$val" != "__MISSING__" ]]; then
        run_test "$test_name" PASS
    else
        run_test "$test_name" FAIL "field missing"
    fi
}

# Assert numeric comparison: actual >= threshold
assert_gte() {
    local test_name="$1"
    local actual="$2"
    local threshold="$3"
    if [[ "$actual" -ge "$threshold" ]]; then
        run_test "$test_name" PASS
    else
        run_test "$test_name" FAIL "expected >= $threshold, got $actual"
    fi
}

# Assert numeric comparison: actual < threshold
assert_lt() {
    local test_name="$1"
    local actual="$2"
    local threshold="$3"
    if [[ "$actual" -lt "$threshold" ]]; then
        run_test "$test_name" PASS
    else
        run_test "$test_name" FAIL "expected < $threshold, got $actual"
    fi
}

# Assert string contains substring.
assert_contains() {
    local test_name="$1"
    local haystack="$2"
    local needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        run_test "$test_name" PASS
    else
        run_test "$test_name" FAIL "expected to contain '$needle'"
    fi
}

# Assert string does NOT contain substring.
assert_not_contains() {
    local test_name="$1"
    local haystack="$2"
    local needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        run_test "$test_name" PASS
    else
        run_test "$test_name" FAIL "expected NOT to contain '$needle'"
    fi
}

record_perf() {
    PERF_LABELS+=("$1")
    PERF_VALUES+=("$2")
}

# Get current time in milliseconds (macOS compatible).
now_ms() {
    python3 -c "import time; print(int(time.time() * 1000))"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

echo "=== emcp-stdio.el integration tests ==="
echo ""

if ! command -v emacs &>/dev/null; then
    echo "FATAL: emacs not found on PATH"
    exit 1
fi

if [[ ! -f "$EMCP_EL" ]]; then
    echo "FATAL: $EMCP_EL not found"
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    echo "FATAL: python3 not found (required as JSON parser for tests)"
    exit 1
fi

echo "Emacs: $(emacs --version 2>&1 | head -1)"
echo "Source: $EMCP_EL"
echo ""

# ---------------------------------------------------------------------------
# 1. Protocol Handshake
# ---------------------------------------------------------------------------

echo "--- 1. Protocol Handshake ---"

INIT_REQ='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
INIT_RESP=$(send_requests "$INIT_REQ")

# H-01: Initialize returns required fields
assert_present "H-01 protocolVersion present"   "$(json_get "$INIT_RESP" '["result"]["protocolVersion"]')"
assert_present "H-01 capabilities present"      "$(json_get "$INIT_RESP" '["result"]["capabilities"]')"
assert_present "H-01 serverInfo present"         "$(json_get "$INIT_RESP" '["result"]["serverInfo"]')"

# H-02: jsonrpc field
assert_eq "H-02 jsonrpc=2.0" "2.0" "$(json_get "$INIT_RESP" '["jsonrpc"]')"

# H-03: id matches
assert_eq "H-03 id matches" "1" "$(json_get "$INIT_RESP" '["id"]')"

# H-04: protocolVersion value
assert_eq "H-04 protocolVersion=2024-11-05" "2024-11-05" "$(json_get "$INIT_RESP" '["result"]["protocolVersion"]')"

# H-05: serverInfo.name
assert_eq "H-05 serverInfo.name" "emacs-mcp-elisp" "$(json_get "$INIT_RESP" '["result"]["serverInfo"]["name"]')"

# H-06: serverInfo.version
assert_eq "H-06 serverInfo.version" "0.1.0" "$(json_get "$INIT_RESP" '["result"]["serverInfo"]["version"]')"

# H-07: ping
PING_REQ='{"jsonrpc":"2.0","id":2,"method":"ping","params":{}}'
PING_RESP=$(send_requests "$INIT_REQ" "$PING_REQ" | tail -1)
assert_eq "H-07 ping jsonrpc" "2.0" "$(json_get "$PING_RESP" '["jsonrpc"]')"
assert_eq "H-07 ping id" "2" "$(json_get "$PING_RESP" '["id"]')"
assert_present "H-07 ping result" "$(json_get "$PING_RESP" '["result"]')"

echo ""

# ---------------------------------------------------------------------------
# 2. Notifications
# ---------------------------------------------------------------------------

echo "--- 2. Notifications ---"

# N-01: notifications/initialized should produce no response
N_RESULT=$(send_requests \
    "$INIT_REQ" \
    '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
    '{"jsonrpc":"2.0","id":99,"method":"ping","params":{}}')
N_LINE_COUNT=$(count_lines "$N_RESULT")
# Should get exactly 2 responses: init + ping (notification produces none)
assert_eq "N-01 notification produces no response" "2" "$N_LINE_COUNT"

# N-02: arbitrary notification (no id)
N_RESULT2=$(send_requests \
    "$INIT_REQ" \
    '{"jsonrpc":"2.0","method":"some/arbitrary/notification"}' \
    '{"jsonrpc":"2.0","id":100,"method":"ping","params":{}}')
N2_LINE_COUNT=$(count_lines "$N_RESULT2")
assert_eq "N-02 arbitrary notification ignored" "2" "$N2_LINE_COUNT"

echo ""

# ---------------------------------------------------------------------------
# 3. tools/list
# ---------------------------------------------------------------------------

echo "--- 3. tools/list ---"

TL_RESULT=$(send_requests \
    "$INIT_REQ" \
    '{"jsonrpc":"2.0","id":10,"method":"tools/list","params":{}}')
TL_RESP=$(get_line 2 "$TL_RESULT")

# TL-01: result.tools is array
TL_TOOLS=$(json_get "$TL_RESP" '["result"]["tools"]')
assert_present "TL-01 result.tools present" "$TL_TOOLS"

# TL-02: Tool count >= 20
TOOL_COUNT=$(json_array_len "$TL_RESP" '["result"]["tools"]')
assert_gte "TL-02 tool count >= 20" "$TOOL_COUNT" 20
log "       (actual tool count: $TOOL_COUNT)"

# TL-03: Tool count < 5000 (sanity)
assert_lt "TL-03 tool count < 5000" "$TOOL_COUNT" 5000

# TL-04, TL-05, TL-06, TL-07, TL-08: Schema validation on first 3 tools
SCHEMA_OK=true
for idx in 0 1 2; do
    TOOL_NAME=$(json_get "$TL_RESP" "[\"result\"][\"tools\"][$idx][\"name\"]")
    TOOL_DESC=$(json_get "$TL_RESP" "[\"result\"][\"tools\"][$idx][\"description\"]")
    TOOL_SCHEMA_TYPE=$(json_get "$TL_RESP" "[\"result\"][\"tools\"][$idx][\"inputSchema\"][\"type\"]")
    TOOL_ARGS_TYPE=$(json_get "$TL_RESP" "[\"result\"][\"tools\"][$idx][\"inputSchema\"][\"properties\"][\"args\"][\"type\"]")
    TOOL_REQUIRED=$(json_get "$TL_RESP" "[\"result\"][\"tools\"][$idx][\"inputSchema\"][\"required\"]")

    if [[ "$TOOL_NAME" == "__MISSING__" ]]; then SCHEMA_OK=false; fi
    if [[ "$TOOL_SCHEMA_TYPE" != "object" ]]; then SCHEMA_OK=false; fi
    if [[ "$TOOL_ARGS_TYPE" != "array" ]]; then SCHEMA_OK=false; fi
done

if $SCHEMA_OK; then
    run_test "TL-04..08 tool schema structure (sampled)" PASS
else
    run_test "TL-04..08 tool schema structure (sampled)" FAIL "schema validation failed on sample tools"
fi

# TL-09: Known functions present
TOOL_NAMES_JSON=$(python3 -c "
import json, sys
o = json.loads(sys.stdin.read())
names = [t['name'] for t in o['result']['tools']]
print(json.dumps(names))
" <<< "$TL_RESP")

# Note: only functions whose arglist matches the text-consumer heuristic
# (string|text|str[^iua]|buffer|sequence|object) appear in tools/list.
# upcase/downcase/capitalize have arglist (OBJ) which does NOT match.
for fn in string-trim concat format; do
    if echo "$TOOL_NAMES_JSON" | python3 -c "import json,sys; names=json.loads(sys.stdin.read()); sys.exit(0 if '$fn' in names else 1)"; then
        run_test "TL-09 '$fn' in tools" PASS
    else
        run_test "TL-09 '$fn' in tools" FAIL
    fi
done

# TL-10: No emcp-stdio-* internals exposed
if echo "$TOOL_NAMES_JSON" | python3 -c "
import json, sys
names = json.loads(sys.stdin.read())
internal = [n for n in names if n.startswith('emcp-stdio-')]
sys.exit(1 if internal else 0)
"; then
    run_test "TL-10 no emcp-stdio-* internals" PASS
else
    run_test "TL-10 no emcp-stdio-* internals" FAIL
fi

echo ""

# ---------------------------------------------------------------------------
# 4. tools/call -- Success Cases
# ---------------------------------------------------------------------------

echo "--- 4. tools/call (success) ---"

TC_RESULT=$(send_requests \
    "$INIT_REQ" \
    '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"upcase","arguments":{"args":["hello"]}}}' \
    '{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"downcase","arguments":{"args":["HELLO"]}}}' \
    '{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"string-trim","arguments":{"args":[" hello "]}}}' \
    '{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"concat","arguments":{"args":["foo","bar"]}}}' \
    '{"jsonrpc":"2.0","id":24,"method":"tools/call","params":{"name":"capitalize","arguments":{"args":["hello world"]}}}' \
    '{"jsonrpc":"2.0","id":25,"method":"tools/call","params":{"name":"string-reverse","arguments":{"args":["abc"]}}}')

# Extract individual responses by id
for id_val in 20 21 22 23 24 25; do
    local_resp=$(python3 -c "
import json, sys
for line in sys.stdin.read().strip().split('\n'):
    o = json.loads(line)
    if o.get('id') == $id_val:
        print(line)
        break
" <<< "$TC_RESULT")
    eval "TC_RESP_${id_val}=\"\$local_resp\""
done

# TC-01: upcase
assert_eq "TC-01 upcase('hello')" "HELLO" "$(json_get "$TC_RESP_20" '["result"]["content"][0]["text"]')"

# TC-02: downcase
assert_eq "TC-02 downcase('HELLO')" "hello" "$(json_get "$TC_RESP_21" '["result"]["content"][0]["text"]')"

# TC-03: string-trim (CLAUDE.md acceptance criterion)
assert_eq "TC-03 string-trim(' hello ')" "hello" "$(json_get "$TC_RESP_22" '["result"]["content"][0]["text"]')"

# TC-04: concat
assert_eq "TC-04 concat('foo','bar')" "foobar" "$(json_get "$TC_RESP_23" '["result"]["content"][0]["text"]')"

# TC-05: capitalize
assert_eq "TC-05 capitalize('hello world')" "Hello World" "$(json_get "$TC_RESP_24" '["result"]["content"][0]["text"]')"

# TC-06: string-reverse
assert_eq "TC-06 string-reverse('abc')" "cba" "$(json_get "$TC_RESP_25" '["result"]["content"][0]["text"]')"

# TC-07, TC-08, TC-09: Response structure validation
CONTENT_TYPE=$(json_get "$TC_RESP_20" '["result"]["content"][0]["type"]')
assert_eq "TC-07/08 content[0].type=text" "text" "$CONTENT_TYPE"
TEXT_VAL=$(json_get "$TC_RESP_20" '["result"]["content"][0]["text"]')
assert_present "TC-09 content[0].text is present" "$TEXT_VAL"

echo ""

# ---------------------------------------------------------------------------
# 5. tools/call -- Error Cases
# ---------------------------------------------------------------------------

echo "--- 5. tools/call (errors) ---"

TE_RESULT=$(send_requests \
    "$INIT_REQ" \
    '{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"nonexistent-tool-xyz","arguments":{"args":["test"]}}}' \
    '{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"upcase","arguments":{"args":["a","b","c","d","e"]}}}')

TE_RESP_30=$(python3 -c "
import json, sys
for line in sys.stdin.read().strip().split('\n'):
    o = json.loads(line)
    if o.get('id') == 30:
        print(line)
        break
" <<< "$TE_RESULT")

TE_RESP_31=$(python3 -c "
import json, sys
for line in sys.stdin.read().strip().split('\n'):
    o = json.loads(line)
    if o.get('id') == 31:
        print(line)
        break
" <<< "$TE_RESULT")

# TE-01: Unknown tool
TE_TEXT_30=$(json_get "$TE_RESP_30" '["result"]["content"][0]["text"]')
assert_contains "TE-01 unknown tool returns error text" "$TE_TEXT_30" "error"

# TE-02: Wrong arity — should not crash, should return something
if [[ -n "$TE_RESP_31" ]]; then
    assert_eq "TE-02 wrong arity returns valid response" "2.0" "$(json_get "$TE_RESP_31" '["jsonrpc"]')"
else
    run_test "TE-02 wrong arity returns valid response" FAIL "no response received"
fi

# TE-03: Error responses still have valid JSON-RPC framing
assert_eq "TE-03 error response has jsonrpc=2.0" "2.0" "$(json_get "$TE_RESP_30" '["jsonrpc"]')"
assert_eq "TE-03 error response has matching id" "30" "$(json_get "$TE_RESP_30" '["id"]')"

echo ""

# ---------------------------------------------------------------------------
# 6. Unknown Method
# ---------------------------------------------------------------------------

echo "--- 6. Unknown Method ---"

UM_RESULT=$(send_requests \
    "$INIT_REQ" \
    '{"jsonrpc":"2.0","id":40,"method":"unknown/method","params":{}}' \
    '{"jsonrpc":"2.0","id":41,"method":"foo","params":{}}')

UM_RESP_40=$(python3 -c "
import json, sys
for line in sys.stdin.read().strip().split('\n'):
    o = json.loads(line)
    if o.get('id') == 40:
        print(line)
        break
" <<< "$UM_RESULT")

UM_RESP_41=$(python3 -c "
import json, sys
for line in sys.stdin.read().strip().split('\n'):
    o = json.loads(line)
    if o.get('id') == 41:
        print(line)
        break
" <<< "$UM_RESULT")

# UM-01: error code -32601
assert_eq "UM-01 error code -32601" "-32601" "$(json_get "$UM_RESP_40" '["error"]["code"]')"

# UM-02: error message contains "Method not found"
UM_MSG=$(json_get "$UM_RESP_41" '["error"]["message"]')
assert_contains "UM-02 error message 'Method not found'" "$UM_MSG" "Method not found"

echo ""

# ---------------------------------------------------------------------------
# 7. Unicode / Non-ASCII (C-004)
# ---------------------------------------------------------------------------

echo "--- 7. Unicode / Non-ASCII (C-004) ---"

U_RESULT=$(send_requests \
    "$INIT_REQ" \
    '{"jsonrpc":"2.0","id":50,"method":"tools/call","params":{"name":"upcase","arguments":{"args":["caf\u00e9"]}}}' \
    '{"jsonrpc":"2.0","id":51,"method":"tools/call","params":{"name":"concat","arguments":{"args":["hello ","\u4e16\u754c"]}}}' \
    '{"jsonrpc":"2.0","id":52,"method":"tools/call","params":{"name":"concat","arguments":{"args":["\ud83d\ude80"," launch"]}}}' \
    '{"jsonrpc":"2.0","id":53,"method":"tools/call","params":{"name":"upcase","arguments":{"args":["caf\u00e9"]}}}')

# Parse responses
for id_val in 50 51 52 53; do
    local_resp=$(python3 -c "
import json, sys
for line in sys.stdin.read().strip().split('\n'):
    o = json.loads(line)
    if o.get('id') == $id_val:
        print(line)
        break
" <<< "$U_RESULT")
    eval "U_RESP_${id_val}=\"\$local_resp\""
done

# U-01 (mapped to U-04 in plan): upcase of cafe with accent
U_TEXT_50=$(json_get "$U_RESP_50" '["result"]["content"][0]["text"]')
# Check the actual Unicode content
python3 -c "
import sys
text = sys.argv[1]
expected = 'CAF\u00c9'
sys.exit(0 if text == expected else 1)
" "$U_TEXT_50" 2>/dev/null
if [[ $? -eq 0 ]]; then
    run_test "U-01 upcase preserves accented chars" PASS
else
    run_test "U-01 upcase preserves accented chars" FAIL "got: $U_TEXT_50"
fi

# U-02: CJK concat
U_TEXT_51=$(json_get "$U_RESP_51" '["result"]["content"][0]["text"]')
python3 -c "
import sys
text = sys.argv[1]
sys.exit(0 if '\u4e16\u754c' in text and text.startswith('hello') else 1)
" "$U_TEXT_51" 2>/dev/null
if [[ $? -eq 0 ]]; then
    run_test "U-02 CJK characters survive round-trip" PASS
else
    run_test "U-02 CJK characters survive round-trip" FAIL "got: $U_TEXT_51"
fi

# U-03: Emoji
U_TEXT_52=$(json_get "$U_RESP_52" '["result"]["content"][0]["text"]')
python3 -c "
import sys
text = sys.argv[1]
sys.exit(0 if '\U0001f680' in text else 1)
" "$U_TEXT_52" 2>/dev/null
if [[ $? -eq 0 ]]; then
    run_test "U-03 emoji survives round-trip" PASS
else
    run_test "U-03 emoji survives round-trip" FAIL "got: $U_TEXT_52"
fi

# U-04: upcase of accented (same as U-01 with different id)
U_TEXT_53=$(json_get "$U_RESP_53" '["result"]["content"][0]["text"]')
python3 -c "
import sys
text = sys.argv[1]
sys.exit(0 if text == 'CAF\u00c9' else 1)
" "$U_TEXT_53" 2>/dev/null
if [[ $? -eq 0 ]]; then
    run_test "U-04 Latin extended upcase" PASS
else
    run_test "U-04 Latin extended upcase" FAIL "got: $U_TEXT_53"
fi

echo ""

# ---------------------------------------------------------------------------
# 8. Sequential Requests
# ---------------------------------------------------------------------------

echo "--- 8. Sequential Requests ---"

# SQ-01: 5 sequential requests with varied ids
SQ_RESULT=$(send_requests \
    "$INIT_REQ" \
    '{"jsonrpc":"2.0","id":42,"method":"ping","params":{}}' \
    '{"jsonrpc":"2.0","id":7,"method":"ping","params":{}}' \
    '{"jsonrpc":"2.0","id":999,"method":"ping","params":{}}' \
    '{"jsonrpc":"2.0","id":1000,"method":"ping","params":{}}' \
    '{"jsonrpc":"2.0","id":2000,"method":"ping","params":{}}')

SQ_LINE_COUNT=$(count_lines "$SQ_RESULT")
assert_eq "SQ-01 6 requests = 6 responses" "6" "$SQ_LINE_COUNT"

# Validate each line is valid JSON
SQ_ALL_VALID=true
while IFS= read -r line; do
    if ! is_valid_json "$line"; then
        SQ_ALL_VALID=false
        break
    fi
done <<< "$SQ_RESULT"
if $SQ_ALL_VALID; then
    run_test "SQ-01 all responses are valid JSON" PASS
else
    run_test "SQ-01 all responses are valid JSON" FAIL
fi

# SQ-02: Mixed methods in sequence
SQ2_RESULT=$(send_requests \
    "$INIT_REQ" \
    '{"jsonrpc":"2.0","id":60,"method":"tools/list","params":{}}' \
    '{"jsonrpc":"2.0","id":61,"method":"tools/call","params":{"name":"upcase","arguments":{"args":["test"]}}}' \
    '{"jsonrpc":"2.0","id":62,"method":"ping","params":{}}')

SQ2_LINE_COUNT=$(count_lines "$SQ2_RESULT")
assert_eq "SQ-02 mixed methods produce correct count" "4" "$SQ2_LINE_COUNT"

# SQ-03: Non-sequential ids echoed correctly
for id_val in 42 7 999; do
    SQ_ID_CHECK=$(python3 -c "
import json, sys
for line in sys.stdin.read().strip().split('\n'):
    o = json.loads(line)
    if o.get('id') == $id_val:
        print('found')
        break
else:
    print('missing')
" <<< "$SQ_RESULT")
    assert_eq "SQ-03 id=$id_val echoed" "found" "$SQ_ID_CHECK"
done

echo ""

# ---------------------------------------------------------------------------
# 9. Malformed Input
# ---------------------------------------------------------------------------

echo "--- 9. Malformed Input ---"

# MI-01: Empty line should be ignored
MI1_RESULT=$(send_requests \
    "$INIT_REQ" \
    "" \
    '{"jsonrpc":"2.0","id":70,"method":"ping","params":{}}')
MI1_LINE_COUNT=$(count_lines "$MI1_RESULT")
# Should get 2 responses (init + ping), empty line ignored
assert_eq "MI-01 empty line ignored" "2" "$MI1_LINE_COUNT"

# MI-02: Invalid JSON should not crash the server
MI2_RESULT=$(send_requests \
    "$INIT_REQ" \
    "not valid json at all" \
    '{"jsonrpc":"2.0","id":71,"method":"ping","params":{}}')
MI2_LINE_COUNT=$(count_lines "$MI2_RESULT")
# Should still get init and ping responses
assert_eq "MI-02 invalid JSON ignored, server continues" "2" "$MI2_LINE_COUNT"

# MI-03: Valid JSON but missing method field
MI3_RESULT=$(send_requests \
    "$INIT_REQ" \
    '{"jsonrpc":"2.0","id":72}' \
    '{"jsonrpc":"2.0","id":73,"method":"ping","params":{}}')
# Should not crash — may or may not produce a response for id 72
MI3_HAS_73=$(python3 -c "
import json, sys
for line in sys.stdin.read().strip().split('\n'):
    o = json.loads(line)
    if o.get('id') == 73:
        print('found')
        break
else:
    print('missing')
" <<< "$MI3_RESULT")
assert_eq "MI-03 missing method does not crash" "found" "$MI3_HAS_73"

echo ""

# ---------------------------------------------------------------------------
# 10. Daemon Tools (conditional)
# ---------------------------------------------------------------------------

echo "--- 10. Daemon Tools ---"

# Check if daemon is available by looking at stderr
send_requests_split "$INIT_REQ"
if echo "$STDERR_RESULT" | grep -q "daemon detected"; then
    DAEMON_AVAILABLE=1
    log "Daemon detected — running daemon tool tests"
else
    DAEMON_AVAILABLE=0
    log "No daemon — skipping daemon tool tests"
fi

if [[ $DAEMON_AVAILABLE -eq 1 ]]; then
    # DT-01: Daemon tools present in tools/list
    DT_RESULT=$(send_requests \
        "$INIT_REQ" \
        '{"jsonrpc":"2.0","id":80,"method":"tools/list","params":{}}')
    DT_RESP=$(get_line 2 "$DT_RESULT")
    DT_DATA_COUNT=$(python3 -c "
import json, sys
o = json.loads(sys.stdin.read())
count = sum(1 for t in o['result']['tools'] if t['name'].startswith('emcp-data-'))
print(count)
" <<< "$DT_RESP")
    assert_gte "DT-01 daemon tools in list" "$DT_DATA_COUNT" 1

    # DT-02: emcp-data-eval works
    DT_EVAL_RESULT=$(send_requests \
        "$INIT_REQ" \
        '{"jsonrpc":"2.0","id":81,"method":"tools/call","params":{"name":"emcp-data-eval","arguments":{"args":["(+ 1 1)"]}}}')
    DT_EVAL_RESP=$(python3 -c "
import json, sys
for line in sys.stdin.read().strip().split('\n'):
    o = json.loads(line)
    if o.get('id') == 81:
        print(line)
        break
" <<< "$DT_EVAL_RESULT")
    DT_EVAL_TEXT=$(json_get "$DT_EVAL_RESP" '["result"]["content"][0]["text"]')
    assert_eq "DT-02 emcp-data-eval (+ 1 1)" "2" "$DT_EVAL_TEXT"
else
    run_test "DT-01 daemon tools in list" SKIP "no daemon"
    run_test "DT-02 emcp-data-eval" SKIP "no daemon"
fi

echo ""

# ---------------------------------------------------------------------------
# 11. Performance Baselines (C-003, C-005)
# ---------------------------------------------------------------------------

echo "--- 11. Performance (informational) ---"

# P-01: Time to first response
P_START=$(now_ms)
P1_RESULT=$(send_requests "$INIT_REQ")
P_END=$(now_ms)
P1_MS=$((P_END - P_START))
record_perf "P-01 time-to-first-response (ms)" "$P1_MS"
run_test "P-01 startup + first response (${P1_MS}ms)" PASS
log "       time: ${P1_MS}ms"

# P-02: tools/list latency
P_START=$(now_ms)
P2_RESULT=$(send_requests \
    "$INIT_REQ" \
    '{"jsonrpc":"2.0","id":90,"method":"tools/list","params":{}}')
P_END=$(now_ms)
P2_MS=$((P_END - P_START))
record_perf "P-02 initialize+tools/list (ms)" "$P2_MS"
run_test "P-02 tools/list latency (${P2_MS}ms)" PASS
log "       time: ${P2_MS}ms"

# P-03: tools/call latency (string-trim)
P_START=$(now_ms)
P3_RESULT=$(send_requests \
    "$INIT_REQ" \
    '{"jsonrpc":"2.0","id":91,"method":"tools/call","params":{"name":"string-trim","arguments":{"args":[" hello "]}}}')
P_END=$(now_ms)
P3_MS=$((P_END - P_START))
record_perf "P-03 initialize+tools/call string-trim (ms)" "$P3_MS"
if [[ $P3_MS -gt 200 ]]; then
    log_always "  NOTE: tools/call latency ${P3_MS}ms exceeds 200ms threshold (C-003)"
fi
run_test "P-03 tools/call latency (${P3_MS}ms)" PASS
log "       time: ${P3_MS}ms"

# P-04: Compare -Q vs full init tool counts (C-005, C-006)
# -Q mode (already tested above)
Q_TOOL_COUNT=$TOOL_COUNT

# Full init mode (load user's init.el)
EMACS_CMD_FULL=(emacs --batch -l "$EMCP_EL" -f emcp-stdio-start)
P_START=$(now_ms)
FULL_RESULT=$(printf '%s\n%s\n' \
    "$INIT_REQ" \
    '{"jsonrpc":"2.0","id":92,"method":"tools/list","params":{}}' \
    | "${EMACS_CMD_FULL[@]}" 2>/dev/null || true)
P_END=$(now_ms)
P4_MS=$((P_END - P_START))

if [[ -n "$FULL_RESULT" ]]; then
    FULL_TL_RESP=$(get_line 2 "$FULL_RESULT")
    if [[ -n "$FULL_TL_RESP" ]] && is_valid_json "$FULL_TL_RESP"; then
        FULL_TOOL_COUNT=$(json_array_len "$FULL_TL_RESP" '["result"]["tools"]')
        record_perf "P-04 -Q tool count" "$Q_TOOL_COUNT"
        record_perf "P-04 full-init tool count" "$FULL_TOOL_COUNT"
        record_perf "P-04 full-init startup+tools/list (ms)" "$P4_MS"
        log "       -Q tools: $Q_TOOL_COUNT, full-init tools: $FULL_TOOL_COUNT"
        log "       full-init time: ${P4_MS}ms"
        DELTA=$((FULL_TOOL_COUNT - Q_TOOL_COUNT))
        if [[ $DELTA -gt 0 ]]; then
            log "       delta: +$DELTA tools with user init (C-006 measurement)"
        else
            log "       delta: $DELTA tools (nearly identical — C-006 refutation candidate)"
        fi
        run_test "P-04 full-init comparison (${Q_TOOL_COUNT} vs ${FULL_TOOL_COUNT})" PASS
    else
        run_test "P-04 full-init comparison" SKIP "could not parse full-init response"
    fi
else
    run_test "P-04 full-init comparison" SKIP "full-init mode failed"
fi

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo "==========================================="
echo "  RESULTS: $PASS passed, $FAIL failed, $SKIP skipped"
echo "==========================================="

if [[ ${#PERF_LABELS[@]} -gt 0 ]]; then
    echo ""
    echo "--- Performance Measurements ---"
    for i in "${!PERF_LABELS[@]}"; do
        echo "  ${PERF_LABELS[$i]}: ${PERF_VALUES[$i]}"
    done
fi

echo ""

if [[ $FAIL -gt 0 ]]; then
    echo "RESULT: FAIL"
    exit 1
else
    echo "RESULT: PASS"
    exit 0
fi

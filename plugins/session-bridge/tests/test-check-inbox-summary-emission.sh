#!/usr/bin/env bash
# tests/test-check-inbox-summary-emission.sh — v0.3.4 Task 2: --summary-only
# emits bare stdout text for PreCompact, not a JSON envelope.
#
# Field motivation (v0.3.3 Task 1 ledger): decompiled Claude Code v2.1.211
# investigation confirmed PreCompact's hook executor uses raw stdout as
# literal "compaction instructions" and never parses hookSpecificOutput or
# reads .systemMessage. The prior `jq -n '{continue,...,systemMessage:$msg}'`
# emission buried the summary inside a JSON envelope, so the model saw
# `{"continue":true,"suppressOutput":false,"systemMessage":"..."}` itself as
# its compaction instructions instead of the summary reaching it as context.
#
# This test locks in the fix: --summary-only now emits the summary as plain
# stdout text, with no JSON wrapping at all.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK_INBOX="$PLUGIN_DIR/scripts/check-inbox.sh"
CREATE_PROJ="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"
CONV_CREATE="$PLUGIN_DIR/scripts/conversation-create.sh"

kill_watchers() {
  local dir="$1"
  for pidfile in "$dir"/projects/*/sessions/*/watcher.pid; do
    [ -f "$pidfile" ] || continue
    local pid
    pid=$(cat "$pidfile" 2>/dev/null || true)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
}

TEST_TMPDIR=$(mktemp -d)
trap 'kill_watchers "$TEST_TMPDIR/bridge" 2>/dev/null; rm -rf "$TEST_TMPDIR"' EXIT

echo "=== test-check-inbox-summary-emission.sh ==="

BRIDGE="$TEST_TMPDIR/bridge"
PROJ_DIR="$TEST_TMPDIR/proj-a"
mkdir -p "$PROJ_DIR"
BRIDGE_DIR="$BRIDGE" bash "$CREATE_PROJ" "emission-test" > /dev/null
SID=$(BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ_DIR" bash "$JOIN" "emission-test" --name solo)
kill_watchers "$BRIDGE"
BRIDGE_DIR="$BRIDGE" bash "$CONV_CREATE" "emission-test" "$SID" "peer-x" "Emission test thread" > /dev/null

OUT_FILE="$TEST_TMPDIR/summary_output.txt"
set +e
BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ_DIR" BRIDGE_SESSION_ID="$SID" bash "$CHECK_INBOX" --summary-only > "$OUT_FILE"
EXIT_CODE=$?
set -e
OUTPUT=$(cat "$OUT_FILE")

# --- Test: summary_only_still_exits_zero ---
echo ""
echo "Test: summary_only_still_exits_zero"
assert_eq "--summary-only exits 0" "0" "$EXIT_CODE"

# --- Test: summary_only_has_no_json_envelope ---
# Checks three ways: the compact-JSON substring named in the task brief
# (weak on its own — jq's default pretty-printing puts a newline + indent
# between "{" and "continue", so this alone wouldn't catch the pretty-
# printed envelope the old code actually emitted), the field key regardless
# of formatting (catches pretty-printed JSON too), and the strongest check
# — the very first byte of stdout is not "{" at all.
echo ""
echo "Test: summary_only_has_no_json_envelope"
if grep -q '{"continue"' "$OUT_FILE"; then
  echo "  FAIL: output contains the compact JSON envelope substring '{\"continue\"'"; FAIL=$((FAIL + 1))
else
  echo "  PASS: output contains no compact JSON envelope substring"; PASS=$((PASS + 1))
fi
if grep -q '"continue"' "$OUT_FILE"; then
  echo "  FAIL: output still contains a \"continue\" JSON field (envelope present, possibly pretty-printed)"; FAIL=$((FAIL + 1))
else
  echo "  PASS: output contains no \"continue\" JSON field"; PASS=$((PASS + 1))
fi
FIRST_BYTE=$(head -c1 "$OUT_FILE")
assert_eq "first byte of stdout is not '{' (not JSON at all)" "false" "$([ "$FIRST_BYTE" = "{" ] && echo true || echo false)"

# --- Test: summary_only_starts_with_bridge_state_header ---
echo ""
echo "Test: summary_only_starts_with_bridge_state_header"
case "$OUTPUT" in
  "=== CLAUDE BRIDGE STATE ==="*)
    echo "  PASS: output starts with === CLAUDE BRIDGE STATE ==="; PASS=$((PASS + 1)) ;;
  *)
    echo "  FAIL: output does not start with === CLAUDE BRIDGE STATE ==="
    echo "    actual (first 80 chars): ${OUTPUT:0:80}"
    FAIL=$((FAIL + 1)) ;;
esac

# --- Test: summary_only_contains_session_roster ---
echo ""
echo "Test: summary_only_contains_session_roster"
assert_contains "output lists the joined session (solo / $SID)" "solo ($SID)" "$OUTPUT"

# --- Test: summary_only_contains_conversation_list ---
echo ""
echo "Test: summary_only_contains_conversation_list"
assert_contains "output lists the open conversation" "Emission test thread" "$OUTPUT"

# --- Test: summary_only_ends_with_end_bridge_marker_and_trailing_newline ---
echo ""
echo "Test: summary_only_ends_with_end_bridge_marker_and_trailing_newline"
LAST_BYTE_HEX=$(tail -c1 "$OUT_FILE" | od -An -tx1 | tr -d ' \n')
assert_eq "raw stdout ends with a real trailing newline byte (0x0a)" "0a" "$LAST_BYTE_HEX"
TAIL_TEXT=$(tail -c 40 "$OUT_FILE")
assert_contains "output text ends with === END BRIDGE ===" "=== END BRIDGE ===" "$TAIL_TEXT"

print_results

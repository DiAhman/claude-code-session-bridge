#!/usr/bin/env bash
# tests/test-check-inbox.sh — Tests for scripts/check-inbox.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"
CHECK_INBOX="$PLUGIN_DIR/scripts/check-inbox.sh"

# Kill all inbox-watcher processes in a bridge directory
kill_watchers() {
  local dir="$1"
  for pidfile in "$dir"/projects/*/sessions/*/watcher.pid; do
    [ -f "$pidfile" ] || continue
    local pid
    pid=$(cat "$pidfile" 2>/dev/null || true)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
}

# Set up isolated temp dirs for testing
TEST_TMPDIR=$(mktemp -d)
trap 'kill_watchers "$TEST_TMPDIR/bridge" 2>/dev/null; rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_A="$TEST_TMPDIR/project-a"
PROJECT_B="$TEST_TMPDIR/project-b"
mkdir -p "$PROJECT_A" "$PROJECT_B"

# Register two sessions (legacy)
SENDER_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$REGISTER")
TARGET_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$REGISTER")

echo "=== test-check-inbox.sh ==="
echo "  sender=$SENDER_ID  target=$TARGET_ID"

# --- Test 1: Empty inbox returns continue true with no systemMessage ---
echo ""
echo "Test 1: Empty inbox returns continue true with no systemMessage"
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" BRIDGE_SESSION_ID="$TARGET_ID" bash "$CHECK_INBOX")
CONTINUE=$(echo "$OUTPUT" | jq -r '.continue')
HAS_SYSTEM_MSG=$(echo "$OUTPUT" | jq 'has("systemMessage")')
assert_eq "continue is true" "true" "$CONTINUE"
assert_eq "no systemMessage key" "false" "$HAS_SYSTEM_MSG"

# --- Test 2: One pending query returns systemMessage with expected content ---
echo ""
echo "Test 2: One pending query returns systemMessage with CLAUDE BRIDGE header, peer name, content, instruction"
MSG_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" bash "$SEND_MSG" "$TARGET_ID" "query" "What APIs do you expose?")

OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" BRIDGE_SESSION_ID="$TARGET_ID" bash "$CHECK_INBOX")
CONTINUE=$(echo "$OUTPUT" | jq -r '.continue')
SYSTEM_MSG=$(echo "$OUTPUT" | jq -r '.systemMessage')

assert_eq "continue is true" "true" "$CONTINUE"
assert_contains "has CLAUDE BRIDGE header" "CLAUDE BRIDGE" "$SYSTEM_MSG"
assert_contains "has peer project name" "project-a" "$SYSTEM_MSG"
assert_contains "has message content" "What APIs do you expose?" "$SYSTEM_MSG"
assert_contains "has send-message instruction" "send-message.sh" "$SYSTEM_MSG"

# --- Test 3: Message deleted from inbox after check ---
echo ""
echo "Test 3: Message deleted from inbox after check"
MSG_FILE="$BRIDGE_DIR/sessions/$TARGET_ID/inbox/$MSG_ID.json"
if [ -f "$MSG_FILE" ]; then
  echo "  FAIL: message still exists in inbox"; FAIL=$((FAIL + 1))
else
  echo "  PASS: message deleted after read"; PASS=$((PASS + 1))
fi

# --- Test 4: Heartbeat updated ---
echo ""
echo "Test 4: Heartbeat updated after check-inbox"
# Set heartbeat to an old value
MANIFEST="$BRIDGE_DIR/sessions/$TARGET_ID/manifest.json"
OLD_HB="2020-01-01T00:00:00Z"
TMP=$(mktemp "$BRIDGE_DIR/sessions/$TARGET_ID/manifest.XXXXXX")
jq --arg hb "$OLD_HB" '.lastHeartbeat = $hb' "$MANIFEST" > "$TMP"
mv "$TMP" "$MANIFEST"

# Verify old value is set
CURRENT_HB=$(jq -r '.lastHeartbeat' "$MANIFEST")
assert_eq "heartbeat set to old value" "$OLD_HB" "$CURRENT_HB"

# Run check-inbox (no pending messages, so output is just continue:true)
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" BRIDGE_SESSION_ID="$TARGET_ID" bash "$CHECK_INBOX")

# check-inbox.sh does NOT update heartbeat (it scans all sessions globally)
# Verify heartbeat is unchanged
UPDATED_HB=$(jq -r '.lastHeartbeat' "$MANIFEST")
if [ "$UPDATED_HB" = "$OLD_HB" ]; then
  echo "  PASS: heartbeat correctly left unchanged by check-inbox"; PASS=$((PASS + 1))
else
  echo "  FAIL: heartbeat was modified (should be unchanged)"; FAIL=$((FAIL + 1))
fi

# --- Test 5: --summary-only mode ---
echo ""
echo "Test 5: --summary-only mode contains session ID, send-message instruction, peer name"
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" BRIDGE_SESSION_ID="$TARGET_ID" bash "$CHECK_INBOX" --summary-only)
SYSTEM_MSG=$(echo "$OUTPUT" | jq -r '.systemMessage')

assert_contains "summary has session ID" "$TARGET_ID" "$SYSTEM_MSG"
assert_contains "summary has send-message instruction" "send-message.sh" "$SYSTEM_MSG"
assert_contains "summary has peer project name" "project-a" "$SYSTEM_MSG"

# --- Test 6: check-inbox does not clean up stale sessions ---
echo ""
echo "Test 6: check-inbox leaves stale sessions alone"
STALE_ID="stale1"
STALE_DIR="$BRIDGE_DIR/sessions/$STALE_ID"
mkdir -p "$STALE_DIR/inbox" "$STALE_DIR/outbox"
cat > "$STALE_DIR/manifest.json" <<EOF
{
  "sessionId": "$STALE_ID",
  "projectName": "stale-project",
  "projectPath": "/tmp/stale",
  "startedAt": "2020-01-01T00:00:00Z",
  "lastHeartbeat": "2020-01-01T00:00:00Z",
  "status": "active",
  "capabilities": ["query"]
}
EOF

# Run check-inbox
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" BRIDGE_SESSION_ID="$TARGET_ID" bash "$CHECK_INBOX")

# Stale session should still exist (check-inbox doesn't clean up)
if [ -d "$STALE_DIR" ]; then
  echo "  PASS: stale session correctly left alone by check-inbox"; PASS=$((PASS + 1))
else
  echo "  FAIL: stale session was unexpectedly removed"; FAIL=$((FAIL + 1))
fi

# =============================================================================
echo ""
echo "--- v2 check-inbox tests ---"

# Test R1: Early exit for non-bridge session (no BRIDGE_SESSION_ID, no bridge-session file)
echo ""
echo "Test R1: Non-bridge session exits immediately with continue:true"
NON_BRIDGE_DIR=$(mktemp -d)
OUTPUT=$(BRIDGE_DIR="$NON_BRIDGE_DIR" PROJECT_DIR="$NON_BRIDGE_DIR" bash "$CHECK_INBOX" --rate-limited 2>/dev/null)
assert_contains "non-bridge exits cleanly" '"continue": true' "$OUTPUT"
# Also test without --rate-limited
OUTPUT=$(BRIDGE_DIR="$NON_BRIDGE_DIR" PROJECT_DIR="$NON_BRIDGE_DIR" bash "$CHECK_INBOX" 2>/dev/null)
assert_contains "non-bridge exits cleanly (no flag)" '"continue": true' "$OUTPUT"
rm -rf "$NON_BRIDGE_DIR"

# Test R2: --rate-limited respects timestamp (project-scoped)
echo ""
echo "Test R2: Rate limiting with 5-second window"
V2_TMPDIR=$(mktemp -d)
V2_BRIDGE="$V2_TMPDIR/bridge"
V2_PROJ="$V2_TMPDIR/myproj"
mkdir -p "$V2_PROJ"
BRIDGE_DIR="$V2_BRIDGE" bash "$PLUGIN_DIR/scripts/project-create.sh" "rate-test" > /dev/null
V2_SID=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ" bash "$PLUGIN_DIR/scripts/project-join.sh" "rate-test")
kill_watchers "$V2_BRIDGE"

# First call should proceed (no timestamp file yet)
OUTPUT=$(BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SID" PROJECT_DIR="$V2_PROJ" bash "$CHECK_INBOX" --rate-limited 2>/dev/null)
assert_contains "first rate-limited call succeeds" '"continue": true' "$OUTPUT"

# Verify timestamp file was created
if ls "$V2_BRIDGE/.last_inbox_check_"* >/dev/null 2>&1; then
  echo "  PASS: timestamp file created"; PASS=$((PASS + 1))
else
  echo "  FAIL: timestamp file not created"; FAIL=$((FAIL + 1))
fi

# Immediate second call should be rate-limited (< 5 seconds)
OUTPUT=$(BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SID" PROJECT_DIR="$V2_PROJ" bash "$CHECK_INBOX" --rate-limited 2>/dev/null)
assert_contains "rate-limited exits early" '"continue": true' "$OUTPUT"
# Should NOT have systemMessage since it was rate-limited
HAS_MSG=$(echo "$OUTPUT" | jq 'has("systemMessage")')
assert_eq "rate-limited has no systemMessage" "false" "$HAS_MSG"

rm -rf "$V2_TMPDIR"

# Test R3: Critical message bypasses rate limit
echo ""
echo "Test R3: Critical urgency message bypasses rate limit"
V2_TMPDIR=$(mktemp -d)
V2_BRIDGE="$V2_TMPDIR/bridge"
V2_PROJ_A="$V2_TMPDIR/proj-a"
V2_PROJ_B="$V2_TMPDIR/proj-b"
mkdir -p "$V2_PROJ_A" "$V2_PROJ_B"
BRIDGE_DIR="$V2_BRIDGE" bash "$PLUGIN_DIR/scripts/project-create.sh" "crit-test" > /dev/null
V2_SID_A=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_A" bash "$PLUGIN_DIR/scripts/project-join.sh" "crit-test")
V2_SID_B=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_B" bash "$PLUGIN_DIR/scripts/project-join.sh" "crit-test")
kill_watchers "$V2_BRIDGE"

# First call to set the timestamp
OUTPUT=$(BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SID_B" PROJECT_DIR="$V2_PROJ_B" bash "$CHECK_INBOX" --rate-limited 2>/dev/null)

# Send a critical message from A to B
BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SID_A" bash "$SEND_MSG" "$V2_SID_B" "query" "URGENT: system is down" --urgency critical > /dev/null

# Second call should bypass rate limit because of critical message
OUTPUT=$(BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SID_B" PROJECT_DIR="$V2_PROJ_B" bash "$CHECK_INBOX" --rate-limited 2>/dev/null)
HAS_MSG=$(echo "$OUTPUT" | jq 'has("systemMessage")')
assert_eq "critical message bypasses rate limit" "true" "$HAS_MSG"
SYSTEM_MSG=$(echo "$OUTPUT" | jq -r '.systemMessage')
assert_contains "critical message content present" "URGENT: system is down" "$SYSTEM_MSG"

rm -rf "$V2_TMPDIR"

# Test R4: Project-scoped session only scans its own inbox
echo ""
echo "Test R4: Project-scoped session scans only its own project inbox"
V2_TMPDIR=$(mktemp -d)
V2_BRIDGE="$V2_TMPDIR/bridge"
V2_PROJ_A="$V2_TMPDIR/proj-a"
V2_PROJ_B="$V2_TMPDIR/proj-b"
mkdir -p "$V2_PROJ_A" "$V2_PROJ_B"
BRIDGE_DIR="$V2_BRIDGE" bash "$PLUGIN_DIR/scripts/project-create.sh" "scope-test" > /dev/null
V2_SID_A=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_A" bash "$PLUGIN_DIR/scripts/project-join.sh" "scope-test")
V2_SID_B=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_B" bash "$PLUGIN_DIR/scripts/project-join.sh" "scope-test")
kill_watchers "$V2_BRIDGE"

# Send a message from A to B
BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SID_A" bash "$SEND_MSG" "$V2_SID_B" "query" "Hello from A" > /dev/null

# B checks inbox — should find message
OUTPUT=$(BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SID_B" PROJECT_DIR="$V2_PROJ_B" bash "$CHECK_INBOX")
SYSTEM_MSG=$(echo "$OUTPUT" | jq -r '.systemMessage')
assert_contains "project-scoped finds message" "Hello from A" "$SYSTEM_MSG"

# A checks inbox — should NOT find the message (it's in B's inbox)
OUTPUT=$(BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SID_A" PROJECT_DIR="$V2_PROJ_A" bash "$CHECK_INBOX")
HAS_MSG=$(echo "$OUTPUT" | jq 'has("systemMessage")')
assert_eq "sender does not see own message in inbox" "false" "$HAS_MSG"

rm -rf "$V2_TMPDIR"

# Test R5: Project-scoped --summary-only includes project context
echo ""
echo "Test R5: Project-scoped summary includes project name and role"
V2_TMPDIR=$(mktemp -d)
V2_BRIDGE="$V2_TMPDIR/bridge"
V2_PROJ="$V2_TMPDIR/myproj"
mkdir -p "$V2_PROJ"
BRIDGE_DIR="$V2_BRIDGE" bash "$PLUGIN_DIR/scripts/project-create.sh" "summary-test" > /dev/null
V2_SID=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ" bash "$PLUGIN_DIR/scripts/project-join.sh" "summary-test" --role orchestrator --specialty "coordination")
kill_watchers "$V2_BRIDGE"

OUTPUT=$(BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SID" PROJECT_DIR="$V2_PROJ" bash "$CHECK_INBOX" --summary-only)
SYSTEM_MSG=$(echo "$OUTPUT" | jq -r '.systemMessage')
assert_contains "summary has project name" "summary-test" "$SYSTEM_MSG"
assert_contains "summary has session id" "$V2_SID" "$SYSTEM_MSG"
assert_contains "summary has role" "orchestrator" "$SYSTEM_MSG"

rm -rf "$V2_TMPDIR"

# Test R6: --rate-limited without flag does full scan
echo ""
echo "Test R6: Without --rate-limited flag, no rate limiting applied"
V2_TMPDIR=$(mktemp -d)
V2_BRIDGE="$V2_TMPDIR/bridge"
V2_PROJ_A="$V2_TMPDIR/proj-a"
V2_PROJ_B="$V2_TMPDIR/proj-b"
mkdir -p "$V2_PROJ_A" "$V2_PROJ_B"
BRIDGE_DIR="$V2_BRIDGE" bash "$PLUGIN_DIR/scripts/project-create.sh" "norate-test" > /dev/null
V2_SID_A=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_A" bash "$PLUGIN_DIR/scripts/project-join.sh" "norate-test")
V2_SID_B=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_B" bash "$PLUGIN_DIR/scripts/project-join.sh" "norate-test")
kill_watchers "$V2_BRIDGE"

# Set timestamp to simulate recent check
mkdir -p "$V2_BRIDGE"
date +%s > "$V2_BRIDGE/.last_inbox_check_${V2_SID_B}"

# Send a message from A to B
BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SID_A" bash "$SEND_MSG" "$V2_SID_B" "query" "No rate limit test" > /dev/null

# Without --rate-limited, should still find the message regardless of timestamp
OUTPUT=$(BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SID_B" PROJECT_DIR="$V2_PROJ_B" bash "$CHECK_INBOX")
SYSTEM_MSG=$(echo "$OUTPUT" | jq -r '.systemMessage')
assert_contains "no-rate-limit finds message" "No rate limit test" "$SYSTEM_MSG"

rm -rf "$V2_TMPDIR"

# Test R7: Project-scoped message includes conversation ID in output
echo ""
echo "Test R7: Project-scoped message output includes conversation ID"
V2_TMPDIR=$(mktemp -d)
V2_BRIDGE="$V2_TMPDIR/bridge"
V2_PROJ_A="$V2_TMPDIR/proj-a"
V2_PROJ_B="$V2_TMPDIR/proj-b"
mkdir -p "$V2_PROJ_A" "$V2_PROJ_B"
BRIDGE_DIR="$V2_BRIDGE" bash "$PLUGIN_DIR/scripts/project-create.sh" "conv-test" > /dev/null
V2_SID_A=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_A" bash "$PLUGIN_DIR/scripts/project-join.sh" "conv-test")
V2_SID_B=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_B" bash "$PLUGIN_DIR/scripts/project-join.sh" "conv-test")
kill_watchers "$V2_BRIDGE"

# Send query (auto-creates conversation)
BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SID_A" bash "$SEND_MSG" "$V2_SID_B" "query" "Conversation test" > /dev/null

OUTPUT=$(BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SID_B" PROJECT_DIR="$V2_PROJ_B" bash "$CHECK_INBOX")
SYSTEM_MSG=$(echo "$OUTPUT" | jq -r '.systemMessage')
assert_contains "output has Conversation field" "Conversation: conv-" "$SYSTEM_MSG"
assert_contains "output has conversation flag in reply instruction" "conversation" "$SYSTEM_MSG"

rm -rf "$V2_TMPDIR"

# ===================================================================
# Stop hook tests (--stop-hook flag)
# ===================================================================
echo ""
echo "--- Stop hook tests ---"

# Fresh isolated environment for stop hook tests
SH_TMPDIR=$(mktemp -d)
SH_BRIDGE="$SH_TMPDIR/bridge"
SH_PROJ_A="$SH_TMPDIR/proj-a"
SH_PROJ_B="$SH_TMPDIR/proj-b"
mkdir -p "$SH_PROJ_A" "$SH_PROJ_B"

CREATE_PROJ="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"

BRIDGE_DIR="$SH_BRIDGE" bash "$CREATE_PROJ" "stop-test" >/dev/null
SH_SID_A=$(BRIDGE_DIR="$SH_BRIDGE" PROJECT_DIR="$SH_PROJ_A" bash "$JOIN" "stop-test" --name "sender")
SH_SID_B=$(BRIDGE_DIR="$SH_BRIDGE" PROJECT_DIR="$SH_PROJ_B" bash "$JOIN" "stop-test" --name "receiver")

# Test S1: --stop-hook with empty inbox exits 0, no output
OUTPUT=$(BRIDGE_DIR="$SH_BRIDGE" BRIDGE_SESSION_ID="$SH_SID_B" bash "$CHECK_INBOX" --stop-hook 2>/dev/null || true)
assert_eq "stop-hook empty inbox: no output" "" "$OUTPUT"

# Test S2: --stop-hook with pending message returns decision block
BRIDGE_DIR="$SH_BRIDGE" BRIDGE_SESSION_ID="$SH_SID_A" bash "$SEND_MSG" "$SH_SID_B" query "Hello from stop test" >/dev/null
OUTPUT=$(BRIDGE_DIR="$SH_BRIDGE" BRIDGE_SESSION_ID="$SH_SID_B" bash "$CHECK_INBOX" --stop-hook)
DECISION=$(echo "$OUTPUT" | jq -r '.decision')
HOOK_NAME=$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.hookEventName')
CONTEXT=$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.additionalContext')
assert_eq "stop-hook decision is block" "block" "$DECISION"
assert_eq "stop-hook hookEventName is Stop" "Stop" "$HOOK_NAME"
assert_contains "stop-hook context has message" "Hello from stop test" "$CONTEXT"
assert_contains "stop-hook context has BRIDGE header" "CLAUDE BRIDGE" "$CONTEXT"

# Test S3: Counter increments on block
COUNTER_FILE="$SH_BRIDGE/.stop_counter_${SH_SID_B}"
COUNTER_VAL=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
assert_eq "stop-hook counter is 1 after first block" "1" "$COUNTER_VAL"

# Test S4: Counter resets on empty inbox (no messages)
echo "5" > "$COUNTER_FILE"
OUTPUT=$(BRIDGE_DIR="$SH_BRIDGE" BRIDGE_SESSION_ID="$SH_SID_B" bash "$CHECK_INBOX" --stop-hook 2>/dev/null || true)
assert_eq "stop-hook empty inbox: no output after counter was 5" "" "$OUTPUT"
COUNTER_VAL=$(cat "$COUNTER_FILE" 2>/dev/null || echo "99")
assert_eq "stop-hook counter reset to 0 on allow" "0" "$COUNTER_VAL"

# Test S5: Counter caps at 10 — allows stop even with messages
echo "10" > "$COUNTER_FILE"
BRIDGE_DIR="$SH_BRIDGE" BRIDGE_SESSION_ID="$SH_SID_A" bash "$SEND_MSG" "$SH_SID_B" query "Should be skipped" >/dev/null
OUTPUT=$(BRIDGE_DIR="$SH_BRIDGE" BRIDGE_SESSION_ID="$SH_SID_B" bash "$CHECK_INBOX" --stop-hook 2>/dev/null || true)
assert_eq "stop-hook cap: exit 0 with no output at counter=10" "" "$OUTPUT"
COUNTER_VAL=$(cat "$COUNTER_FILE" 2>/dev/null || echo "99")
assert_eq "stop-hook cap: counter reset to 0" "0" "$COUNTER_VAL"
# Message should still be pending (not claimed)
PENDING_COUNT=$(find "$SH_BRIDGE/projects/stop-test/sessions/$SH_SID_B/inbox" -name "*.json" \
  -exec jq -r 'select(.status == "pending") | .id' {} \; 2>/dev/null | wc -l)
assert_eq "stop-hook cap: message still pending" "1" "$PENDING_COUNT"
# Clean up the pending message for subsequent tests
BRIDGE_DIR="$SH_BRIDGE" BRIDGE_SESSION_ID="$SH_SID_B" bash "$CHECK_INBOX" >/dev/null

# Test S6: Counter resets on default mode (UserPromptSubmit simulation)
echo "7" > "$COUNTER_FILE"
BRIDGE_DIR="$SH_BRIDGE" BRIDGE_SESSION_ID="$SH_SID_B" bash "$CHECK_INBOX" >/dev/null
COUNTER_VAL=$(cat "$COUNTER_FILE" 2>/dev/null || echo "99")
assert_eq "counter resets on default mode (UserPromptSubmit)" "0" "$COUNTER_VAL"

# Test S7: Non-bridge session exits 0 silently
OUTPUT=$(bash "$CHECK_INBOX" --stop-hook 2>/dev/null || true)
assert_eq "stop-hook non-bridge: no output" "" "$OUTPUT"

# Test S8: Multiple messages drained sequentially
BRIDGE_DIR="$SH_BRIDGE" BRIDGE_SESSION_ID="$SH_SID_A" bash "$SEND_MSG" "$SH_SID_B" query "Msg Alpha" >/dev/null
BRIDGE_DIR="$SH_BRIDGE" BRIDGE_SESSION_ID="$SH_SID_A" bash "$SEND_MSG" "$SH_SID_B" query "Msg Beta" >/dev/null
BRIDGE_DIR="$SH_BRIDGE" BRIDGE_SESSION_ID="$SH_SID_A" bash "$SEND_MSG" "$SH_SID_B" query "Msg Gamma" >/dev/null

# First call: claims all 3 messages in one scan
OUT1=$(BRIDGE_DIR="$SH_BRIDGE" BRIDGE_SESSION_ID="$SH_SID_B" bash "$CHECK_INBOX" --stop-hook)
D1=$(echo "$OUT1" | jq -r '.decision')
REASON1=$(echo "$OUT1" | jq -r '.reason')
CTX1=$(echo "$OUT1" | jq -r '.hookSpecificOutput.additionalContext')
assert_eq "drain call 1: decision block" "block" "$D1"
assert_contains "drain call 1: reason says 3" "3 bridge" "$REASON1"
assert_contains "drain call 1: has Msg Alpha" "Msg Alpha" "$CTX1"
assert_contains "drain call 1: has Msg Beta" "Msg Beta" "$CTX1"
assert_contains "drain call 1: has Msg Gamma" "Msg Gamma" "$CTX1"

# Second call: inbox empty now, should allow stop
OUT2=$(BRIDGE_DIR="$SH_BRIDGE" BRIDGE_SESSION_ID="$SH_SID_B" bash "$CHECK_INBOX" --stop-hook 2>/dev/null || true)
assert_eq "drain call 2: no output (inbox empty)" "" "$OUT2"

rm -rf "$SH_TMPDIR"

print_results

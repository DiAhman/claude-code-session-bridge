#!/usr/bin/env bash
# tests/test-bridge-listen.sh — Tests for scripts/bridge-listen.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"
LISTEN="$PLUGIN_DIR/scripts/bridge-listen.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_A="$TEST_TMPDIR/project-a"
PROJECT_B="$TEST_TMPDIR/project-b"
mkdir -p "$PROJECT_A" "$PROJECT_B"

SESSION_A=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$REGISTER")
SESSION_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$REGISTER")

echo "=== test-bridge-listen.sh ==="
echo "  session_a=$SESSION_A  session_b=$SESSION_B"

# --- Test 1: Returns message when pending ---
echo ""
echo "Test 1: Returns message content when a pending message exists"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" query "Hello from A" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" 5)
assert_contains "has MESSAGE_ID" "MESSAGE_ID=" "$OUTPUT"
assert_contains "has FROM_ID" "FROM_ID=$SESSION_A" "$OUTPUT"
assert_contains "has TYPE=query" "TYPE=query" "$OUTPUT"
assert_contains "has message content" "Hello from A" "$OUTPUT"
if echo "$OUTPUT" | grep -qF -- "---"; then
  echo "  PASS: has separator between metadata and content"; PASS=$((PASS + 1))
else
  echo "  FAIL: missing separator"; FAIL=$((FAIL + 1))
fi

# --- Test 2: Message marked as read ---
echo ""
echo "Test 2: Message marked as read after pickup"
MSG_FILE=$(find "$BRIDGE_DIR/sessions/$SESSION_B/inbox" -name "*.json" | head -1)
assert_eq "message status is read" "read" "$(jq -r '.status' "$MSG_FILE")"

# --- Test 3: Already-read messages are not re-delivered ---
echo ""
echo "Test 3: Already-read messages are ignored"
# The message from Test 1 is now read — should not be returned again
if BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" 3 > /dev/null 2>&1; then
  echo "  FAIL: re-delivered an already-read message"; FAIL=$((FAIL + 1))
else
  echo "  PASS: already-read message not returned again"; PASS=$((PASS + 1))
fi

# --- Test 4: Times out with exit code 1 when inbox is empty ---
echo ""
echo "Test 4: Times out correctly on empty inbox"
if BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" 3 > /dev/null 2>&1; then
  echo "  FAIL: should have timed out"; FAIL=$((FAIL + 1))
else
  echo "  PASS: timed out with exit 1"; PASS=$((PASS + 1))
fi

# --- Test 5: Picks up ping messages ---
echo ""
echo "Test 5: Handles ping message type"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" ping "connected" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" 5)
assert_contains "ping type detected" "TYPE=ping" "$OUTPUT"

# --- Test 6: Scans ALL sessions — picks from any session's inbox ---
echo ""
echo "Test 6: Picks messages from any session's inbox"
PROJECT_C="$TEST_TMPDIR/project-c"
mkdir -p "$PROJECT_C"
SESSION_C=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_C" bash "$REGISTER")
# Send to C's inbox from A
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_C" query "For session C" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" 5)
assert_contains "picks message for session C" "For session C" "$OUTPUT"
assert_contains "target is C" "TO_ID=$SESSION_C" "$OUTPUT"

# --- Test 7: Metadata includes inReplyTo when set ---
echo ""
echo "Test 7: inReplyTo field is included in output when set"
ORIG_ID="msg-original-123"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" response "My reply" "$ORIG_ID" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" 5)
assert_contains "inReplyTo in output" "IN_REPLY_TO=$ORIG_ID" "$OUTPUT"

# --- Test 8: Empty IN_REPLY_TO when not set ---
echo ""
echo "Test 8: IN_REPLY_TO is empty when not a reply"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" query "New question" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" 5)
assert_contains "IN_REPLY_TO is empty" "IN_REPLY_TO=" "$OUTPUT"
if echo "$OUTPUT" | grep -q "IN_REPLY_TO=msg-"; then
  echo "  FAIL: IN_REPLY_TO should be empty for new query"; FAIL=$((FAIL + 1))
else
  echo "  PASS: IN_REPLY_TO is empty for non-reply"; PASS=$((PASS + 1))
fi

print_results

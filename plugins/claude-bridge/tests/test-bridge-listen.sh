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

# --- Test 1: Returns immediately when a pending message exists ---
echo ""
echo "Test 1: Returns message when one is pending"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" query "Hello from A" > /dev/null

OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" 5)
assert_contains "output has MESSAGE_ID" "MESSAGE_ID=" "$OUTPUT"
assert_contains "output has FROM_ID" "FROM_ID=$SESSION_A" "$OUTPUT"
assert_contains "output has TYPE=query" "TYPE=query" "$OUTPUT"
assert_contains "output has content" "Hello from A" "$OUTPUT"
if echo "$OUTPUT" | grep -qF -- "---"; then
  echo "  PASS: output has separator"; PASS=$((PASS + 1))
else
  echo "  FAIL: output missing separator"; FAIL=$((FAIL + 1))
fi

# --- Test 2: Message marked as read after listen picks it up ---
echo ""
echo "Test 2: Message marked as read"
MSG_FILE=$(find "$BRIDGE_DIR/sessions/$SESSION_B/inbox" -name "*.json" | head -1)
MSG_STATUS=$(jq -r '.status' "$MSG_FILE")
assert_eq "message status is read" "read" "$MSG_STATUS"

# --- Test 3: Times out when no messages ---
echo ""
echo "Test 3: Times out with exit 1 when no pending messages"
if BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" 3 > /dev/null 2>&1; then
  echo "  FAIL: should have timed out"; FAIL=$((FAIL + 1))
else
  echo "  PASS: timed out correctly"; PASS=$((PASS + 1))
fi

# --- Test 4: Handles multiple message types ---
echo ""
echo "Test 4: Picks up ping messages too"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" ping "connected" > /dev/null

OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" 5)
assert_contains "ping type detected" "TYPE=ping" "$OUTPUT"

print_results

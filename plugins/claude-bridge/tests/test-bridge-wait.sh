#!/usr/bin/env bash
# tests/test-bridge-wait.sh — Tests for scripts/bridge-wait.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"
WAIT="$PLUGIN_DIR/scripts/bridge-wait.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_A="$TEST_TMPDIR/project-a"
PROJECT_B="$TEST_TMPDIR/project-b"
mkdir -p "$PROJECT_A" "$PROJECT_B"

SESSION_A=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$REGISTER")
SESSION_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$REGISTER")

echo "=== test-bridge-wait.sh ==="
echo "  session_a=$SESSION_A  session_b=$SESSION_B"

# --- Test 1: Receives response matching inReplyTo ---
echo ""
echo "Test 1: Receives response matching inReplyTo"

# A sends a query to B
MSG_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" query "What version?")

# B responds to A with inReplyTo
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_B" bash "$SEND_MSG" "$SESSION_A" response "Version 2.0" "$MSG_ID" > /dev/null

# A waits for the response
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$WAIT" "$SESSION_A" "$MSG_ID" 5)
assert_contains "response has content" "Version 2.0" "$OUTPUT"
assert_contains "response has from project" "project-b" "$OUTPUT"

# --- Test 2: Message marked as read after wait picks it up ---
echo ""
echo "Test 2: Response marked as read"
RESPONSE_FILE=$(find "$BRIDGE_DIR/sessions/$SESSION_A/inbox" -name "*.json" -exec jq -r "select(.inReplyTo == \"$MSG_ID\") | input_filename" {} \; 2>/dev/null | head -1 || true)

if [ -z "$RESPONSE_FILE" ]; then
  # Alternative search
  for F in "$BRIDGE_DIR/sessions/$SESSION_A/inbox"/msg-*.json; do
    [ -f "$F" ] || continue
    IRT=$(jq -r '.inReplyTo // ""' "$F")
    if [ "$IRT" = "$MSG_ID" ]; then
      RESPONSE_FILE="$F"
      break
    fi
  done
fi

if [ -n "$RESPONSE_FILE" ] && [ -f "$RESPONSE_FILE" ]; then
  RESP_STATUS=$(jq -r '.status' "$RESPONSE_FILE")
  assert_eq "response status is read" "read" "$RESP_STATUS"
else
  echo "  FAIL: could not find response file"; FAIL=$((FAIL + 1))
fi

# --- Test 3: Times out when no matching response ---
echo ""
echo "Test 3: Times out when no matching response"
if BRIDGE_DIR="$BRIDGE_DIR" bash "$WAIT" "$SESSION_A" "nonexistent-msg-id" 3 > /dev/null 2>&1; then
  echo "  FAIL: should have timed out"; FAIL=$((FAIL + 1))
else
  echo "  PASS: timed out correctly"; PASS=$((PASS + 1))
fi

# --- Test 4: Ignores messages with wrong inReplyTo ---
echo ""
echo "Test 4: Ignores messages with wrong inReplyTo"

# Send a query
MSG_ID2=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" query "Question 2")

# Send a response with WRONG inReplyTo
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_B" bash "$SEND_MSG" "$SESSION_A" response "Wrong answer" "some-other-msg" > /dev/null

# Wait should timeout since no response matches MSG_ID2
if BRIDGE_DIR="$BRIDGE_DIR" bash "$WAIT" "$SESSION_A" "$MSG_ID2" 3 > /dev/null 2>&1; then
  echo "  FAIL: should have timed out (wrong inReplyTo)"; FAIL=$((FAIL + 1))
else
  echo "  PASS: correctly ignored wrong inReplyTo"; PASS=$((PASS + 1))
fi

print_results

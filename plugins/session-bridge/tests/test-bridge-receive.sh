#!/usr/bin/env bash
# tests/test-bridge-receive.sh — Tests for scripts/bridge-receive.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"
RECEIVE="$PLUGIN_DIR/scripts/bridge-receive.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_A="$TEST_TMPDIR/project-a"
PROJECT_B="$TEST_TMPDIR/project-b"
mkdir -p "$PROJECT_A" "$PROJECT_B"

SESSION_A=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$REGISTER")
SESSION_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$REGISTER")

echo "=== test-bridge-receive.sh ==="
echo "  session_a=$SESSION_A  session_b=$SESSION_B"

# --- Test 1: Receives response matching inReplyTo ---
echo ""
echo "Test 1: Receives response matching inReplyTo"
MSG_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" query "What version?")
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_B" bash "$SEND_MSG" "$SESSION_A" response "Version 2.0" "$MSG_ID" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$RECEIVE" "$SESSION_A" "$MSG_ID" 5)
assert_contains "response has content" "Version 2.0" "$OUTPUT"
assert_contains "response shows from project" "project-b" "$OUTPUT"

# --- Test 2: Response marked as read ---
echo ""
echo "Test 2: Response marked as read after pickup"
for F in "$BRIDGE_DIR/sessions/$SESSION_A/inbox"/msg-*.json; do
  [ -f "$F" ] || continue
  IRT=$(jq -r '.inReplyTo // ""' "$F")
  if [ "$IRT" = "$MSG_ID" ]; then
    assert_eq "response status is read" "read" "$(jq -r '.status' "$F")"
    break
  fi
done

# --- Test 3: Times out with exit code 1 ---
echo ""
echo "Test 3: Times out when no matching response arrives"
if BRIDGE_DIR="$BRIDGE_DIR" bash "$RECEIVE" "$SESSION_A" "nonexistent-msg-id" 3 > /dev/null 2>&1; then
  echo "  FAIL: should have timed out"; FAIL=$((FAIL + 1))
else
  echo "  PASS: timed out with exit 1"; PASS=$((PASS + 1))
fi

# --- Test 4: Ignores responses with wrong inReplyTo ---
echo ""
echo "Test 4: Ignores messages with non-matching inReplyTo"
MSG_ID2=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" query "Question 2")
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_B" bash "$SEND_MSG" "$SESSION_A" response "Unrelated answer" "some-other-msg" > /dev/null
if BRIDGE_DIR="$BRIDGE_DIR" bash "$RECEIVE" "$SESSION_A" "$MSG_ID2" 3 > /dev/null 2>&1; then
  echo "  FAIL: should have timed out"; FAIL=$((FAIL + 1))
else
  echo "  PASS: correctly ignored wrong inReplyTo"; PASS=$((PASS + 1))
fi

# --- Test 5: Already-read message is NOT re-delivered ---
echo ""
echo "Test 5: Already-read response is not re-delivered"
MSG_ID3=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" query "Question 3")
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_B" bash "$SEND_MSG" "$SESSION_A" response "Answer 3" "$MSG_ID3" > /dev/null

# Pick it up once
BRIDGE_DIR="$BRIDGE_DIR" bash "$RECEIVE" "$SESSION_A" "$MSG_ID3" 5 > /dev/null

# Try to receive again — should timeout (already read)
if BRIDGE_DIR="$BRIDGE_DIR" bash "$RECEIVE" "$SESSION_A" "$MSG_ID3" 3 > /dev/null 2>&1; then
  echo "  FAIL: re-delivered already-read message"; FAIL=$((FAIL + 1))
else
  echo "  PASS: already-read message not re-delivered"; PASS=$((PASS + 1))
fi

# --- Test 6: Multiple messages in inbox — picks only the matching one ---
echo ""
echo "Test 6: Multiple messages — picks only the one matching inReplyTo"
MSG_ID4=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" query "Question 4")
MSG_ID5=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" query "Question 5")

# Respond to BOTH
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_B" bash "$SEND_MSG" "$SESSION_A" response "Answer for 4" "$MSG_ID4" > /dev/null
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_B" bash "$SEND_MSG" "$SESSION_A" response "Answer for 5" "$MSG_ID5" > /dev/null

# Receive only MSG_ID5's response
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$RECEIVE" "$SESSION_A" "$MSG_ID5" 5)
assert_contains "gets correct response" "Answer for 5" "$OUTPUT"
if echo "$OUTPUT" | grep -q "Answer for 4"; then
  echo "  FAIL: got wrong message mixed in"; FAIL=$((FAIL + 1))
else
  echo "  PASS: only received the correct response"; PASS=$((PASS + 1))
fi

print_results

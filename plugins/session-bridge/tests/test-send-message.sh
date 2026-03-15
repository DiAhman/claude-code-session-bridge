#!/usr/bin/env bash
# tests/test-send-message.sh — Tests for scripts/send-message.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_A="$TEST_TMPDIR/project-a"
PROJECT_B="$TEST_TMPDIR/project-b"
mkdir -p "$PROJECT_A" "$PROJECT_B"

SENDER_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$REGISTER")
TARGET_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$REGISTER")

echo "=== test-send-message.sh ==="
echo "  sender=$SENDER_ID  target=$TARGET_ID"

# --- Test 1: Query message lands in inbox with correct fields ---
echo ""
echo "Test 1: Query message fields (from, to, type, content, status, inReplyTo, fromProject)"
MSG_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" bash "$SEND_MSG" "$TARGET_ID" "query" "What APIs do you expose?")
INBOX_FILE="$BRIDGE_DIR/sessions/$TARGET_ID/inbox/$MSG_ID.json"
OUTBOX_FILE="$BRIDGE_DIR/sessions/$SENDER_ID/outbox/$MSG_ID.json"
assert_file_exists "message in target inbox" "$INBOX_FILE"
assert_file_exists "message in sender outbox" "$OUTBOX_FILE"
MSG=$(cat "$INBOX_FILE")
assert_eq "from is sender" "$SENDER_ID" "$(echo "$MSG" | jq -r '.from')"
assert_eq "to is target" "$TARGET_ID" "$(echo "$MSG" | jq -r '.to')"
assert_eq "type is query" "query" "$(echo "$MSG" | jq -r '.type')"
assert_eq "content matches" "What APIs do you expose?" "$(echo "$MSG" | jq -r '.content')"
assert_eq "inbox status is pending" "pending" "$(echo "$MSG" | jq -r '.status')"
assert_eq "inReplyTo is null" "null" "$(echo "$MSG" | jq -r '.inReplyTo')"
assert_eq "fromProject metadata" "project-a" "$(echo "$MSG" | jq -r '.metadata.fromProject')"
assert_eq "urgency metadata" "normal" "$(echo "$MSG" | jq -r '.metadata.urgency')"

# --- Test 2: Outbox copy has status=sent, inbox has status=pending ---
echo ""
echo "Test 2: Outbox is sent, inbox is pending"
assert_eq "outbox status is sent" "sent" "$(jq -r '.status' "$OUTBOX_FILE")"
assert_eq "inbox status is pending" "pending" "$(jq -r '.status' "$INBOX_FILE")"

# --- Test 3: Response with inReplyTo ---
echo ""
echo "Test 3: Response with inReplyTo links back to original"
REPLY_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$TARGET_ID" bash "$SEND_MSG" "$SENDER_ID" "response" "Here are the APIs..." "$MSG_ID")
REPLY_FILE="$BRIDGE_DIR/sessions/$SENDER_ID/inbox/$REPLY_ID.json"
assert_file_exists "reply in sender inbox" "$REPLY_FILE"
assert_eq "reply type is response" "response" "$(jq -r '.type' "$REPLY_FILE")"
assert_eq "inReplyTo references original" "$MSG_ID" "$(jq -r '.inReplyTo' "$REPLY_FILE")"

# --- Test 4: Ping message ---
echo ""
echo "Test 4: Ping message type"
PING_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" bash "$SEND_MSG" "$TARGET_ID" "ping" "connected")
PING_FILE="$BRIDGE_DIR/sessions/$TARGET_ID/inbox/$PING_ID.json"
assert_file_exists "ping in target inbox" "$PING_FILE"
assert_eq "ping type" "ping" "$(jq -r '.type' "$PING_FILE")"

# --- Test 5: session-ended message type ---
echo ""
echo "Test 5: session-ended message type"
END_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" bash "$SEND_MSG" "$TARGET_ID" "session-ended" "goodbye")
END_FILE="$BRIDGE_DIR/sessions/$TARGET_ID/inbox/$END_ID.json"
assert_file_exists "session-ended in inbox" "$END_FILE"
assert_eq "session-ended type" "session-ended" "$(jq -r '.type' "$END_FILE")"

# --- Test 6: Each message gets a unique ID ---
echo ""
echo "Test 6: Each message gets a unique ID"
ID1=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" bash "$SEND_MSG" "$TARGET_ID" query "q1")
ID2=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" bash "$SEND_MSG" "$TARGET_ID" query "q2")
if [ "$ID1" != "$ID2" ]; then
  echo "  PASS: message IDs are unique"; PASS=$((PASS + 1))
else
  echo "  FAIL: duplicate message IDs"; FAIL=$((FAIL + 1))
fi

# --- Test 7: Content with special characters is preserved ---
echo ""
echo "Test 7: Special characters in content are preserved"
SPECIAL='auth.login() -> auth.authenticate() + "quotes" & <tags>'
SP_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" bash "$SEND_MSG" "$TARGET_ID" query "$SPECIAL")
SP_FILE="$BRIDGE_DIR/sessions/$TARGET_ID/inbox/$SP_ID.json"
assert_eq "special chars preserved" "$SPECIAL" "$(jq -r '.content' "$SP_FILE")"

# --- Test 8: Sending to non-existent session fails ---
echo ""
echo "Test 8: Sending to non-existent session fails with exit code 1"
if BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" bash "$SEND_MSG" "zzz999" query "test" > /dev/null 2>&1; then
  echo "  FAIL: should have failed for non-existent target"; FAIL=$((FAIL + 1))
else
  echo "  PASS: correctly failed for non-existent target"; PASS=$((PASS + 1))
fi

# --- Test 9: timestamp is in ISO 8601 format ---
echo ""
echo "Test 9: Message has valid ISO 8601 timestamp"
TS=$(jq -r '.timestamp' "$INBOX_FILE")
if echo "$TS" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
  echo "  PASS: timestamp is ISO 8601"; PASS=$((PASS + 1))
else
  echo "  FAIL: invalid timestamp format: $TS"; FAIL=$((FAIL + 1))
fi

print_results

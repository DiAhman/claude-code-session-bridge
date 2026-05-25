#!/usr/bin/env bash
# tests/test-send-message.sh — Tests for scripts/send-message.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"; kill $(jobs -p) 2>/dev/null || true' EXIT

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

echo ""
echo "--- v2 protocol tests ---"

# Setup project for v2 tests
V2_TMPDIR=$(mktemp -d)
V2_BRIDGE="$V2_TMPDIR/bridge"
V2_PROJ_A="$V2_TMPDIR/app-a"
V2_PROJ_B="$V2_TMPDIR/app-b"
mkdir -p "$V2_PROJ_A" "$V2_PROJ_B"

BRIDGE_DIR="$V2_BRIDGE" bash "$PLUGIN_DIR/scripts/project-create.sh" "v2-proj" > /dev/null
V2_SESS_A=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_A" bash "$PLUGIN_DIR/scripts/project-join.sh" "v2-proj" --role specialist --specialty "app")
V2_SESS_B=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_B" bash "$PLUGIN_DIR/scripts/project-join.sh" "v2-proj" --role specialist --specialty "auth")

# Test V1: Project-scoped message delivery
MSG_ID=$(BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SESS_A" bash "$SEND_MSG" "$V2_SESS_B" query "What changed?" --urgency high)
assert_not_empty "v2 message sent" "$MSG_ID"
V2_MSG_FILE="$V2_BRIDGE/projects/v2-proj/sessions/$V2_SESS_B/inbox/$MSG_ID.json"
assert_file_exists "message in project inbox" "$V2_MSG_FILE"

# Test V2: protocolVersion in message
assert_json_field "has protocolVersion" "$V2_MSG_FILE" '.protocolVersion' "2.0"

# Test V3: urgency field
assert_json_field "urgency set to high" "$V2_MSG_FILE" '.metadata.urgency' "high"

# Test V4: conversationId auto-created for query
CONV_ID=$(jq -r '.conversationId' "$V2_MSG_FILE")
assert_eq "conversationId not null" "true" "$([ "$CONV_ID" != "null" ] && echo true || echo false)"
CONV_FILE="$V2_BRIDGE/projects/v2-proj/conversations/$CONV_ID.json"
assert_file_exists "conversation file created" "$CONV_FILE"
assert_json_field "conversation status is waiting" "$CONV_FILE" '.status' "waiting"

# Test V5: response within conversation (named args only)
RESP_ID=$(BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SESS_B" bash "$SEND_MSG" "$V2_SESS_A" response "Nothing changed" --conversation "$CONV_ID" --reply-to "$MSG_ID")
assert_file_exists "response delivered" "$V2_BRIDGE/projects/v2-proj/sessions/$V2_SESS_A/inbox/$RESP_ID.json"
assert_json_field "response has conversationId" "$V2_BRIDGE/projects/v2-proj/sessions/$V2_SESS_A/inbox/$RESP_ID.json" '.conversationId' "$CONV_ID"

# Test V6: task-complete resolves conversation
COMPLETE_ID=$(BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SESS_B" bash "$SEND_MSG" "$V2_SESS_A" task-complete "All done" --conversation "$CONV_ID" --reply-to "$MSG_ID")
assert_json_field "conversation resolved" "$CONV_FILE" '.status' "resolved"

# Test V7: ping has null conversationId
PING_ID=$(BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SESS_A" bash "$SEND_MSG" "$V2_SESS_B" ping "hello")
PING_FILE="$V2_BRIDGE/projects/v2-proj/sessions/$V2_SESS_B/inbox/$PING_ID.json"
assert_json_field "ping conversationId is null" "$PING_FILE" '.conversationId' "null"

# Test V8: default urgency is normal
assert_json_field "ping default urgency" "$PING_FILE" '.metadata.urgency' "normal"

# Test V9: fromRole in metadata
assert_json_field "fromRole set" "$V2_MSG_FILE" '.metadata.fromRole' "specialist"

# Cleanup
rm -rf "$V2_TMPDIR"

echo ""
echo "--- Stale-recipient detection tests ---"

# Setup project for stale-recipient tests (fresh — avoids v2 conversation state)
S_TMPDIR=$(mktemp -d)
S_BRIDGE="$S_TMPDIR/bridge"
S_PROJ_A="$S_TMPDIR/sender-proj"
S_PROJ_B="$S_TMPDIR/target-proj"
mkdir -p "$S_PROJ_A" "$S_PROJ_B"

PROJECT_NAME="stale-proj"
BRIDGE_DIR="$S_BRIDGE" bash "$PLUGIN_DIR/scripts/project-create.sh" "$PROJECT_NAME" > /dev/null
S_SENDER_ID=$(BRIDGE_DIR="$S_BRIDGE" PROJECT_DIR="$S_PROJ_A" bash "$PLUGIN_DIR/scripts/project-join.sh" "$PROJECT_NAME" --role specialist --specialty "sender")
S_TARGET_ID=$(BRIDGE_DIR="$S_BRIDGE" PROJECT_DIR="$S_PROJ_B" bash "$PLUGIN_DIR/scripts/project-join.sh" "$PROJECT_NAME" --role specialist --specialty "target")

# Stop heartbeat daemons so we can control freshness manually
for SID in "$S_SENDER_ID" "$S_TARGET_ID"; do
  PID_FILE="$S_BRIDGE/projects/$PROJECT_NAME/sessions/$SID/heartbeat-daemon.pid"
  if [ -f "$PID_FILE" ]; then
    DPID=$(cat "$PID_FILE" 2>/dev/null || echo "")
    [ -n "$DPID" ] && kill "$DPID" 2>/dev/null || true
  fi
done

# --- Test SM-S1: send to active recipient — no stale notification ---
echo ""
echo "Test SM-S1: send to active recipient does not generate recipient-stale"
# Ensure target has a fresh heartbeat
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$S_BRIDGE/projects/$PROJECT_NAME/sessions/$S_TARGET_ID/heartbeat"
MSG_ID_S1=$(BRIDGE_DIR="$S_BRIDGE" BRIDGE_SESSION_ID="$S_SENDER_ID" \
  bash "$SEND_MSG" "$S_TARGET_ID" query "hello fresh" 2>/dev/null)
# Sender inbox should NOT have a recipient-stale notification
NOTIF_COUNT=$(find "$S_BRIDGE/projects/$PROJECT_NAME/sessions/$S_SENDER_ID/inbox" \
  -maxdepth 1 -name "*.json" -exec grep -lE '"type"[[:space:]]*:[[:space:]]*"recipient-stale"' {} \; 2>/dev/null | wc -l)
assert_eq "no recipient-stale for fresh recipient" "0" "$NOTIF_COUNT"

# --- Test SM-S2: send to stale recipient → still delivers, emits recipient-stale ---
echo ""
echo "Test SM-S2: send to stale recipient delivers + emits recipient-stale"
# Force recipient into stale-detectable state:
# Status=active, no heartbeat file, no daemon PID file
TARGET_DIR="$S_BRIDGE/projects/$PROJECT_NAME/sessions/$S_TARGET_ID"
TMP=$(mktemp "$TARGET_DIR/manifest.XXXXXX")
jq '.status = "active"' "$TARGET_DIR/manifest.json" > "$TMP" && mv "$TMP" "$TARGET_DIR/manifest.json"
rm -f "$TARGET_DIR/heartbeat" "$TARGET_DIR/heartbeat-daemon.pid"

MSG_ID_S2=$(BRIDGE_DIR="$S_BRIDGE" BRIDGE_SESSION_ID="$S_SENDER_ID" \
  bash "$SEND_MSG" "$S_TARGET_ID" query "to stale recipient" 2>/dev/null)
# Original message DID land in recipient's inbox
ORIG_IN_TARGET=$(find "$TARGET_DIR/inbox" -maxdepth 1 -name "$MSG_ID_S2.json" 2>/dev/null | wc -l)
assert_eq "original message delivered to recipient inbox" "1" "$ORIG_IN_TARGET"
# Recipient status was flipped to stale
assert_json_field "recipient flipped to stale" "$TARGET_DIR/manifest.json" ".status" "stale"
# Sender got a recipient-stale notification back
NOTIF=$(find "$S_BRIDGE/projects/$PROJECT_NAME/sessions/$S_SENDER_ID/inbox" \
  -maxdepth 1 -name "*.json" -exec grep -lE '"type"[[:space:]]*:[[:space:]]*"recipient-stale"' {} \; 2>/dev/null | head -1)
if [ -n "$NOTIF" ]; then
  echo "  PASS: sender received recipient-stale notification"; PASS=$((PASS + 1))
  assert_contains "notification mentions stale recipient id" "$S_TARGET_ID" "$(cat "$NOTIF")"
else
  echo "  FAIL: no recipient-stale notification in sender inbox"; FAIL=$((FAIL + 1))
fi

# --- Test SM-S3: recipient-stale type is accepted by validation ---
echo ""
echo "Test SM-S3: recipient-stale and session-removed pass type validation"
# Reset target to active so we can send to it
TMP=$(mktemp "$TARGET_DIR/manifest.XXXXXX")
jq '.status = "active"' "$TARGET_DIR/manifest.json" > "$TMP" && mv "$TMP" "$TARGET_DIR/manifest.json"
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$TARGET_DIR/heartbeat"
# Sending a recipient-stale message manually should not error on type validation
OUT=$(BRIDGE_DIR="$S_BRIDGE" BRIDGE_SESSION_ID="$S_SENDER_ID" \
  bash "$SEND_MSG" "$S_TARGET_ID" recipient-stale "manual test" 2>&1 || true)
if echo "$OUT" | grep -q "Unknown message type"; then
  echo "  FAIL: recipient-stale rejected by type validation"; FAIL=$((FAIL + 1))
else
  echo "  PASS: recipient-stale accepted"; PASS=$((PASS + 1))
fi
OUT=$(BRIDGE_DIR="$S_BRIDGE" BRIDGE_SESSION_ID="$S_SENDER_ID" \
  bash "$SEND_MSG" "$S_TARGET_ID" session-removed "manual test" 2>&1 || true)
if echo "$OUT" | grep -q "Unknown message type"; then
  echo "  FAIL: session-removed rejected"; FAIL=$((FAIL + 1))
else
  echo "  PASS: session-removed accepted"; PASS=$((PASS + 1))
fi

# Cleanup
rm -rf "$S_TMPDIR"

print_results

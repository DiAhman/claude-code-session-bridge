#!/usr/bin/env bash
# tests/test-cleanup.sh — Tests for scripts/cleanup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"
CLEANUP="$PLUGIN_DIR/scripts/cleanup.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_A="$TEST_TMPDIR/project-a"
PROJECT_B="$TEST_TMPDIR/project-b"
PROJECT_C="$TEST_TMPDIR/project-c"
mkdir -p "$PROJECT_A" "$PROJECT_B" "$PROJECT_C"

SESSION_A=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$REGISTER")
SESSION_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$REGISTER")
SESSION_C=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_C" bash "$REGISTER")

echo "=== test-cleanup.sh ==="
echo "  session_a=$SESSION_A  session_b=$SESSION_B  session_c=$SESSION_C"

# Have B and C send to A (so A knows both as peers)
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_B" bash "$SEND_MSG" "$SESSION_A" ping "hello" > /dev/null
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_C" bash "$SEND_MSG" "$SESSION_A" ping "hello" > /dev/null

# --- Test 1: Session dir removed ---
echo ""
echo "Test 1: Cleanup removes session directory"
SESSION_A_DIR="$BRIDGE_DIR/sessions/$SESSION_A"
assert_dir_exists "session dir exists before cleanup" "$SESSION_A_DIR"
BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$CLEANUP"
if [ ! -d "$SESSION_A_DIR" ]; then
  echo "  PASS: session dir removed"; PASS=$((PASS + 1))
else
  echo "  FAIL: session dir still exists"; FAIL=$((FAIL + 1))
fi

# --- Test 2: bridge-session pointer removed ---
echo ""
echo "Test 2: bridge-session file removed"
if [ ! -f "$PROJECT_A/.claude/bridge-session" ]; then
  echo "  PASS: bridge-session file removed"; PASS=$((PASS + 1))
else
  echo "  FAIL: bridge-session file still exists"; FAIL=$((FAIL + 1))
fi

# --- Test 3: ALL peers notified with session-ended ---
echo ""
echo "Test 3: All peers receive session-ended notification"
for SID in "$SESSION_B" "$SESSION_C"; do
  FOUND=false
  for F in "$BRIDGE_DIR/sessions/$SID/inbox"/msg-*.json; do
    [ -f "$F" ] || continue
    FTYPE=$(jq -r '.type' "$F" 2>/dev/null)
    FFROM=$(jq -r '.from' "$F" 2>/dev/null)
    if [ "$FTYPE" = "session-ended" ] && [ "$FFROM" = "$SESSION_A" ]; then
      FOUND=true
      break
    fi
  done
  if $FOUND; then
    echo "  PASS: session $SID notified"; PASS=$((PASS + 1))
  else
    echo "  FAIL: session $SID not notified"; FAIL=$((FAIL + 1))
  fi
done

# --- Test 4: Stale sessions cleaned up ---
echo ""
echo "Test 4: Stale sessions (>30 min heartbeat) cleaned up"
STALE_ID="stale99"
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
assert_dir_exists "stale session exists before cleanup" "$STALE_DIR"
PROJECT_D="$TEST_TMPDIR/project-d"
mkdir -p "$PROJECT_D"
SESSION_D=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_D" bash "$REGISTER")
BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_D" bash "$CLEANUP"
if [ ! -d "$STALE_DIR" ]; then
  echo "  PASS: stale session cleaned up"; PASS=$((PASS + 1))
else
  echo "  FAIL: stale session still exists"; FAIL=$((FAIL + 1))
fi

# --- Test 5: No-op when bridge-session file doesn't exist ---
echo ""
echo "Test 5: Cleanup is no-op when no bridge-session file"
PROJECT_E="$TEST_TMPDIR/project-e"
mkdir -p "$PROJECT_E"
# Don't register — no bridge-session file
if BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_E" bash "$CLEANUP" 2>/dev/null; then
  echo "  PASS: cleanup exits cleanly with no bridge-session"; PASS=$((PASS + 1))
else
  echo "  FAIL: cleanup errored without bridge-session"; FAIL=$((FAIL + 1))
fi

# --- Test 6: Active sessions not cleaned by stale cleanup ---
echo ""
echo "Test 6: Active sessions (fresh heartbeat) not cleaned as stale"
SESSION_B_DIR="$BRIDGE_DIR/sessions/$SESSION_B"
assert_dir_exists "session B still exists" "$SESSION_B_DIR"

# SESSION_B has fresh heartbeat, should NOT be cleaned up
# Register another session and trigger cleanup
PROJECT_F="$TEST_TMPDIR/project-f"
mkdir -p "$PROJECT_F"
SESSION_F=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_F" bash "$REGISTER")
BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_F" bash "$CLEANUP"

assert_dir_exists "active session B not cleaned" "$SESSION_B_DIR"

echo ""
echo "--- project-scoped cleanup tests ---"

# Helper to kill all watcher processes in a bridge dir
kill_watchers() {
  local bridge="$1"
  for pidfile in "$bridge"/projects/*/sessions/*/watcher.pid; do
    [ -f "$pidfile" ] || continue
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
  done
}

V2_TMPDIR=$(mktemp -d)
V2_BRIDGE="$V2_TMPDIR/bridge"
V2_PROJ_A="$V2_TMPDIR/proj-a"
V2_PROJ_B="$V2_TMPDIR/proj-b"
mkdir -p "$V2_PROJ_A" "$V2_PROJ_B"

BRIDGE_DIR="$V2_BRIDGE" bash "$PLUGIN_DIR/scripts/project-create.sh" "cleanup-proj" > /dev/null
V2_SID_A=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_A" bash "$PLUGIN_DIR/scripts/project-join.sh" "cleanup-proj")
V2_SID_B=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_B" bash "$PLUGIN_DIR/scripts/project-join.sh" "cleanup-proj")

# Send a message so they know each other
BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SID_A" bash "$PLUGIN_DIR/scripts/send-message.sh" "$V2_SID_B" ping "hello" > /dev/null

# Create an open conversation initiated by A
CONV_ID=$(BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SID_A" bash "$PLUGIN_DIR/scripts/send-message.sh" "$V2_SID_B" query "What is the status?" --urgency normal)
CONV_MSG_FILE="$V2_BRIDGE/projects/cleanup-proj/sessions/$V2_SID_B/inbox/$CONV_ID.json"
CONV_ID_FROM_MSG=""
if [ -f "$CONV_MSG_FILE" ]; then
  CONV_ID_FROM_MSG=$(jq -r '.conversationId' "$CONV_MSG_FILE")
fi

# --- Test 7: Project session dir removed ---
echo ""
echo "Test 7: Project-scoped cleanup removes session directory"
BRIDGE_CLEANUP_CONFIRMED=1 BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_A" bash "$CLEANUP"
assert_eq "project session dir removed" "false" "$([ -d "$V2_BRIDGE/projects/cleanup-proj/sessions/$V2_SID_A" ] && echo true || echo false)"

# --- Test 8: bridge-session pointer removed ---
echo ""
echo "Test 8: Project-scoped cleanup removes bridge-session pointer"
assert_eq "bridge-session pointer removed" "false" "$([ -f "$V2_PROJ_A/.claude/bridge-session" ] && echo true || echo false)"

# --- Test 9: Peer B notified via session-ended ---
echo ""
echo "Test 9: Project peer receives session-ended notification"
FOUND_ENDED=false
for F in "$V2_BRIDGE/projects/cleanup-proj/sessions/$V2_SID_B/inbox"/msg-*.json; do
  [ -f "$F" ] || continue
  if [ "$(jq -r '.type' "$F")" = "session-ended" ]; then
    FOUND_ENDED=true
    break
  fi
done
if $FOUND_ENDED; then
  echo "  PASS: peer notified via session-ended"; PASS=$((PASS + 1))
else
  echo "  FAIL: peer not notified"; FAIL=$((FAIL + 1))
fi

# --- Test 10: Open conversations initiated by A are resolved ---
echo ""
echo "Test 10: Open conversations initiated by departing session are resolved"
if [ -n "$CONV_ID_FROM_MSG" ] && [ "$CONV_ID_FROM_MSG" != "null" ]; then
  CONV_FILE="$V2_BRIDGE/projects/cleanup-proj/conversations/$CONV_ID_FROM_MSG.json"
  if [ -f "$CONV_FILE" ]; then
    CONV_STATUS=$(jq -r '.status' "$CONV_FILE")
    if [ "$CONV_STATUS" = "resolved" ]; then
      echo "  PASS: conversation resolved on cleanup"; PASS=$((PASS + 1))
    else
      echo "  FAIL: conversation status is '$CONV_STATUS', expected 'resolved'"; FAIL=$((FAIL + 1))
    fi
  else
    echo "  FAIL: conversation file not found"; FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL: no conversation ID found in message"; FAIL=$((FAIL + 1))
fi

# --- Test 11: Conversation files NOT deleted (shared project state) ---
echo ""
echo "Test 11: Conversation files preserved (shared project state)"
CONV_COUNT=$(find "$V2_BRIDGE/projects/cleanup-proj/conversations" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
if [ "$CONV_COUNT" -gt 0 ]; then
  echo "  PASS: conversation files preserved ($CONV_COUNT files)"; PASS=$((PASS + 1))
else
  echo "  FAIL: conversation files were deleted"; FAIL=$((FAIL + 1))
fi

kill_watchers "$V2_BRIDGE"
rm -rf "$V2_TMPDIR"

print_results

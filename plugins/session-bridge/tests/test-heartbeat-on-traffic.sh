#!/usr/bin/env bash
# tests/test-heartbeat-on-traffic.sh — Heartbeat is bumped on real traffic; daemon self-heals (#19).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"
LISTEN="$PLUGIN_DIR/scripts/bridge-listen.sh"

TEST_TMPDIR=$(mktemp -d)
SPAWNED_PIDS=()
cleanup() {
  for p in "${SPAWNED_PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
  done
  # Kill any heartbeat-daemon that ensure_producer_alive spawned against our temp dir
  pgrep -f "heartbeat-daemon.sh $TEST_TMPDIR" 2>/dev/null | while read -r p; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
mkdir -p "$BRIDGE_DIR"

echo "=== test-heartbeat-on-traffic.sh ==="

# --- Test 1: send-message.sh bumps SENDER heartbeat on successful delivery ---
echo ""
echo "Test 1: send-message.sh bumps sender heartbeat (project-scoped)"
SENDER_DIR=$(setup_project_session "$BRIDGE_DIR" "proj-x" "snd001" "orchestrator" "Alpha")
RECIPIENT_DIR=$(setup_project_session "$BRIDGE_DIR" "proj-x" "rcp001" "specialist" "Bravo")

# Backdate sender heartbeat by 600 seconds so we can prove it was rewritten.
STALE_TS=$(date -u -d "@$(( $(date -u +%s) - 600 ))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -r "$(( $(date -u +%s) - 600 ))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
printf '%s' "$STALE_TS" > "$SENDER_DIR/heartbeat"

BEFORE_HB=$(cat "$SENDER_DIR/heartbeat")
assert_eq "pre-send heartbeat matches backdated stamp" "$STALE_TS" "$BEFORE_HB"

BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="snd001" \
  bash "$SEND_MSG" "rcp001" ping "self-heal probe" > /dev/null

AFTER_HB=$(cat "$SENDER_DIR/heartbeat")
if [ "$AFTER_HB" != "$BEFORE_HB" ] && [ -n "$AFTER_HB" ]; then
  echo "  PASS: sender heartbeat advanced after send-message.sh"; PASS=$((PASS + 1))
else
  echo "  FAIL: sender heartbeat unchanged (before=$BEFORE_HB after=$AFTER_HB)"; FAIL=$((FAIL + 1))
fi

# --- Test 2: bridge-listen.sh bumps RECEIVER heartbeat on successful delivery ---
echo ""
echo "Test 2: bridge-listen.sh bumps receiver heartbeat after delivering a message"
# Backdate receiver heartbeat
printf '%s' "$STALE_TS" > "$RECIPIENT_DIR/heartbeat"
RBEFORE=$(cat "$RECIPIENT_DIR/heartbeat")
assert_eq "pre-listen receiver heartbeat backdated" "$STALE_TS" "$RBEFORE"

# Drop a fresh pending message directly into receiver inbox so the listener delivers it.
MSG_ID="msg-listenertest"
cat > "$RECIPIENT_DIR/inbox/${MSG_ID}.json" <<JSON
{"protocolVersion":"2.0","id":"$MSG_ID","conversationId":null,"from":"snd001","to":"rcp001","type":"ping","timestamp":"$STALE_TS","status":"pending","content":"hello","inReplyTo":null,"metadata":{"urgency":"normal","fromProject":"proj-x","fromRole":"orchestrator"}}
JSON

# BRIDGE_STANDBY_IGNORE_PENDING=1: the message dropped above is deliberately
# pre-existing in the inbox — this test is about the heartbeat bump on
# delivery, not the #27 pending-guard (covered separately).
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_STANDBY_IGNORE_PENDING=1 bash "$LISTEN" "rcp001" 5 > /dev/null

RAFTER=$(cat "$RECIPIENT_DIR/heartbeat")
if [ "$RAFTER" != "$RBEFORE" ] && [ -n "$RAFTER" ]; then
  echo "  PASS: receiver heartbeat advanced after delivery"; PASS=$((PASS + 1))
else
  echo "  FAIL: receiver heartbeat unchanged (before=$RBEFORE after=$RAFTER)"; FAIL=$((FAIL + 1))
fi

# --- Test 3: send-message.sh self-heals dead heartbeat-daemon via ensure_producer_alive ---
echo ""
echo "Test 3: send-message.sh relaunches heartbeat-daemon when pid file points to dead process"
HEAL_SND=$(setup_project_session "$BRIDGE_DIR" "proj-y" "heal01" "orchestrator" "Heal")
HEAL_RCP=$(setup_project_session "$BRIDGE_DIR" "proj-y" "heal02" "specialist" "Recv")

# pid file content from setup_project_session is literal "0" — not a live process.
PRE_PID=$(cat "$HEAL_SND/heartbeat-daemon.pid")
assert_eq "pre-send pid file is '0' (dead)" "0" "$PRE_PID"

HEARTBEAT_INTERVAL=60 BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="heal01" \
  bash "$SEND_MSG" "heal02" ping "wake the daemon" > /dev/null

POST_PID=$(cat "$HEAL_SND/heartbeat-daemon.pid")
if [ -n "$POST_PID" ] && [ "$POST_PID" != "0" ] && kill -0 "$POST_PID" 2>/dev/null; then
  echo "  PASS: heartbeat-daemon relaunched (pid=$POST_PID, alive)"; PASS=$((PASS + 1))
  SPAWNED_PIDS+=("$POST_PID")
else
  echo "  FAIL: heartbeat-daemon NOT relaunched (post_pid='$POST_PID')"; FAIL=$((FAIL + 1))
fi

# --- Test 4: a write_heartbeat failure does NOT break message delivery ---
echo ""
echo "Test 4: send-message.sh still succeeds when heartbeat write fails"
DENY_SND=$(setup_project_session "$BRIDGE_DIR" "proj-z" "deny01" "orchestrator" "Deny")
DENY_RCP=$(setup_project_session "$BRIDGE_DIR" "proj-z" "deny02" "specialist" "Drcv")

# Make heartbeat file unwritable by replacing it with a read-only directory at that path.
# write_heartbeat does mktemp + mv → the mv will fail because the destination is a dir.
# The || true guard in send-message.sh must absorb that failure.
rm -f "$DENY_SND/heartbeat"
mkdir -p "$DENY_SND/heartbeat/blocker"

SET_E_RC=0
OUT=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="deny01" \
  bash "$SEND_MSG" "deny02" ping "delivery survives hb failure" 2>&1) || SET_E_RC=$?

assert_eq "send-message.sh exit code is 0 even when heartbeat write fails" "0" "$SET_E_RC"
assert_contains "message id was still printed" "msg-" "$OUT"
INBOX_COUNT=$(find "$DENY_RCP/inbox" -maxdepth 1 -name "*.json" 2>/dev/null | wc -l)
assert_eq "recipient inbox received the message (1 file)" "1" "$INBOX_COUNT"
rm -rf "$DENY_SND/heartbeat"

print_results

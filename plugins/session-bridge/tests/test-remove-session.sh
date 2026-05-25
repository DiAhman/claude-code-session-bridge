#!/usr/bin/env bash
# tests/test-remove-session.sh — Tests for scripts/remove-session.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREATE_PROJECT="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"
REMOVE="$PLUGIN_DIR/scripts/remove-session.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_NAME="remove-test"
PROJECT_A="$TEST_TMPDIR/proj-a"
PROJECT_B="$TEST_TMPDIR/proj-b"
mkdir -p "$PROJECT_A/.claude" "$PROJECT_B/.claude"

BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$CREATE_PROJECT" "$PROJECT_NAME" >/dev/null
SID_A=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$JOIN" "$PROJECT_NAME" --role orchestrator --name "orch")
SID_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$JOIN" "$PROJECT_NAME" --role specialist --name "spec")

echo "=== test-remove-session.sh ==="
echo "  orch=$SID_A  spec=$SID_B"
sleep 1

SESSION_B_DIR="$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$SID_B"

# --- Test 1: remove destroys session dir ---
echo ""
echo "Test 1: remove-session.sh destroys session directory"
BRIDGE_DIR="$BRIDGE_DIR" bash "$REMOVE" "$SID_B"
if [ -d "$SESSION_B_DIR" ]; then
  echo "  FAIL: session dir still exists"; FAIL=$((FAIL + 1))
else
  echo "  PASS: session dir destroyed"; PASS=$((PASS + 1))
fi

# --- Test 2: orchestrator receives session-removed notification ---
echo ""
echo "Test 2: orchestrator receives session-removed notification"
ORCH_INBOX="$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$SID_A/inbox"
NOTIF=$(find "$ORCH_INBOX" -maxdepth 1 -name "*.json" -exec grep -l '"type"[[:space:]]*:[[:space:]]*"session-removed"' {} \; 2>/dev/null | head -1)
if [ -n "$NOTIF" ]; then
  echo "  PASS: orchestrator inbox has session-removed"; PASS=$((PASS + 1))
  assert_contains "notification names removed session" "$SID_B" "$(cat "$NOTIF")"
else
  echo "  FAIL: no session-removed notification in orchestrator inbox"; FAIL=$((FAIL + 1))
fi

# --- Test 3: remove on non-existent session is idempotent ---
echo ""
echo "Test 3: remove on non-existent session does not error"
if BRIDGE_DIR="$BRIDGE_DIR" bash "$REMOVE" "zzzzzz" 2>&1; then
  echo "  PASS: idempotent remove"; PASS=$((PASS + 1))
else
  echo "  FAIL: errored on non-existent session"; FAIL=$((FAIL + 1))
fi

# Kill remaining daemons
for PID_FILE in "$BRIDGE_DIR/projects/$PROJECT_NAME/sessions"/*/heartbeat-daemon.pid; do
  [ -f "$PID_FILE" ] || continue
  P=$(cat "$PID_FILE" 2>/dev/null || echo "")
  [ -n "$P" ] && kill "$P" 2>/dev/null || true
done

print_results

#!/usr/bin/env bash
# tests/test-close-session.sh — Tests for scripts/close-session.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
CREATE_PROJECT="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"
CLOSE="$PLUGIN_DIR/scripts/close-session.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_NAME="close-test"
PROJECT_A="$TEST_TMPDIR/proj-a"
mkdir -p "$PROJECT_A/.claude"

BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$CREATE_PROJECT" "$PROJECT_NAME" >/dev/null
SID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$JOIN" "$PROJECT_NAME" --role specialist --name "close-test")
sleep 2  # heartbeat daemon writes

echo "=== test-close-session.sh ==="
echo "  session=$SID"

SESSION_DIR="$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$SID"
MANIFEST="$SESSION_DIR/manifest.json"
HB_FILE="$SESSION_DIR/heartbeat"
PID_FILE="$SESSION_DIR/heartbeat-daemon.pid"

# Pre-condition checks
assert_file_exists "manifest exists pre-close" "$MANIFEST"
assert_file_exists "heartbeat file exists pre-close" "$HB_FILE"
assert_json_field "status is active pre-close" "$MANIFEST" ".status" "active"

# --- Test 1: close-session.sh flips status to offline ---
echo ""
echo "Test 1: status flips to offline"
BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$CLOSE"
assert_json_field "status flipped to offline" "$MANIFEST" ".status" "offline"

# --- Test 2: heartbeat-daemon is killed (PID file removed by daemon's own EXIT trap) ---
echo ""
echo "Test 2: heartbeat-daemon is killed"
sleep 1  # allow trap to run
if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "  FAIL: heartbeat-daemon still alive (PID $OLD_PID)"; FAIL=$((FAIL + 1))
  else
    echo "  PASS: heartbeat-daemon dead (stale PID file removed by trap)"; PASS=$((PASS + 1))
  fi
else
  echo "  PASS: heartbeat-daemon PID file removed"; PASS=$((PASS + 1))
fi

# --- Test 3: session dir is NOT destroyed (persistence-first) ---
echo ""
echo "Test 3: session directory preserved"
assert_dir_exists "session dir preserved" "$SESSION_DIR"
assert_file_exists "manifest preserved" "$MANIFEST"
assert_file_exists "heartbeat file preserved (forensic)" "$HB_FILE"
assert_dir_exists "inbox preserved" "$SESSION_DIR/inbox"
assert_dir_exists "outbox preserved" "$SESSION_DIR/outbox"

# --- Test 4: bridge-session pointer is preserved (for resume) ---
echo ""
echo "Test 4: bridge-session pointer preserved"
assert_file_exists ".claude/bridge-session preserved" "$PROJECT_A/.claude/bridge-session"
assert_file_exists ".claude/bridge-role preserved" "$PROJECT_A/.claude/bridge-role"

# --- Test 5: close on already-offline session is idempotent (no error) ---
echo ""
echo "Test 5: close on already-offline session is idempotent"
if BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$CLOSE" 2>&1; then
  echo "  PASS: idempotent close"; PASS=$((PASS + 1))
else
  echo "  FAIL: close errored on already-offline"; FAIL=$((FAIL + 1))
fi

print_results

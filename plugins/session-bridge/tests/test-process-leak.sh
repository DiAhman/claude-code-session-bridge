#!/usr/bin/env bash
# tests/test-process-leak.sh — Tests for issues #1, #2, #3
# Issue #1: bridge-listen.sh process leak (PID file self-cleaning)
# Issue #2: task-assign delivery (single listener, no competition)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREATE_PROJ="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"
LISTEN="$PLUGIN_DIR/scripts/bridge-listen.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"; pkill -f "bridge-listen.sh.*leak-test" 2>/dev/null || true; kill $(jobs -p) 2>/dev/null || true' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJ_A="$TEST_TMPDIR/proj-a"
PROJ_B="$TEST_TMPDIR/proj-b"
mkdir -p "$PROJ_A" "$PROJ_B"

BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE_PROJ" "leak-test" > /dev/null
SID_A=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_A" bash "$JOIN" "leak-test")
SID_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_B" bash "$JOIN" "leak-test")

SESSION_DIR_A="$BRIDGE_DIR/projects/leak-test/sessions/$SID_A"

echo "=== test-process-leak.sh ==="

# --- Issue #1: PID file management ---

# Test 1: Sequential listeners with timeout=1 don't leave stale PIDs
BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SID_A" 1 >/dev/null 2>&1 || true
BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SID_A" 1 >/dev/null 2>&1 || true
BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SID_A" 1 >/dev/null 2>&1 || true

PID_FILE="$SESSION_DIR_A/bridge-listen.pid"
if [ -f "$PID_FILE" ]; then
  STALE=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [ -n "$STALE" ] && kill -0 "$STALE" 2>/dev/null; then
    echo "  FAIL: stale listener process running after sequential calls"; FAIL=$((FAIL + 1))
  else
    echo "  PASS: no stale process after sequential listeners"; PASS=$((PASS + 1))
  fi
else
  echo "  PASS: PID file cleaned up after sequential listeners"; PASS=$((PASS + 1))
fi

# Test 2: A new listener updates the PID file (kills old recorded PID)
# Pre-populate PID file with a fake PID
echo "99999" > "$PID_FILE"
BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SID_A" 1 >/dev/null 2>&1 || true
if [ -f "$PID_FILE" ]; then
  NEW_PID=$(cat "$PID_FILE" 2>/dev/null || echo "99999")
  assert_eq "PID file updated from fake" "true" "$([ "$NEW_PID" != "99999" ] && echo true || echo false)"
else
  echo "  PASS: PID file cleaned up (listener exited)"; PASS=$((PASS + 1))
fi

# --- Issue #2: task-assign delivery ---
echo ""
echo "--- task-assign delivery tests ---"

# Test 3: task-assign is delivered and picked up
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_B" bash "$SEND_MSG" "$SID_A" task-assign "Fix issue #99" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SID_A" 5 2>/dev/null || echo "TIMEOUT")
assert_contains "task-assign picked up" "TYPE=task-assign" "$OUTPUT"
assert_contains "task-assign content delivered" "Fix issue #99" "$OUTPUT"

# Test 4: task-assign after query — both delivered
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_B" bash "$SEND_MSG" "$SID_A" query "What version?" > /dev/null
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_B" bash "$SEND_MSG" "$SID_A" task-assign "Deploy v2" > /dev/null

OUT1=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SID_A" 5 2>/dev/null || echo "TIMEOUT1")
OUT2=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SID_A" 5 2>/dev/null || echo "TIMEOUT2")
ALL="$OUT1 $OUT2"
assert_contains "query delivered" "What version?" "$ALL"
assert_contains "task-assign delivered after query" "Deploy v2" "$ALL"

# Test 5: Multiple task-assigns all delivered
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_B" bash "$SEND_MSG" "$SID_A" task-assign "Task Alpha" > /dev/null
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_B" bash "$SEND_MSG" "$SID_A" task-assign "Task Beta" > /dev/null
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_B" bash "$SEND_MSG" "$SID_A" task-assign "Task Gamma" > /dev/null

O1=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SID_A" 5 2>/dev/null || echo "T")
O2=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SID_A" 5 2>/dev/null || echo "T")
O3=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SID_A" 5 2>/dev/null || echo "T")
ALL3="$O1 $O2 $O3"
assert_contains "task Alpha delivered" "Task Alpha" "$ALL3"
assert_contains "task Beta delivered" "Task Beta" "$ALL3"
assert_contains "task Gamma delivered" "Task Gamma" "$ALL3"

print_results

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

# --- Issue #1: flock-based exclusive listener ---

# Test 1: Lock file persists after listener exits (never deleted)
BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SID_A" 1 >/dev/null 2>&1 || true
LOCK_FILE="$SESSION_DIR_A/bridge-listen.lock"
assert_eq "lock file persists after listener exit" "true" "$([ -f "$LOCK_FILE" ] && echo true || echo false)"

# Test 2: Lock is NOT held after listener exits (flock releases on fd close)
if flock -n "$LOCK_FILE" true 2>/dev/null; then
  echo "  PASS: lock not held after listener exit"; PASS=$((PASS + 1))
else
  echo "  FAIL: lock still held after listener exit"; FAIL=$((FAIL + 1))
fi

# Test 3: Sequential listeners reuse the same lock file (same inode)
INODE_BEFORE=$(stat -c %i "$LOCK_FILE" 2>/dev/null || stat -f %i "$LOCK_FILE" 2>/dev/null)
BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SID_A" 1 >/dev/null 2>&1 || true
INODE_AFTER=$(stat -c %i "$LOCK_FILE" 2>/dev/null || stat -f %i "$LOCK_FILE" 2>/dev/null)
assert_eq "sequential listeners reuse same lock inode" "$INODE_BEFORE" "$INODE_AFTER"

# Test 4: Second concurrent listener exits immediately (flock exclusion)
# Start a long listener in background
BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SID_A" 30 >/dev/null 2>&1 &
FIRST_BG=$!
sleep 1
# Try to start a second — should exit 0 immediately (lock held)
SECOND_RC=0
BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SID_A" 30 >/dev/null 2>&1 || SECOND_RC=$?
assert_eq "second listener exits cleanly (flock exclusion)" "0" "$SECOND_RC"
kill "$FIRST_BG" 2>/dev/null || true
pkill -P "$FIRST_BG" 2>/dev/null || true
sleep 0.5

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

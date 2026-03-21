#!/usr/bin/env bash
# tests/test-spurious-cleanup.sh — Tests for issue #3 (spurious session-ended during compaction)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREATE_PROJ="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"
CLEANUP="$PLUGIN_DIR/scripts/cleanup.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"
LISTEN="$PLUGIN_DIR/scripts/bridge-listen.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"; kill $(jobs -p) 2>/dev/null || true' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJ_A="$TEST_TMPDIR/proj-a"
PROJ_B="$TEST_TMPDIR/proj-b"
mkdir -p "$PROJ_A" "$PROJ_B"

BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE_PROJ" "cleanup-test" > /dev/null
SID_A=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_A" bash "$JOIN" "cleanup-test")
SID_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_B" bash "$JOIN" "cleanup-test")

SESSION_DIR_A="$BRIDGE_DIR/projects/cleanup-test/sessions/$SID_A"
SESSION_DIR_B="$BRIDGE_DIR/projects/cleanup-test/sessions/$SID_B"

echo "=== test-spurious-cleanup.sh ==="

# Test 1: Cleanup with live watcher does NOT remove session or notify peers
# The watcher should be running from project-join.sh
WATCHER_PID=""
if [ -f "$SESSION_DIR_A/watcher.pid" ]; then
  WATCHER_PID=$(cat "$SESSION_DIR_A/watcher.pid")
fi

if [ -n "$WATCHER_PID" ] && kill -0 "$WATCHER_PID" 2>/dev/null; then
  echo "  PASS: watcher is running before cleanup"; PASS=$((PASS + 1))
else
  # Watcher may not have started (no inotifywait in test env?) — start a fake one
  sleep 300 &
  WATCHER_PID=$!
  echo "$WATCHER_PID" > "$SESSION_DIR_A/watcher.pid"
  echo "  PASS: simulated watcher running"; PASS=$((PASS + 1))
fi

# Run cleanup WITHOUT confirmed flag (simulates SessionEnd during compaction)
BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_A" bash "$CLEANUP" 2>/dev/null || true

# Session directory should STILL exist (cleanup was a no-op)
assert_dir_exists "session dir survives non-terminal cleanup" "$SESSION_DIR_A"
assert_file_exists "manifest survives" "$SESSION_DIR_A/manifest.json"

# Peer B should NOT have received a session-ended message
ENDED_COUNT=0
for F in "$SESSION_DIR_B/inbox"/msg-*.json; do
  [ -f "$F" ] || continue
  TYPE=$(jq -r '.type' "$F" 2>/dev/null || echo "")
  [ "$TYPE" = "session-ended" ] && ENDED_COUNT=$((ENDED_COUNT + 1))
done
assert_eq "no spurious session-ended sent" "0" "$ENDED_COUNT"

# Test 2: Cleanup WITH confirmed flag DOES remove session and notify peers
BRIDGE_CLEANUP_CONFIRMED=1 BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_A" bash "$CLEANUP" 2>/dev/null || true

assert_eq "session dir removed after confirmed cleanup" "false" "$([ -d "$SESSION_DIR_A" ] && echo true || echo false)"

# Peer B should have received session-ended now
ENDED_COUNT=0
for F in "$SESSION_DIR_B/inbox"/msg-*.json; do
  [ -f "$F" ] || continue
  TYPE=$(jq -r '.type' "$F" 2>/dev/null || echo "")
  [ "$TYPE" = "session-ended" ] && ENDED_COUNT=$((ENDED_COUNT + 1))
done
assert_eq "session-ended sent on confirmed cleanup" "1" "$ENDED_COUNT"

# Test 3: Cleanup with dead watcher also does full cleanup (truly ended session)
# Re-create session A
SID_A2=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_A" bash "$JOIN" "cleanup-test")
SESSION_DIR_A2="$BRIDGE_DIR/projects/cleanup-test/sessions/$SID_A2"

# Kill the watcher to simulate a truly dead session
if [ -f "$SESSION_DIR_A2/watcher.pid" ]; then
  kill "$(cat "$SESSION_DIR_A2/watcher.pid")" 2>/dev/null || true
  sleep 0.5
fi
# Write a fake dead PID
echo "99999" > "$SESSION_DIR_A2/watcher.pid"

# Unconfirmed cleanup should still work because watcher is dead
BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_A" bash "$CLEANUP" 2>/dev/null || true
assert_eq "session dir removed when watcher dead" "false" "$([ -d "$SESSION_DIR_A2" ] && echo true || echo false)"

# Test 4: Legacy sessions always do full cleanup (no watcher check)
LEGACY_DIR="$TEST_TMPDIR/legacy-proj"
mkdir -p "$LEGACY_DIR/.claude"
LEGACY_SID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$LEGACY_DIR" bash "$PLUGIN_DIR/scripts/register.sh")
assert_dir_exists "legacy session created" "$BRIDGE_DIR/sessions/$LEGACY_SID"

BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$LEGACY_DIR" bash "$CLEANUP" 2>/dev/null || true
assert_eq "legacy session cleaned up" "false" "$([ -d "$BRIDGE_DIR/sessions/$LEGACY_SID" ] && echo true || echo false)"

print_results

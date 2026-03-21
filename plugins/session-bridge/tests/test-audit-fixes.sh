#!/usr/bin/env bash
# tests/test-audit-fixes.sh — Regression tests for the comprehensive audit fixes
# Covers: message type validation, timestamp validation, atomic writes,
# auto-join failure visibility, inotifywait error handling, per-session rate limiting
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREATE_PROJ="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"
CLEANUP="$PLUGIN_DIR/scripts/cleanup.sh"
AUTO_JOIN="$PLUGIN_DIR/scripts/auto-join.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"; kill $(jobs -p) 2>/dev/null || true' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJ_A="$TEST_TMPDIR/proj-a"
PROJ_B="$TEST_TMPDIR/proj-b"
mkdir -p "$PROJ_A" "$PROJ_B"

BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE_PROJ" "audit-test" > /dev/null
SID_A=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_A" bash "$JOIN" "audit-test")
SID_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_B" bash "$JOIN" "audit-test")

echo "=== test-audit-fixes.sh ==="

# --- Message type validation ---
echo ""
echo "--- message type validation ---"

# Test 1: Valid type succeeds
MSG_ID=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_A" bash "$SEND_MSG" "$SID_B" query "test" 2>/dev/null)
assert_not_empty "valid type query succeeds" "$MSG_ID"

# Test 2: Invalid type fails
if BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_A" bash "$SEND_MSG" "$SID_B" "taks-assign" "test" 2>/dev/null; then
  echo "  FAIL: typo'd type should error"; FAIL=$((FAIL + 1))
else
  echo "  PASS: typo'd type rejected"; PASS=$((PASS + 1))
fi

# Test 3: Another invalid type
if BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_A" bash "$SEND_MSG" "$SID_B" "qurey" "test" 2>/dev/null; then
  echo "  FAIL: misspelled type should error"; FAIL=$((FAIL + 1))
else
  echo "  PASS: misspelled type rejected"; PASS=$((PASS + 1))
fi

# --- Timestamp validation in cleanup ---
echo ""
echo "--- timestamp validation ---"

# Test 4: Session with null heartbeat is NOT deleted by stale cleanup
PROJ_NULL="$TEST_TMPDIR/null-hb"
mkdir -p "$PROJ_NULL"
NULL_SID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_NULL" bash "$JOIN" "audit-test")
NULL_MANIFEST="$BRIDGE_DIR/projects/audit-test/sessions/$NULL_SID/manifest.json"

# Corrupt the heartbeat to null
TMP=$(mktemp "$(dirname "$NULL_MANIFEST")/manifest.XXXXXX")
jq '.lastHeartbeat = null' "$NULL_MANIFEST" > "$TMP" && mv "$TMP" "$NULL_MANIFEST"

# Run cleanup from a different project dir (won't find this session as "its own")
BRIDGE_CLEANUP_CONFIRMED=1 BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$TEST_TMPDIR/nonexistent" bash "$CLEANUP" 2>/dev/null || true

# Session with null heartbeat should still exist (not deleted by stale pruning)
assert_dir_exists "null heartbeat session survives stale cleanup" "$BRIDGE_DIR/projects/audit-test/sessions/$NULL_SID"

# --- Per-session rate limiting ---
echo ""
echo "--- per-session rate limiting ---"

# Test 5: Rate limit file is per-session, not global
CHECK="$PLUGIN_DIR/scripts/check-inbox.sh"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_A" PROJECT_DIR="$PROJ_A" bash "$CHECK" --rate-limited 2>/dev/null || true
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_B" PROJECT_DIR="$PROJ_B" bash "$CHECK" --rate-limited 2>/dev/null || true

# Both should have their own rate-limit files
if ls "$BRIDGE_DIR/.last_inbox_check_$SID_A" >/dev/null 2>&1; then
  echo "  PASS: session A has own rate-limit file"; PASS=$((PASS + 1))
else
  echo "  FAIL: session A missing rate-limit file"; FAIL=$((FAIL + 1))
fi
if ls "$BRIDGE_DIR/.last_inbox_check_$SID_B" >/dev/null 2>&1; then
  echo "  PASS: session B has own rate-limit file"; PASS=$((PASS + 1))
else
  echo "  FAIL: session B missing rate-limit file"; FAIL=$((FAIL + 1))
fi

# Test 6: No global rate-limit file
if [ -f "$BRIDGE_DIR/.last_inbox_check" ]; then
  echo "  FAIL: global rate-limit file should not exist"; FAIL=$((FAIL + 1))
else
  echo "  PASS: no global rate-limit file (per-session only)"; PASS=$((PASS + 1))
fi

# --- Auto-join failure visibility ---
echo ""
echo "--- auto-join failure visibility ---"

# Test 7: Auto-join shows warning when project doesn't exist
PROJ_FAIL="$TEST_TMPDIR/fail-proj"
mkdir -p "$PROJ_FAIL/.claude"
echo '{"role": "specialist", "specialty": "", "name": "fail", "project": "nonexistent-project"}' > "$PROJ_FAIL/.claude/bridge-role"
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_FAIL" bash "$AUTO_JOIN" 2>/dev/null)
assert_contains "auto-join failure shows warning" "AUTO-JOIN FAILED" "$OUTPUT"

# --- Atomic claim in bridge-listen (no double delivery) ---
echo ""
echo "--- message claiming ---"

# Test 8: Claimed messages are invisible to other scanners
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID_A" bash "$SEND_MSG" "$SID_B" ping "claim-test" > /dev/null
INBOX_B="$BRIDGE_DIR/projects/audit-test/sessions/$SID_B/inbox"

# Count pending messages
PENDING=$(find "$INBOX_B" -name "*.json" -exec jq -r 'select(.status=="pending") | .id' {} \; 2>/dev/null | wc -l | tr -d '[:space:]')
assert_eq "one pending message" "true" "$([ "$PENDING" -ge 1 ] && echo true || echo false)"

# After bridge-listen claims it, no .claimed_ files should be left behind
BRIDGE_DIR="$BRIDGE_DIR" bash "$PLUGIN_DIR/scripts/bridge-listen.sh" "$SID_B" 5 >/dev/null 2>&1 || true
CLAIMED=$(find "$INBOX_B" -name ".claimed_*" 2>/dev/null | wc -l | tr -d '[:space:]')
assert_eq "no orphaned .claimed_ files" "0" "$CLAIMED"

# --- Watcher relaunch on rejoin ---
echo ""
echo "--- watcher relaunch ---"

# Test 9: Rejoin relaunches dead watcher
SESSION_DIR_A="$BRIDGE_DIR/projects/audit-test/sessions/$SID_A"
WATCHER_PID_FILE="$SESSION_DIR_A/watcher.pid"

# Kill the watcher
if [ -f "$WATCHER_PID_FILE" ]; then
  kill "$(cat "$WATCHER_PID_FILE")" 2>/dev/null || true
  pkill -P "$(cat "$WATCHER_PID_FILE")" 2>/dev/null || true
  sleep 0.5
fi
# Write a dead PID
echo "99999" > "$WATCHER_PID_FILE"

# Rejoin — should detect dead watcher and relaunch
BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_A" bash "$JOIN" "audit-test" > /dev/null
sleep 0.5

if [ -f "$WATCHER_PID_FILE" ]; then
  NEW_WPID=$(cat "$WATCHER_PID_FILE")
  if [ "$NEW_WPID" != "99999" ] && kill -0 "$NEW_WPID" 2>/dev/null; then
    echo "  PASS: watcher relaunched on rejoin with dead PID"; PASS=$((PASS + 1))
  else
    echo "  FAIL: watcher not relaunched (PID: $NEW_WPID)"; FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL: watcher PID file missing after rejoin"; FAIL=$((FAIL + 1))
fi

print_results

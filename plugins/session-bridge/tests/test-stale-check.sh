#!/usr/bin/env bash
# tests/test-stale-check.sh — Tests for scripts/lib/stale-check.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$PLUGIN_DIR/scripts/lib/stale-check.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

echo "=== test-stale-check.sh ==="

# Source the lib for testing
# shellcheck source=/dev/null
source "$LIB"

# --- Test 1: get_heartbeat_age returns seconds since file content timestamp ---
echo ""
echo "Test 1: get_heartbeat_age returns age in seconds"
HB_FILE="$TEST_TMPDIR/heartbeat"
TS_120S_AGO=$(date -u -d "120 seconds ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-120S +"%Y-%m-%dT%H:%M:%SZ")
echo "$TS_120S_AGO" > "$HB_FILE"
AGE=$(get_heartbeat_age "$HB_FILE")
# Age should be ~120 (allow ±5s slack for test runtime)
if [ "$AGE" -ge 115 ] && [ "$AGE" -le 130 ]; then
  echo "  PASS: heartbeat age ~120s (got $AGE)"; PASS=$((PASS + 1))
else
  echo "  FAIL: heartbeat age expected ~120, got $AGE"; FAIL=$((FAIL + 1))
fi

# --- Test 2: get_heartbeat_age returns 99999999 when file missing ---
echo ""
echo "Test 2: get_heartbeat_age returns sentinel when file missing"
MISSING_AGE=$(get_heartbeat_age "$TEST_TMPDIR/does-not-exist")
assert_eq "missing file → sentinel" "99999999" "$MISSING_AGE"

# --- Test 3: is_producer_alive returns 0 for $$ (this script process) ---
echo ""
echo "Test 3: is_producer_alive returns true for live PID"
# Self-PID is alive but won't pass the cmdline check (we're a test script, not heartbeat-daemon)
# So this should return 1 (false) — defensive cmdline guard
if is_producer_alive "$$"; then
  echo "  FAIL: self-pid passed cmdline guard (should reject)"; FAIL=$((FAIL + 1))
else
  echo "  PASS: cmdline guard rejects non-daemon PID"; PASS=$((PASS + 1))
fi

# --- Test 4: is_producer_alive returns 1 for dead PID ---
echo ""
echo "Test 4: is_producer_alive returns false for dead PID"
# Spawn-and-kill a short-lived process to get a guaranteed-dead PID
sleep 0 &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
if is_producer_alive "$DEAD_PID"; then
  echo "  FAIL: dead PID reported alive"; FAIL=$((FAIL + 1))
else
  echo "  PASS: dead PID reported dead"; PASS=$((PASS + 1))
fi

# --- Test 5: is_producer_alive returns 1 for empty PID ---
echo ""
echo "Test 5: is_producer_alive returns false for empty PID"
if is_producer_alive ""; then
  echo "  FAIL: empty PID reported alive"; FAIL=$((FAIL + 1))
else
  echo "  PASS: empty PID reported dead"; PASS=$((PASS + 1))
fi

# --- Test 6: is_stale returns false when status=offline ---
echo ""
echo "Test 6: is_stale returns false when status=offline"
SESSION_DIR="$TEST_TMPDIR/session1"
mkdir -p "$SESSION_DIR"
echo '{"sessionId":"abc123","status":"offline"}' > "$SESSION_DIR/manifest.json"
TS_OLD=$(date -u -d "1 hour ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-1H +"%Y-%m-%dT%H:%M:%SZ")
echo "$TS_OLD" > "$SESSION_DIR/heartbeat"
if is_stale "$SESSION_DIR" 300; then
  echo "  FAIL: offline session reported stale"; FAIL=$((FAIL + 1))
else
  echo "  PASS: offline session not stale"; PASS=$((PASS + 1))
fi

# --- Test 7: is_stale returns true when status=active + heartbeat old + no daemon PID file ---
echo ""
echo "Test 7: is_stale returns true when status=active, heartbeat old, no daemon"
SESSION_DIR="$TEST_TMPDIR/session2"
mkdir -p "$SESSION_DIR"
echo '{"sessionId":"def456","status":"active"}' > "$SESSION_DIR/manifest.json"
echo "$TS_OLD" > "$SESSION_DIR/heartbeat"
# No watcher.pid file — daemon presumed dead
if is_stale "$SESSION_DIR" 300; then
  echo "  PASS: stale session correctly detected"; PASS=$((PASS + 1))
else
  echo "  FAIL: stale session not detected"; FAIL=$((FAIL + 1))
fi

# --- Test 8: is_stale returns false when status=active + heartbeat fresh ---
echo ""
echo "Test 8: is_stale returns false when heartbeat is fresh"
SESSION_DIR="$TEST_TMPDIR/session3"
mkdir -p "$SESSION_DIR"
echo '{"sessionId":"ghi789","status":"active"}' > "$SESSION_DIR/manifest.json"
TS_NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "$TS_NOW" > "$SESSION_DIR/heartbeat"
if is_stale "$SESSION_DIR" 300; then
  echo "  FAIL: fresh heartbeat reported stale"; FAIL=$((FAIL + 1))
else
  echo "  PASS: fresh heartbeat not stale"; PASS=$((PASS + 1))
fi

# --- Test 9: set_status writes new status field atomically ---
echo ""
echo "Test 9: set_status writes new status to manifest"
SESSION_DIR="$TEST_TMPDIR/session4"
mkdir -p "$SESSION_DIR"
echo '{"sessionId":"jkl012","status":"active","other":"keep"}' > "$SESSION_DIR/manifest.json"
set_status "$SESSION_DIR/manifest.json" "stale"
assert_json_field "status flipped to stale" "$SESSION_DIR/manifest.json" ".status" "stale"
assert_json_field "other field preserved" "$SESSION_DIR/manifest.json" ".other" "keep"

print_results

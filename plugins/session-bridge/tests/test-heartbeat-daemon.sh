#!/usr/bin/env bash
# tests/test-heartbeat-daemon.sh — Tests for scripts/heartbeat-daemon.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DAEMON="$PLUGIN_DIR/scripts/heartbeat-daemon.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

echo "=== test-heartbeat-daemon.sh ==="

# Set up a fake session dir
SESSION_DIR="$TEST_TMPDIR/session"
mkdir -p "$SESSION_DIR"
echo '{"sessionId":"test01","status":"active"}' > "$SESSION_DIR/manifest.json"

# --- Test 1: Daemon writes heartbeat file on first tick ---
echo ""
echo "Test 1: heartbeat file is written on first tick"
HEARTBEAT_INTERVAL=1 bash "$DAEMON" "$SESSION_DIR" &
DAEMON_PID=$!
sleep 2  # wait for at least one tick
HB_FILE="$SESSION_DIR/heartbeat"
assert_file_exists "heartbeat file exists" "$HB_FILE"
HB_CONTENT=$(cat "$HB_FILE")
assert_contains "heartbeat contains ISO 8601 timestamp" "T" "$HB_CONTENT"
assert_contains "heartbeat ends with Z" "Z" "$HB_CONTENT"
kill "$DAEMON_PID" 2>/dev/null || true
wait "$DAEMON_PID" 2>/dev/null || true

# --- Test 2: Daemon updates heartbeat across multiple ticks ---
echo ""
echo "Test 2: heartbeat is updated across ticks"
SESSION_DIR2="$TEST_TMPDIR/session2"
mkdir -p "$SESSION_DIR2"
echo '{"sessionId":"test02","status":"active"}' > "$SESSION_DIR2/manifest.json"
HEARTBEAT_INTERVAL=1 bash "$DAEMON" "$SESSION_DIR2" &
DAEMON_PID=$!
sleep 1
HB1=$(cat "$SESSION_DIR2/heartbeat")
sleep 2
HB2=$(cat "$SESSION_DIR2/heartbeat")
if [ "$HB1" = "$HB2" ]; then
  echo "  FAIL: heartbeat did not update across ticks (HB1=$HB1, HB2=$HB2)"; FAIL=$((FAIL + 1))
else
  echo "  PASS: heartbeat updated across ticks"; PASS=$((PASS + 1))
fi
kill "$DAEMON_PID" 2>/dev/null || true
wait "$DAEMON_PID" 2>/dev/null || true

# --- Test 3: Daemon writes PID file ---
echo ""
echo "Test 3: heartbeat-daemon.pid file is written"
SESSION_DIR3="$TEST_TMPDIR/session3"
mkdir -p "$SESSION_DIR3"
echo '{"sessionId":"test03","status":"active"}' > "$SESSION_DIR3/manifest.json"
HEARTBEAT_INTERVAL=1 bash "$DAEMON" "$SESSION_DIR3" &
DAEMON_PID=$!
sleep 2
PID_FILE="$SESSION_DIR3/heartbeat-daemon.pid"
assert_file_exists "PID file exists" "$PID_FILE"
WRITTEN_PID=$(cat "$PID_FILE")
assert_eq "PID file contains daemon PID" "$DAEMON_PID" "$WRITTEN_PID"
kill "$DAEMON_PID" 2>/dev/null || true
wait "$DAEMON_PID" 2>/dev/null || true

# --- Test 4: EXIT trap flips status=active → stale on SIGTERM ---
echo ""
echo "Test 4: EXIT trap sets status=stale when killed while active"
SESSION_DIR4="$TEST_TMPDIR/session4"
mkdir -p "$SESSION_DIR4"
echo '{"sessionId":"test04","status":"active"}' > "$SESSION_DIR4/manifest.json"
HEARTBEAT_INTERVAL=1 bash "$DAEMON" "$SESSION_DIR4" &
DAEMON_PID=$!
sleep 2
kill -TERM "$DAEMON_PID"
wait "$DAEMON_PID" 2>/dev/null || true
sleep 1
assert_json_field "status flipped to stale" "$SESSION_DIR4/manifest.json" ".status" "stale"

# --- Test 5: EXIT trap is no-op when status=offline ---
echo ""
echo "Test 5: EXIT trap is no-op when status=offline"
SESSION_DIR5="$TEST_TMPDIR/session5"
mkdir -p "$SESSION_DIR5"
echo '{"sessionId":"test05","status":"active"}' > "$SESSION_DIR5/manifest.json"
HEARTBEAT_INTERVAL=1 bash "$DAEMON" "$SESSION_DIR5" &
DAEMON_PID=$!
sleep 2
# Simulate close-session.sh: flip status first, THEN kill daemon
jq '.status = "offline"' "$SESSION_DIR5/manifest.json" > "$SESSION_DIR5/manifest.tmp" && mv "$SESSION_DIR5/manifest.tmp" "$SESSION_DIR5/manifest.json"
kill -TERM "$DAEMON_PID"
wait "$DAEMON_PID" 2>/dev/null || true
sleep 1
assert_json_field "status remained offline" "$SESSION_DIR5/manifest.json" ".status" "offline"

print_results

#!/usr/bin/env bash
# tests/test-bridge-listen.sh — Tests for scripts/bridge-listen.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"
LISTEN="$PLUGIN_DIR/scripts/bridge-listen.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_A="$TEST_TMPDIR/project-a"
PROJECT_B="$TEST_TMPDIR/project-b"
mkdir -p "$PROJECT_A" "$PROJECT_B"

SESSION_A=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$REGISTER")
SESSION_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$REGISTER")

echo "=== test-bridge-listen.sh ==="
echo "  session_a=$SESSION_A  session_b=$SESSION_B"

# --- Helper (#27 pending-guard, v0.3.3 Task 2) ---
# bridge-listen.sh now refuses to launch when its target inbox already has a
# pending message sitting in it (that backlog must be drained first — see
# tests/test-bridge-listen-pending-guard.sh). Most of this file's tests were
# originally written as "drop a message in the inbox, THEN call bridge-listen
# synchronously and expect immediate pickup" — that shape now trips the guard
# before the listener ever gets to its scan loop.
#
# This helper launches the listener FIRST against an empty inbox (the guard
# passes), settles briefly so it clears the guard + flock + arms its
# filesystem watcher, then returns control so the caller can send a message
# that arrives DURING the blocking wait — the actual scenario bridge-listen
# is designed for, and a closer match to real /bridge standby usage than the
# original synchronous send-then-listen shape. Sets LISTEN_BG_PID as a global
# (NOT via command substitution / echo — backgrounding inside a `$(...)`
# subshell would reparent the job so the caller's `wait` can't see it) so the
# caller can `wait "$LISTEN_BG_PID"` and then read $4 for the captured output.
# Usage: start_listener_bg <bridge-dir> <session-id> <timeout> <outfile>
start_listener_bg() {
  local bdir="$1" sid="$2" timeout="$3" outfile="$4"
  BRIDGE_DIR="$bdir" bash "$LISTEN" "$sid" "$timeout" > "$outfile" 2>&1 &
  LISTEN_BG_PID=$!
  sleep 1
}

# --- Test 1: Returns message when pending ---
echo ""
echo "Test 1: Returns message content when a pending message exists"
OUT1="$TEST_TMPDIR/listen-out-1.txt"
start_listener_bg "$BRIDGE_DIR" "$SESSION_B" 5 "$OUT1"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" query "Hello from A" > /dev/null
wait "$LISTEN_BG_PID" || true
OUTPUT=$(cat "$OUT1")
assert_contains "has MESSAGE_ID" "MESSAGE_ID=" "$OUTPUT"
assert_contains "has FROM_ID" "FROM_ID=$SESSION_A" "$OUTPUT"
assert_contains "has TYPE=query" "TYPE=query" "$OUTPUT"
assert_contains "has message content" "Hello from A" "$OUTPUT"
if echo "$OUTPUT" | grep -qF -- "---"; then
  echo "  PASS: has separator between metadata and content"; PASS=$((PASS + 1))
else
  echo "  FAIL: missing separator"; FAIL=$((FAIL + 1))
fi

# --- Test 2: Message archived (not deleted) after pickup ---
echo ""
echo "Test 2: Message archived to .delivered/ after pickup"
MSG_COUNT=$(find "$BRIDGE_DIR/sessions/$SESSION_B/inbox" -maxdepth 1 -name "*.json" 2>/dev/null | wc -l)
assert_eq "no messages at top of inbox" "0" "$MSG_COUNT"
ARCHIVE_COUNT=$(find "$BRIDGE_DIR/sessions/$SESSION_B/inbox/.delivered" -name "*.json" 2>/dev/null | wc -l)
assert_eq "one message in .delivered/" "1" "$ARCHIVE_COUNT"

# --- Test 3: No messages to re-deliver ---
echo ""
echo "Test 3: No messages to re-deliver (inbox is empty)"
if BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 3 > /dev/null 2>&1; then
  echo "  FAIL: re-delivered a deleted message"; FAIL=$((FAIL + 1))
else
  echo "  PASS: no message returned from empty inbox"; PASS=$((PASS + 1))
fi

# --- Test 4: Times out with exit code 1 when inbox is empty ---
echo ""
echo "Test 4: Times out correctly on empty inbox"
if BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 3 > /dev/null 2>&1; then
  echo "  FAIL: should have timed out"; FAIL=$((FAIL + 1))
else
  echo "  PASS: timed out with exit 1"; PASS=$((PASS + 1))
fi

# --- Test 5: Picks up ping messages ---
echo ""
echo "Test 5: Handles ping message type"
OUT5="$TEST_TMPDIR/listen-out-5.txt"
start_listener_bg "$BRIDGE_DIR" "$SESSION_B" 5 "$OUT5"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" ping "connected" > /dev/null
wait "$LISTEN_BG_PID" || true
OUTPUT=$(cat "$OUT5")
assert_contains "ping type detected" "TYPE=ping" "$OUTPUT"

# --- Test 6: Only picks messages from OWN inbox, not other sessions ---
echo ""
echo "Test 6: Does not pick up messages from other sessions' inboxes"
PROJECT_C="$TEST_TMPDIR/project-c"
mkdir -p "$PROJECT_C"
SESSION_C=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_C" bash "$REGISTER")
# Launch C's listener first (empty inbox), then send to C's inbox from A —
# arrives during C's blocking wait.
OUT6C="$TEST_TMPDIR/listen-out-6c.txt"
start_listener_bg "$BRIDGE_DIR" "$SESSION_C" 5 "$OUT6C"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_C" query "For session C" > /dev/null
# Listen on B (own empty inbox, unaffected by C's traffic) — should NOT pick up C's message
if BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 3 > /dev/null 2>&1; then
  echo "  FAIL: B picked up C's message"; FAIL=$((FAIL + 1))
else
  echo "  PASS: B correctly ignores C's inbox"; PASS=$((PASS + 1))
fi
# C — SHOULD pick it up
wait "$LISTEN_BG_PID" || true
OUTPUT=$(cat "$OUT6C")
assert_contains "C picks up its own message" "For session C" "$OUTPUT"

# --- Test 7: Does NOT pick up own outgoing messages (echo prevention) ---
echo ""
echo "Test 7: Does not echo own messages back"
# Launch A's listener first (empty inbox), then B sends to A — message lands
# in A's inbox and arrives during A's blocking wait.
OUT7="$TEST_TMPDIR/listen-out-7.txt"
start_listener_bg "$BRIDGE_DIR" "$SESSION_A" 5 "$OUT7"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_B" bash "$SEND_MSG" "$SESSION_A" query "From B" > /dev/null
wait "$LISTEN_BG_PID" || true
OUTPUT=$(cat "$OUT7")
assert_contains "A picks up B's message" "From B" "$OUTPUT"
# Now: B sends a response to A, message lands in A's inbox FROM B
# If B somehow had that in its own inbox too, it should be skipped
# This tests the FROM_ID != SESSION_ID check

# --- Test 8: inReplyTo field is included in output when set ---
echo ""
echo "Test 8: inReplyTo field is included in output when set"
ORIG_ID="msg-original-123"
OUT8="$TEST_TMPDIR/listen-out-8.txt"
start_listener_bg "$BRIDGE_DIR" "$SESSION_B" 5 "$OUT8"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" response "My reply" "$ORIG_ID" > /dev/null
wait "$LISTEN_BG_PID" || true
OUTPUT=$(cat "$OUT8")
assert_contains "inReplyTo in output" "IN_REPLY_TO=$ORIG_ID" "$OUTPUT"

echo ""
echo "--- inotifywait/project-scoped tests ---"

# Test I1: Works with project-scoped inbox
V2_TMPDIR=$(mktemp -d)
V2_BRIDGE="$V2_TMPDIR/bridge"
V2_PROJ_A="$V2_TMPDIR/proj-a"
V2_PROJ_B="$V2_TMPDIR/proj-b"
mkdir -p "$V2_PROJ_A" "$V2_PROJ_B"
BRIDGE_DIR="$V2_BRIDGE" bash "$PLUGIN_DIR/scripts/project-create.sh" "listen-proj" > /dev/null
V2_SID_A=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_A" bash "$PLUGIN_DIR/scripts/project-join.sh" "listen-proj")
V2_SID_B=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_B" bash "$PLUGIN_DIR/scripts/project-join.sh" "listen-proj")

# Launch listener first (empty inbox), then send a message — arrives during the wait.
OUT_I1="$V2_TMPDIR/listen-out-i1.txt"
start_listener_bg "$V2_BRIDGE" "$V2_SID_B" 5 "$OUT_I1"
BRIDGE_DIR="$V2_BRIDGE" BRIDGE_SESSION_ID="$V2_SID_A" bash "$PLUGIN_DIR/scripts/send-message.sh" "$V2_SID_B" ping "hello" > /dev/null
wait "$LISTEN_BG_PID" || true
OUTPUT=$(cat "$OUT_I1")
assert_contains "finds project-scoped message" "TYPE=ping" "$OUTPUT"

rm -rf "$V2_TMPDIR"

echo ""
echo "--- BRIDGE_STATUS output markers ---"

# Test S1: delivered status prefix on successful message delivery
echo ""
echo "Test S1: emits BRIDGE_STATUS=delivered when a message is handed off"
OUT_S1="$TEST_TMPDIR/listen-out-s1.txt"
start_listener_bg "$BRIDGE_DIR" "$SESSION_B" 5 "$OUT_S1"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" ping "status-test" > /dev/null
wait "$LISTEN_BG_PID" || true
OUTPUT=$(cat "$OUT_S1")
FIRST_LINE=$(echo "$OUTPUT" | head -1)
assert_eq "first line is BRIDGE_STATUS=delivered" "BRIDGE_STATUS=delivered" "$FIRST_LINE"

# Test S2: already_running status when a second listener can't get the lock
echo ""
echo "Test S2: emits BRIDGE_STATUS=already_running when another listener holds the lock"
BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 60 >/dev/null 2>&1 &
HOLDER_PID=$!
# Give the holder a moment to take the flock
sleep 1
SECOND_OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 5 2>/dev/null || true)
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
assert_eq "second listener reports already_running" "BRIDGE_STATUS=already_running" "$SECOND_OUTPUT"

# Test S3: timeout status when listener hits its timeout with no message
echo ""
echo "Test S3: emits BRIDGE_STATUS=timeout on timeout with empty inbox"
TIMEOUT_OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 2 2>/dev/null || true)
assert_eq "timed-out listener reports timeout" "BRIDGE_STATUS=timeout" "$TIMEOUT_OUTPUT"

# --- Test R1: Pre-existing message delivered immediately on listener start ---
# Deliberately sends BEFORE starting the listener to exercise the "scan finds
# a file that was already there, no CREATE event needed" code path (the
# scan-then-watch race the ARM-before-scan ordering closes). That shape is
# exactly what the #27 pending-guard now refuses by default, so this uses the
# documented escape hatch (BRIDGE_STANDBY_IGNORE_PENDING=1) to reach it —
# this is the guard's sanctioned bypass, not a weakening of it.
echo ""
echo "Test R1: Pre-existing inbox message picked up on first scan"
# Send a message BEFORE starting the listener — the file is already in inbox
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" query "race-pre-existing" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_STANDBY_IGNORE_PENDING=1 bash "$LISTEN" "$SESSION_B" 5)
assert_contains "delivers pre-existing message" "race-pre-existing" "$OUTPUT"

# --- Test R2: Listener loop iterates correctly after a delivery (re-scan picks up next) ---
# Both messages are queued BEFORE either listener invocation, modeling a
# backlog that built up while no listener was running — the same
# escape-hatch-sanctioned scenario as R1 above.
echo ""
echo "Test R2: Two messages in rapid succession both deliver across two listener invocations"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" query "race-burst-1" > /dev/null
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" query "race-burst-2" > /dev/null
OUTPUT1=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_STANDBY_IGNORE_PENDING=1 bash "$LISTEN" "$SESSION_B" 5)
OUTPUT2=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_STANDBY_IGNORE_PENDING=1 bash "$LISTEN" "$SESSION_B" 5)
COMBINED="$OUTPUT1$OUTPUT2"
assert_contains "first burst message delivered" "race-burst-1" "$COMBINED"
assert_contains "second burst message delivered" "race-burst-2" "$COMBINED"

print_results

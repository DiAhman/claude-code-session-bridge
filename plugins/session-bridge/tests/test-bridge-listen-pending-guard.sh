#!/usr/bin/env bash
# tests/test-bridge-listen-pending-guard.sh — Tests for the pending-message
# guard in scripts/bridge-listen.sh (#27 architectural fix).
#
# bridge-listen.sh (aka /bridge standby) blocks waiting for FUTURE messages.
# It must refuse to launch at all when the caller's inbox already has
# pre-queued, undrained messages sitting in it — those need to surface as
# actionable turn input (via check-inbox.sh, or SessionStart's --drain on
# cold start) BEFORE the agent buries them under a blocking wait-loop.
#
# Escape hatch: BRIDGE_STANDBY_IGNORE_PENDING=1 bypasses the guard for the
# rare case an operator deliberately wants to ignore the backlog.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"
LISTEN="$PLUGIN_DIR/scripts/bridge-listen.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"; kill $(jobs -p) 2>/dev/null || true' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_A="$TEST_TMPDIR/project-a"
PROJECT_B="$TEST_TMPDIR/project-b"
mkdir -p "$PROJECT_A" "$PROJECT_B"

SESSION_A=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$REGISTER")
SESSION_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$REGISTER")

echo "=== test-bridge-listen-pending-guard.sh ==="
echo "  session_a=$SESSION_A  session_b=$SESSION_B"

# --- Test 1: refuses launch when a pending message already sits in the inbox ---
echo ""
echo "Test 1: refuses to launch when inbox has a pending message"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" task-assign "pre-queued directive" > /dev/null
OUT_FILE="$TEST_TMPDIR/t1.out"
ERR_FILE="$TEST_TMPDIR/t1.err"
set +e
BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 5 > "$OUT_FILE" 2> "$ERR_FILE"
RC=$?
set -e
assert_eq "exit code is 1" "1" "$RC"
FIRST_LINE=$(head -1 "$OUT_FILE")
assert_eq "stdout first line is BRIDGE_STATUS=pending_messages" "BRIDGE_STATUS=pending_messages" "$FIRST_LINE"
assert_contains "stderr explains the refusal" "pre-queued message" "$(cat "$ERR_FILE")"
assert_contains "stderr names the override env" "BRIDGE_STANDBY_IGNORE_PENDING=1" "$(cat "$ERR_FILE")"
assert_contains "stderr points at check-inbox.sh" "check-inbox.sh" "$(cat "$ERR_FILE")"

# --- Test 2: escape hatch BRIDGE_STANDBY_IGNORE_PENDING=1 bypasses the guard ---
echo ""
echo "Test 2: BRIDGE_STANDBY_IGNORE_PENDING=1 bypasses the guard"
# Inbox still has the pending message from Test 1 (guard refused before any claim).
OUT_FILE="$TEST_TMPDIR/t2.out"
set +e
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_STANDBY_IGNORE_PENDING=1 bash "$LISTEN" "$SESSION_B" 5 > "$OUT_FILE" 2>/dev/null
RC=$?
set -e
FIRST_LINE=$(head -1 "$OUT_FILE")
assert_eq "escape hatch: exit code is 0 (message delivered)" "0" "$RC"
assert_eq "escape hatch: first line is BRIDGE_STATUS=delivered" "BRIDGE_STATUS=delivered" "$FIRST_LINE"
assert_contains "escape hatch: delivers the pre-queued message content" "pre-queued directive" "$(cat "$OUT_FILE")"

# --- Test 3: normal launch proceeds when inbox is empty ---
echo ""
echo "Test 3: normal launch proceeds when inbox is empty (times out, not refused)"
OUT_FILE="$TEST_TMPDIR/t3.out"
set +e
BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 2 > "$OUT_FILE" 2>/dev/null
RC=$?
set -e
FIRST_LINE=$(head -1 "$OUT_FILE")
assert_eq "empty inbox: exit code is 1 (timeout, not refusal)" "1" "$RC"
assert_eq "empty inbox: first line is BRIDGE_STATUS=timeout" "BRIDGE_STATUS=timeout" "$FIRST_LINE"

# --- Test 4: guard checks the CALLER's own inbox, not unrelated sessions' ---
echo ""
echo "Test 4: guard does not trip on another session's pending message"
PROJECT_C="$TEST_TMPDIR/project-c"
mkdir -p "$PROJECT_C"
SESSION_C=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_C" bash "$REGISTER")
# Message queued for C, not B — B's own inbox is empty.
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_C" query "for C only" > /dev/null
OUT_FILE="$TEST_TMPDIR/t4.out"
set +e
BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 2 > "$OUT_FILE" 2>/dev/null
RC=$?
set -e
FIRST_LINE=$(head -1 "$OUT_FILE")
assert_eq "B's own empty inbox: exit code is 1 (timeout, not refusal)" "1" "$RC"
assert_eq "B's own empty inbox: first line is BRIDGE_STATUS=timeout" "BRIDGE_STATUS=timeout" "$FIRST_LINE"

# --- Test 5: guard runs before flock acquire, not after ---
# A launch refused by the pending-guard must not hold or disturb the lock —
# a subsequent legitimate listener must still be able to acquire it.
echo ""
echo "Test 5: guard-refused launch does not leak the flock"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_C" ping "another pending" > /dev/null
OUT_FILE="$TEST_TMPDIR/t5.out"
set +e
BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_C" 5 > "$OUT_FILE" 2>/dev/null
RC=$?
set -e
assert_eq "refused launch: exit code is 1" "1" "$RC"
assert_eq "refused launch: BRIDGE_STATUS=pending_messages" "BRIDGE_STATUS=pending_messages" "$(head -1 "$OUT_FILE")"
# Drain ALL pending messages out from under it (simulating check-inbox.sh —
# C's inbox also still holds the "for C only" message from Test 4, which was
# never consumed since Test 4 listened on B), then confirm the lock is free.
find "$BRIDGE_DIR/sessions/$SESSION_C/inbox" -maxdepth 1 -name "*.json" -delete
OUT_FILE2="$TEST_TMPDIR/t5b.out"
set +e
BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_C" 2 > "$OUT_FILE2" 2>/dev/null
RC2=$?
set -e
assert_eq "lock still acquirable after refusal: exit code is 1 (timeout)" "1" "$RC2"
assert_eq "lock still acquirable after refusal: BRIDGE_STATUS=timeout (not already_running)" "BRIDGE_STATUS=timeout" "$(head -1 "$OUT_FILE2")"

print_results

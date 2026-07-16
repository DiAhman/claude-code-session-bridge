#!/usr/bin/env bash
# tests/test-bridge-listen-double-fork.sh — Tests for the double-fork PPID guard
# in scripts/bridge-listen.sh. Covers issue #18 — listener must refuse to start
# when Claude Code's run_in_background:true is combined with a trailing & in the
# same Bash invocation, because that pattern reparents the listener to init and
# leaks the process.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
LISTEN="$PLUGIN_DIR/scripts/bridge-listen.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_A="$TEST_TMPDIR/project-a"
mkdir -p "$PROJECT_A"

SESSION_A=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$REGISTER")

echo "=== test-bridge-listen-double-fork.sh ==="
echo "  session_a=$SESSION_A"

# --- Test 1: guard refuses when all three conditions are met ---
echo ""
echo "Test 1: refuses when PPID dead + cmdline matches 'bash -c .* &' + env unset"
OUT_FILE="$TEST_TMPDIR/t1.out"
ERR_FILE="$TEST_TMPDIR/t1.err"
set +e
BRIDGE_DIR="$BRIDGE_DIR" \
  BRIDGE_FAKE_PPID=999999 \
  BRIDGE_FAKE_PPID_DEAD=1 \
  BRIDGE_FAKE_PPID_CMDLINE="bash -c bash $LISTEN $SESSION_A 0 &" \
  bash "$LISTEN" "$SESSION_A" 1 > "$OUT_FILE" 2> "$ERR_FILE"
RC=$?
set -e
assert_eq "exit code is 1" "1" "$RC"
FIRST_LINE=$(head -1 "$OUT_FILE")
assert_eq "stdout first line is BRIDGE_STATUS=double_fork_refused" "BRIDGE_STATUS=double_fork_refused" "$FIRST_LINE"
assert_contains "stderr explains the refusal" "backgrounded-via-shell-& pattern" "$(cat "$ERR_FILE")"
assert_contains "stderr names the override env" "BRIDGE_INTENTIONAL_DOUBLE_FORK=1" "$(cat "$ERR_FILE")"

# --- Test 2: guard does NOT trip when parent is alive (normal Claude Code launch) ---
echo ""
echo "Test 2: guard does NOT trip when parent is alive even if cmdline matches"
OUT_FILE="$TEST_TMPDIR/t2.out"
set +e
BRIDGE_DIR="$BRIDGE_DIR" \
  BRIDGE_FAKE_PPID="$$" \
  BRIDGE_FAKE_PPID_DEAD=0 \
  BRIDGE_FAKE_PPID_CMDLINE="bash -c bash $LISTEN $SESSION_A 0 &" \
  bash "$LISTEN" "$SESSION_A" 1 > "$OUT_FILE" 2>/dev/null
RC=$?
set -e
FIRST_LINE=$(head -1 "$OUT_FILE")
assert_eq "first line is BRIDGE_STATUS=timeout (no message, normal exit)" "BRIDGE_STATUS=timeout" "$FIRST_LINE"
assert_eq "exit code is 1 from timeout (not refusal)" "1" "$RC"

# --- Test 3: guard does NOT trip when cmdline doesn't match the suicide pattern ---
echo ""
echo "Test 3: guard does NOT trip when parent cmdline lacks trailing &"
OUT_FILE="$TEST_TMPDIR/t3.out"
set +e
BRIDGE_DIR="$BRIDGE_DIR" \
  BRIDGE_FAKE_PPID=999998 \
  BRIDGE_FAKE_PPID_DEAD=1 \
  BRIDGE_FAKE_PPID_CMDLINE="bash -c bash $LISTEN $SESSION_A 0" \
  bash "$LISTEN" "$SESSION_A" 1 > "$OUT_FILE" 2>/dev/null
RC=$?
set -e
FIRST_LINE=$(head -1 "$OUT_FILE")
assert_eq "first line is BRIDGE_STATUS=timeout" "BRIDGE_STATUS=timeout" "$FIRST_LINE"

# --- Test 4: opt-out env var bypasses the guard ---
echo ""
echo "Test 4: BRIDGE_INTENTIONAL_DOUBLE_FORK=1 bypasses the guard"
OUT_FILE="$TEST_TMPDIR/t4.out"
set +e
BRIDGE_DIR="$BRIDGE_DIR" \
  BRIDGE_INTENTIONAL_DOUBLE_FORK=1 \
  BRIDGE_FAKE_PPID=999997 \
  BRIDGE_FAKE_PPID_DEAD=1 \
  BRIDGE_FAKE_PPID_CMDLINE="bash -c bash $LISTEN $SESSION_A 0 &" \
  bash "$LISTEN" "$SESSION_A" 1 > "$OUT_FILE" 2>/dev/null
RC=$?
set -e
FIRST_LINE=$(head -1 "$OUT_FILE")
assert_eq "first line is BRIDGE_STATUS=timeout (override let it proceed)" "BRIDGE_STATUS=timeout" "$FIRST_LINE"

# --- Test 5: guard does NOT false-positive on a normal direct invocation ---
# This is the regression test: existing tests/test-bridge-listen.sh runs the
# listener via 'bash $LISTEN ...' from a live shell parent. That must keep
# working with no env stubbing.
echo ""
echo "Test 5: normal direct invocation (no env stubs) reaches the loop"
OUT_FILE="$TEST_TMPDIR/t5.out"
set +e
BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_A" 1 > "$OUT_FILE" 2>/dev/null
RC=$?
set -e
FIRST_LINE=$(head -1 "$OUT_FILE")
assert_eq "first line is BRIDGE_STATUS=timeout (no false positive)" "BRIDGE_STATUS=timeout" "$FIRST_LINE"
assert_eq "exit code is 1 from timeout" "1" "$RC"

print_results

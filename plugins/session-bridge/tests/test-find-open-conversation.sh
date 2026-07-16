#!/usr/bin/env bash
# tests/test-find-open-conversation.sh — Tests for scripts/lib/find-open-conversation.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$PLUGIN_DIR/scripts/lib/find-open-conversation.sh"
CONV_CREATE="$PLUGIN_DIR/scripts/conversation-create.sh"
CONV_UPDATE="$PLUGIN_DIR/scripts/conversation-update.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
export BRIDGE_DIR

echo "=== test-find-open-conversation.sh ==="

# shellcheck source=/dev/null
source "$LIB"

# --- Fixtures: project + two sessions ---
setup_project_session "$BRIDGE_DIR" "alpha" "aaaaaa" "orchestrator" "lead" > /dev/null
setup_project_session "$BRIDGE_DIR" "alpha" "bbbbbb" "specialist" "worker" > /dev/null
setup_project_session "$BRIDGE_DIR" "alpha" "cccccc" "specialist" "other"  > /dev/null

# --- Test 1: zero matches returns empty, exit 0 ---
echo ""
echo "Test 1: zero open conversations → empty stdout, exit 0"
GOT=$(find_open_conversation "aaaaaa" "bbbbbb" "alpha")
RC=$?
assert_eq "stdout empty" "" "$GOT"
assert_eq "exit 0" "0" "$RC"

# --- Test 2: single match returns the conv-id ---
echo ""
echo "Test 2: single open conversation returns its id"
CONV1=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_CREATE" "alpha" "aaaaaa" "bbbbbb" "topic one")
GOT=$(find_open_conversation "aaaaaa" "bbbbbb" "alpha")
assert_eq "returns conv1" "$CONV1" "$GOT"

# --- Test 3: participant order does not matter ---
echo ""
echo "Test 3: participant order doesn't matter"
GOT=$(find_open_conversation "bbbbbb" "aaaaaa" "alpha")
assert_eq "swapped order still matches" "$CONV1" "$GOT"

# --- Test 4: resolved conversation is ignored ---
echo ""
echo "Test 4: resolved conversation is ignored"
BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_UPDATE" "alpha" "$CONV1" "resolved" --resolution "done"
GOT=$(find_open_conversation "aaaaaa" "bbbbbb" "alpha")
assert_eq "resolved skipped → empty" "" "$GOT"

# --- Test 5: waiting status still counts as open ---
echo ""
echo "Test 5: status=waiting counts as not-resolved"
CONV2=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_CREATE" "alpha" "aaaaaa" "bbbbbb" "topic two")
BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_UPDATE" "alpha" "$CONV2" "waiting"
GOT=$(find_open_conversation "aaaaaa" "bbbbbb" "alpha")
assert_eq "waiting matches" "$CONV2" "$GOT"

# --- Test 6: conversation with different pair is not returned ---
echo ""
echo "Test 6: different pair is not returned"
CONV_AC=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_CREATE" "alpha" "aaaaaa" "cccccc" "ac chat")
GOT=$(find_open_conversation "bbbbbb" "cccccc" "alpha")
assert_eq "bbbbbb/cccccc still empty" "" "$GOT"
GOT=$(find_open_conversation "aaaaaa" "cccccc" "alpha")
assert_eq "aaaaaa/cccccc matches AC" "$CONV_AC" "$GOT"
GOT=$(find_open_conversation "aaaaaa" "bbbbbb" "alpha")
assert_eq "aaaaaa/bbbbbb still CONV2" "$CONV2" "$GOT"

# --- Test 7: multiple open between the same pair → exit 2 + stderr ---
echo ""
echo "Test 7: two open conversations for same pair → exit 2 with stderr"
CONV3=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$CONV_CREATE" "alpha" "aaaaaa" "bbbbbb" "topic three")
set +e
STDERR=$(find_open_conversation "aaaaaa" "bbbbbb" "alpha" 2>&1 >/dev/null)
RC=$?
set -e
assert_eq "exit 2 on multi-match" "2" "$RC"
assert_contains "stderr names both convs" "$CONV2" "$STDERR"
assert_contains "stderr names both convs" "$CONV3" "$STDERR"
assert_contains "stderr has 'Multiple open conversations'" "Multiple open conversations" "$STDERR"

# --- Test 8: nonexistent project → empty, exit 0 ---
echo ""
echo "Test 8: missing project dir → empty, exit 0"
GOT=$(find_open_conversation "aaaaaa" "bbbbbb" "no-such-project")
RC=$?
assert_eq "missing project → empty" "" "$GOT"
assert_eq "missing project → exit 0" "0" "$RC"

print_results

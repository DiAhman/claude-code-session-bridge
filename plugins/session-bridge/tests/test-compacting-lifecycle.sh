#!/usr/bin/env bash
# tests/test-compacting-lifecycle.sh — Tests for compacting lifecycle flag,
# pre-compact.sh / clear-compacting.sh hooks, list-peers display, and
# rate-limited send-message warning.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PRE_COMPACT="$PLUGIN_DIR/scripts/pre-compact.sh"
CLEAR_COMPACTING="$PLUGIN_DIR/scripts/clear-compacting.sh"
LIST_PEERS="$PLUGIN_DIR/scripts/list-peers.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"

echo "=== test-compacting-lifecycle.sh ==="

# --- Test 1: pre-compact.sh sets lifecycle=compacting + lastCompactStart ---
echo ""
echo "Test 1: pre-compact.sh writes lifecycle=compacting and lastCompactStart"
SID1="aaa111"
SDIR1=$(setup_project_session "$BRIDGE_DIR" "proj-pc" "$SID1" "specialist" "Spec One")
assert_json_field "baseline lifecycle is normal" "$SDIR1/manifest.json" '.lifecycle' "normal"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID1" bash "$PRE_COMPACT"
assert_json_field "lifecycle flipped to compacting" "$SDIR1/manifest.json" '.lifecycle' "compacting"
LCS=$(jq -r '.lastCompactStart // ""' "$SDIR1/manifest.json")
assert_not_empty "lastCompactStart recorded" "$LCS"

# --- Test 2: pre-compact.sh exits 0 with no BRIDGE_SESSION_ID ---
echo ""
echo "Test 2: pre-compact.sh is best-effort with no env (exit 0)"
set +e
BRIDGE_DIR="$BRIDGE_DIR" bash "$PRE_COMPACT"
RC=$?
set -e
assert_eq "exit 0 when BRIDGE_SESSION_ID unset" "0" "$RC"

# --- Test 3: pre-compact.sh exits 0 with unknown session ---
echo ""
echo "Test 3: pre-compact.sh is best-effort with unknown session id (exit 0)"
set +e
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="ghost1" bash "$PRE_COMPACT"
RC=$?
set -e
assert_eq "exit 0 when session dir missing" "0" "$RC"

# --- Test 4: clear-compacting.sh flips compacting → normal ---
echo ""
echo "Test 4: clear-compacting.sh resets lifecycle to normal"
# SID1 is still compacting from Test 1
assert_json_field "precondition: still compacting" "$SDIR1/manifest.json" '.lifecycle' "compacting"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID1" bash "$CLEAR_COMPACTING"
assert_json_field "lifecycle is now normal" "$SDIR1/manifest.json" '.lifecycle' "normal"

# --- Test 5: clear-compacting.sh is a no-op when already normal ---
echo ""
echo "Test 5: clear-compacting.sh is a no-op when lifecycle=normal"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID1" bash "$CLEAR_COMPACTING"
assert_json_field "still normal after second call" "$SDIR1/manifest.json" '.lifecycle' "normal"

# --- Test 6: clear-compacting.sh exits 0 with no env ---
echo ""
echo "Test 6: clear-compacting.sh is best-effort with no env (exit 0)"
set +e
BRIDGE_DIR="$BRIDGE_DIR" bash "$CLEAR_COMPACTING"
RC=$?
set -e
assert_eq "exit 0 when BRIDGE_SESSION_ID unset" "0" "$RC"

print_results

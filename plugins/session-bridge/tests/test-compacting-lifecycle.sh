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

# proj-pc needs project.json so list-peers.sh's project-scoped discovery loop
# (which iterates $BRIDGE_DIR/projects/*/project.json) finds it. Task 1's
# setup_project_session helper only fabricates session dirs/manifests, not
# project.json itself — that's project-create.sh's job (same pattern used by
# test-list-peers.sh's Test 4).
BRIDGE_DIR="$BRIDGE_DIR" bash "$PLUGIN_DIR/scripts/project-create.sh" "proj-pc" > /dev/null

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

# --- Test 7: list-peers.sh shows 'active (compacting)' for compacting peer ---
echo ""
echo "Test 7: list-peers.sh displays 'active (compacting)' when lifecycle=compacting"
SID2="bbb222"
SDIR2=$(setup_project_session "$BRIDGE_DIR" "proj-pc" "$SID2" "specialist" "Spec Two")
# Flip SID2 to compacting via the hook to exercise the same code path
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SID2" bash "$PRE_COMPACT"
OUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST_PEERS")
assert_contains "compacting peer shown with suffix" "active (compacting)" "$OUT"
assert_contains "compacting peer session id shown" "$SID2" "$OUT"
# The first peer (SID1) was reset to normal in Test 4 — it should NOT have the suffix.
# Note: list-peers.sh prints fixed-width columns (STATUS is %-20s), so the
# "active" status is followed by column-padding whitespace, not immediately
# by end-of-line — allow trailing [[:space:]]* so the anchor matches the
# real table output while still correctly rejecting "active (compacting)".
echo "$OUT" | grep -E "^[[:space:]]+$SID1[[:space:]].*active[[:space:]]*$" >/dev/null \
  && { echo "  PASS: non-compacting peer shows plain 'active'"; PASS=$((PASS + 1)); } \
  || { echo "  FAIL: non-compacting peer should show plain 'active'"; echo "    output: $OUT"; FAIL=$((FAIL + 1)); }

# --- Test 8: send-message.sh warns to stderr when recipient is compacting ---
echo ""
echo "Test 8: send-message.sh emits rate-limited stderr warning for compacting recipient"
SENDER_ID="ccc333"
TARGET_ID="ddd444"
SENDER_DIR=$(setup_project_session "$BRIDGE_DIR" "proj-pc" "$SENDER_ID" "orchestrator" "Orch")
TARGET_DIR=$(setup_project_session "$BRIDGE_DIR" "proj-pc" "$TARGET_ID" "specialist" "Compactor")
# Flip TARGET to compacting
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$TARGET_ID" bash "$PRE_COMPACT"

# First send: warning expected
STDERR1=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" bash "$SEND_MSG" \
  "$TARGET_ID" ping "hello" 2>&1 >/dev/null)
assert_contains "first send emits compacting warning" "compacting" "$STDERR1"
assert_contains "warning identifies recipient" "$TARGET_ID" "$STDERR1"
assert_file_exists "rate-limit mtime file created" "$SENDER_DIR/.compact-warned-$TARGET_ID"

# --- Test 9: second send within 60s does NOT re-emit warning ---
echo ""
echo "Test 9: send-message.sh suppresses warning within 60s window"
STDERR2=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" bash "$SEND_MSG" \
  "$TARGET_ID" ping "hello again" 2>&1 >/dev/null)
if echo "$STDERR2" | grep -q "compacting"; then
  echo "  FAIL: second send within 60s should not warn (stderr: $STDERR2)"; FAIL=$((FAIL + 1))
else
  echo "  PASS: second send suppressed"; PASS=$((PASS + 1))
fi

# --- Test 10: warning re-emits after rate-limit window expires ---
echo ""
echo "Test 10: send-message.sh re-emits warning when mtime is older than 60s"
# Backdate the rate-limit file by 120 seconds (BSD touch -t for macOS, GNU -d for Linux)
PAST_EPOCH=$(($(date -u +%s) - 120))
touch -d "@$PAST_EPOCH" "$SENDER_DIR/.compact-warned-$TARGET_ID" 2>/dev/null \
  || touch -t "$(date -r "$PAST_EPOCH" +%Y%m%d%H%M.%S 2>/dev/null)" "$SENDER_DIR/.compact-warned-$TARGET_ID"
STDERR3=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" bash "$SEND_MSG" \
  "$TARGET_ID" ping "hello again later" 2>&1 >/dev/null)
assert_contains "third send re-emits warning after rate-limit expiry" "compacting" "$STDERR3"

# --- Test 11: no warning when recipient lifecycle=normal ---
echo ""
echo "Test 11: send-message.sh does not warn when recipient lifecycle=normal"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$TARGET_ID" bash "$CLEAR_COMPACTING"
rm -f "$SENDER_DIR/.compact-warned-$TARGET_ID"
STDERR4=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" bash "$SEND_MSG" \
  "$TARGET_ID" ping "normal recipient" 2>&1 >/dev/null)
if echo "$STDERR4" | grep -q "compacting"; then
  echo "  FAIL: should not warn for non-compacting recipient (stderr: $STDERR4)"; FAIL=$((FAIL + 1))
else
  echo "  PASS: no warning for non-compacting recipient"; PASS=$((PASS + 1))
fi

print_results

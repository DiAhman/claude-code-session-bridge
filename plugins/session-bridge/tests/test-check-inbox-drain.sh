#!/usr/bin/env bash
# tests/test-check-inbox-drain.sh — Tests for check-inbox.sh --drain mode (#27).
#
# Closes the architectural half of the wake-from-cold message-swallow bug:
# --drain fires from SessionStart and surfaces each pending message
# INDIVIDUALLY as an actionable hookSpecificOutput.additionalContext
# injection (hookEventName: SessionStart) — not a collapsed "pending: N"
# summary count (that's --summary-only, which PreCompact still needs since
# it can't consume additionalContext at all — see #28 / task-1-report.md).
#
# Reuses the same claim + archival + EMIT_SUCCESS gating logic as Default
# mode (a24096a / #28): archival to .delivered/ only happens if the
# emission JSON actually printed successfully.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"
CHECK_INBOX="$PLUGIN_DIR/scripts/check-inbox.sh"
CREATE_PROJ="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"
AUTO_JOIN="$PLUGIN_DIR/scripts/auto-join.sh"

kill_watchers() {
  local dir="$1"
  for pidfile in "$dir"/projects/*/sessions/*/watcher.pid; do
    [ -f "$pidfile" ] || continue
    local pid
    pid=$(cat "$pidfile" 2>/dev/null || true)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
}

TEST_TMPDIR=$(mktemp -d)
trap 'kill_watchers "$TEST_TMPDIR/bridge" 2>/dev/null; rm -rf "$TEST_TMPDIR"; kill $(jobs -p) 2>/dev/null || true' EXIT

echo "=== test-check-inbox-drain.sh ==="

# Shared fixture: one project, two sessions (A sends, B receives).
setup_fixture() {
  local proj="$1"
  local d="$TEST_TMPDIR/$proj"
  local bridge="$d/bridge"
  local proj_a="$d/proj-a"
  local proj_b="$d/proj-b"
  mkdir -p "$proj_a" "$proj_b"
  BRIDGE_DIR="$bridge" bash "$CREATE_PROJ" "$proj" > /dev/null
  local sid_a sid_b
  sid_a=$(BRIDGE_DIR="$bridge" PROJECT_DIR="$proj_a" bash "$JOIN" "$proj" --name sender)
  sid_b=$(BRIDGE_DIR="$bridge" PROJECT_DIR="$proj_b" bash "$JOIN" "$proj" --name receiver)
  kill_watchers "$bridge"
  echo "$bridge|$proj_a|$proj_b|$sid_a|$sid_b"
}

# --- Test: no-op when inbox is empty ---
echo ""
echo "Test: drain_is_noop_on_empty_inbox"
IFS='|' read -r BRIDGE PROJ_A PROJ_B SID_A SID_B <<< "$(setup_fixture drain-empty)"
OUTPUT=$(BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ_B" BRIDGE_SESSION_ID="$SID_B" bash "$CHECK_INBOX" --drain)
CONTINUE=$(echo "$OUTPUT" | jq -r '.continue')
HAS_HOOK_SPECIFIC=$(echo "$OUTPUT" | jq 'has("hookSpecificOutput")')
assert_eq "empty inbox: continue is true" "true" "$CONTINUE"
assert_eq "empty inbox: no hookSpecificOutput block emitted" "false" "$HAS_HOOK_SPECIFIC"

# --- Test: single pending message surfaces individually via additionalContext ---
echo ""
echo "Test: drain_surfaces_single_message_as_additionalContext"
IFS='|' read -r BRIDGE PROJ_A PROJ_B SID_A SID_B <<< "$(setup_fixture drain-single)"
BRIDGE_DIR="$BRIDGE" BRIDGE_SESSION_ID="$SID_A" bash "$SEND_MSG" "$SID_B" task-assign "Draft the Q3 brief" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ_B" BRIDGE_SESSION_ID="$SID_B" bash "$CHECK_INBOX" --drain)
EVT=$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.hookEventName // ""')
CTX=$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
HAS_SYS=$(echo "$OUTPUT" | jq 'has("systemMessage")')
assert_eq "single message: hookEventName is SessionStart" "SessionStart" "$EVT"
assert_eq "single message: no top-level systemMessage key" "false" "$HAS_SYS"
assert_contains "single message: additionalContext carries content" "Draft the Q3 brief" "$CTX"
assert_contains "single message: additionalContext carries type" "task-assign" "$CTX"
assert_contains "single message: framed as pre-queued (not a bare count)" "pre-queued" "$CTX"
assert_contains "single message: instructs draining before standby" "standby" "$CTX"

# --- Test: multiple pending messages each surface individually (not collapsed) ---
echo ""
echo "Test: drain_surfaces_each_of_multiple_messages_individually"
IFS='|' read -r BRIDGE PROJ_A PROJ_B SID_A SID_B <<< "$(setup_fixture drain-multi)"
BRIDGE_DIR="$BRIDGE" BRIDGE_SESSION_ID="$SID_A" bash "$SEND_MSG" "$SID_B" task-assign "Marketing brief" > /dev/null
BRIDGE_DIR="$BRIDGE" BRIDGE_SESSION_ID="$SID_A" bash "$SEND_MSG" "$SID_B" query "Legal review status?" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ_B" BRIDGE_SESSION_ID="$SID_B" bash "$CHECK_INBOX" --drain)
CTX=$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "multi: 2 pre-queued message(s) count in header" "2 pre-queued message(s)" "$CTX"
assert_contains "multi: first message content present" "Marketing brief" "$CTX"
assert_contains "multi: second message content present" "Legal review status?" "$CTX"
# Each message keeps its own metadata block — assert both Message ID markers appear.
# additionalContext uses literal \n escape sequences (not real newlines — same
# convention as Default mode), so count substring occurrences, not lines.
MSG_ID_COUNT=$(echo "$CTX" | grep -o "Message ID:" | wc -l | tr -d ' ')
assert_eq "multi: each message has its own Message ID marker" "2" "$MSG_ID_COUNT"

# --- Test: messages archived to .delivered/ after successful drain ---
echo ""
echo "Test: drain_archives_messages_after_successful_emission"
IFS='|' read -r BRIDGE PROJ_A PROJ_B SID_A SID_B <<< "$(setup_fixture drain-archive)"
MSG_ID=$(BRIDGE_DIR="$BRIDGE" BRIDGE_SESSION_ID="$SID_A" bash "$SEND_MSG" "$SID_B" task-assign "archive me")
BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ_B" BRIDGE_SESSION_ID="$SID_B" bash "$CHECK_INBOX" --drain > /dev/null
INBOX_DIR="$BRIDGE/projects/drain-archive/sessions/$SID_B/inbox"
assert_file_exists "drain: message archived to .delivered/" "$INBOX_DIR/.delivered/$MSG_ID.json"
if [ -f "$INBOX_DIR/$MSG_ID.json" ]; then
  echo "  FAIL: message still present in inbox root after successful drain"; FAIL=$((FAIL + 1))
else
  echo "  PASS: message removed from inbox root after successful drain"; PASS=$((PASS + 1))
fi

# --- Test: emission failure prevents archival (same #28 gating, drain mode) ---
echo ""
echo "Test: drain_emission_failure_prevents_archival_side_effect"
IFS='|' read -r BRIDGE PROJ_A PROJ_B SID_A SID_B <<< "$(setup_fixture drain-emit-failure)"
MSG_ID=$(BRIDGE_DIR="$BRIDGE" BRIDGE_SESSION_ID="$SID_A" bash "$SEND_MSG" "$SID_B" task-assign "must not be lost")

REAL_JQ=$(command -v jq)
FAKE_BIN_DIR=$(mktemp -d)
cat > "$FAKE_BIN_DIR/jq" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *hookSpecificOutput*) exit 1 ;;
  esac
done
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$FAKE_BIN_DIR/jq"

set +e
PATH="$FAKE_BIN_DIR:$PATH" BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ_B" BRIDGE_SESSION_ID="$SID_B" bash "$CHECK_INBOX" --drain > /dev/null 2>/dev/null
RC=$?
set -e
rm -rf "$FAKE_BIN_DIR"

INBOX_DIR="$BRIDGE/projects/drain-emit-failure/sessions/$SID_B/inbox"
if [ -f "$INBOX_DIR/.delivered/$MSG_ID.json" ]; then
  echo "  FAIL: message archived to .delivered/ despite failed emission (#28 regression, drain mode)"; FAIL=$((FAIL + 1))
else
  echo "  PASS: message NOT archived when drain emission failed"; PASS=$((PASS + 1))
fi
if [ -f "$INBOX_DIR/$MSG_ID.json" ]; then
  echo "  PASS: message restored to inbox (still deliverable on next check)"; PASS=$((PASS + 1))
  assert_json_field "restored message status is pending" "$INBOX_DIR/$MSG_ID.json" ".status" "pending"
else
  echo "  FAIL: message missing entirely — silently lost on drain emission failure"; FAIL=$((FAIL + 1))
fi
echo "  (script exit code on emission failure: $RC — informational, not asserted)"

# --- Test: SessionStart wiring end-to-end (simulated) ---
# Simulates the real SessionStart hook chain: auto-join.sh (rebinds the
# session identity + restarts daemons) followed by check-inbox.sh --drain
# (surfaces whatever was pre-queued while the session was cold). A message
# sent to B BEFORE this sequence runs must come out the other end as
# actionable additionalContext, proving the two hooks compose correctly.
echo ""
echo "Test: sessionstart_wiring_end_to_end_simulated"
E2E_DIR="$TEST_TMPDIR/e2e"
E2E_BRIDGE="$E2E_DIR/bridge"
E2E_PROJ_A="$E2E_DIR/proj-a"
E2E_PROJ_B="$E2E_DIR/proj-b"
mkdir -p "$E2E_PROJ_A" "$E2E_PROJ_B"
BRIDGE_DIR="$E2E_BRIDGE" bash "$CREATE_PROJ" "e2e-drain" > /dev/null
E2E_SID_A=$(BRIDGE_DIR="$E2E_BRIDGE" PROJECT_DIR="$E2E_PROJ_A" bash "$JOIN" "e2e-drain" --name sender)
E2E_SID_B=$(BRIDGE_DIR="$E2E_BRIDGE" PROJECT_DIR="$E2E_PROJ_B" bash "$JOIN" "e2e-drain" --role specialist --name receiver)
kill_watchers "$E2E_BRIDGE"

# Message queued while B is "cold" (no session running).
BRIDGE_DIR="$E2E_BRIDGE" BRIDGE_SESSION_ID="$E2E_SID_A" bash "$SEND_MSG" "$E2E_SID_B" task-assign "Cold-start directive" > /dev/null

# SessionStart hook 1: auto-join.sh rebinds B's identity from .claude/bridge-role.
AUTO_JOIN_OUTPUT=$(BRIDGE_DIR="$E2E_BRIDGE" PROJECT_DIR="$E2E_PROJ_B" bash "$AUTO_JOIN" 2>/dev/null)
assert_contains "e2e: auto-join reports rejoin" "BRIDGE AUTO-JOINED" "$AUTO_JOIN_OUTPUT"
kill_watchers "$E2E_BRIDGE"

# SessionStart hook 2: check-inbox.sh --drain surfaces the pre-queued message.
DRAIN_OUTPUT=$(BRIDGE_DIR="$E2E_BRIDGE" PROJECT_DIR="$E2E_PROJ_B" BRIDGE_SESSION_ID="$E2E_SID_B" bash "$CHECK_INBOX" --drain)
DRAIN_CTX=$(echo "$DRAIN_OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
DRAIN_EVT=$(echo "$DRAIN_OUTPUT" | jq -r '.hookSpecificOutput.hookEventName // ""')
assert_eq "e2e: drain hookEventName is SessionStart" "SessionStart" "$DRAIN_EVT"
assert_contains "e2e: drain surfaces the pre-queued directive" "Cold-start directive" "$DRAIN_CTX"

print_results

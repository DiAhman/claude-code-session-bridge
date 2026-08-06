#!/usr/bin/env bash
# tests/test-check-inbox-hook-emit.sh — Regression tests for #28: check-inbox.sh
# must inject claimed messages via hookSpecificOutput.additionalContext (reaches
# the model's context) rather than the top-level systemMessage field (terminal
# only). Covers Default mode (UserPromptSubmit + rate-limited PostToolUse),
# Summary-only mode (PreCompact), and the Stop-hook path (unchanged baseline).
#
# Investigation finding (Step 1, recorded in task-1-report.md): PreCompact does
# NOT structurally support hookSpecificOutput.additionalContext in the current
# Claude Code runtime (verified against v2.1.211's decompiled hook-output
# parser: executePreCompactHooks routes through a different executor than
# UserPromptSubmit/PostToolUse/Stop, and that executor never reads
# hookSpecificOutput.additionalContext at all). Summary-only mode therefore
# intentionally KEEPS systemMessage — the two tests that the task brief
# originally proposed asserting additionalContext for Summary-only mode are
# replaced below with tests asserting the correct (systemMessage-retaining)
# fallback behavior instead, per the brief's documented fallback option.
#
# v0.3.4 Task 2 update: the same decompiled-runtime investigation also
# established that PreCompact's hook executor uses raw stdout as literal
# "compaction instructions" and never parses hookSpecificOutput OR reads
# .systemMessage — so the systemMessage envelope above was never reaching
# the model as context either; it reached it as the literal instructions
# blob. --summary-only now emits bare stdout text with no JSON wrapper at
# all. The two Summary-only tests below (originally asserting the
# systemMessage-retaining envelope) were updated accordingly; see
# tests/test-check-inbox-summary-emission.sh for the dedicated coverage of
# the new bare-text shape.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"
CHECK_INBOX="$PLUGIN_DIR/scripts/check-inbox.sh"
CREATE_PROJ="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"

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
trap 'kill_watchers "$TEST_TMPDIR/bridge" 2>/dev/null; rm -rf "$TEST_TMPDIR"' EXIT

echo "=== test-check-inbox-hook-emit.sh ==="

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

# --- test_default_mode_emits_additionalContext_not_systemMessage ---
echo ""
echo "Test: default_mode_emits_additionalContext_not_systemMessage"
IFS='|' read -r BRIDGE PROJ_A PROJ_B SID_A SID_B <<< "$(setup_fixture emit-default)"
BRIDGE_DIR="$BRIDGE" BRIDGE_SESSION_ID="$SID_A" bash "$SEND_MSG" "$SID_B" query "hello via default mode" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ_B" BRIDGE_SESSION_ID="$SID_B" bash "$CHECK_INBOX")
HAS_SYS=$(echo "$OUTPUT" | jq 'has("systemMessage")')
CTX=$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_eq "default mode: no top-level systemMessage key" "false" "$HAS_SYS"
assert_contains "default mode: additionalContext carries message" "hello via default mode" "$CTX"

# --- test_default_mode_output_json_has_hookEventName_matching_env ---
echo ""
echo "Test: default_mode_output_json_has_hookEventName_matching_env"
IFS='|' read -r BRIDGE PROJ_A PROJ_B SID_A SID_B <<< "$(setup_fixture emit-hookname)"
# UserPromptSubmit path — no --rate-limited flag
BRIDGE_DIR="$BRIDGE" BRIDGE_SESSION_ID="$SID_A" bash "$SEND_MSG" "$SID_B" query "ups event" > /dev/null
OUT_UPS=$(BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ_B" BRIDGE_SESSION_ID="$SID_B" bash "$CHECK_INBOX")
EVT_UPS=$(echo "$OUT_UPS" | jq -r '.hookSpecificOutput.hookEventName // ""')
assert_eq "UserPromptSubmit invocation: hookEventName is UserPromptSubmit" "UserPromptSubmit" "$EVT_UPS"

# PostToolUse path — --rate-limited flag (fresh session so no rate-limit window is active)
BRIDGE_DIR="$BRIDGE" BRIDGE_SESSION_ID="$SID_A" bash "$SEND_MSG" "$SID_B" query "post-tool event" > /dev/null
OUT_PTU=$(BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ_B" BRIDGE_SESSION_ID="$SID_B" bash "$CHECK_INBOX" --rate-limited)
EVT_PTU=$(echo "$OUT_PTU" | jq -r '.hookSpecificOutput.hookEventName // ""')
assert_eq "PostToolUse invocation: hookEventName is PostToolUse" "PostToolUse" "$EVT_PTU"

# --- test_summary_only_mode_emits_bare_text_precompact_unsupported ---
# (v0.3.4 Task 2: renamed from
#  test_summary_only_mode_retains_systemMessage_precompact_unsupported. The
#  systemMessage envelope this test used to assert on is gone — PreCompact
#  never parsed it anyway (see file header). Now asserts the replacement
#  bare-text shape instead.)
echo ""
echo "Test: summary_only_mode_emits_bare_text_precompact_unsupported"
IFS='|' read -r BRIDGE PROJ_A PROJ_B SID_A SID_B <<< "$(setup_fixture summary-mode)"
OUTPUT=$(BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ_B" BRIDGE_SESSION_ID="$SID_B" bash "$CHECK_INBOX" --summary-only)
FIRST_BYTE=$(printf '%s' "$OUTPUT" | head -c1)
assert_eq "summary-only mode: output is bare text, not JSON (PreCompact never parsed the envelope)" "false" "$([ "$FIRST_BYTE" = "{" ] && echo true || echo false)"
assert_contains "summary-only mode: bare text has bridge state header" "CLAUDE BRIDGE STATE" "$OUTPUT"

# --- test_summary_only_output_has_no_json_fields_at_all ---
# (v0.3.4 Task 2: renamed from test_summary_only_output_is_valid_continue_json,
#  which asserted continue:true and no hookSpecificOutput block inside a JSON
#  envelope. There's no JSON envelope left to assert fields on — this now
#  locks in that neither field survives as text anywhere in the bare-text
#  output.)
echo ""
echo "Test: summary_only_output_has_no_json_fields_at_all"
if echo "$OUTPUT" | grep -q '"continue"'; then
  echo "  FAIL: bare-text output still contains a \"continue\" JSON field"; FAIL=$((FAIL + 1))
else
  echo "  PASS: bare-text output contains no \"continue\" JSON field"; PASS=$((PASS + 1))
fi
if echo "$OUTPUT" | grep -q '"hookSpecificOutput"'; then
  echo "  FAIL: bare-text output still contains a \"hookSpecificOutput\" JSON field"; FAIL=$((FAIL + 1))
else
  echo "  PASS: bare-text output contains no \"hookSpecificOutput\" JSON field"; PASS=$((PASS + 1))
fi

# --- test_stop_mode_output_unchanged_still_uses_hookSpecificOutput_additionalContext ---
echo ""
echo "Test: stop_mode_output_unchanged_still_uses_hookSpecificOutput_additionalContext"
IFS='|' read -r BRIDGE PROJ_A PROJ_B SID_A SID_B <<< "$(setup_fixture stop-mode)"
BRIDGE_DIR="$BRIDGE" BRIDGE_SESSION_ID="$SID_A" bash "$SEND_MSG" "$SID_B" query "stop hook message" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE" BRIDGE_SESSION_ID="$SID_B" bash "$CHECK_INBOX" --stop-hook)
DECISION=$(echo "$OUTPUT" | jq -r '.decision')
EVT=$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.hookEventName')
CTX=$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.additionalContext')
assert_eq "stop mode: decision is block" "block" "$DECISION"
assert_eq "stop mode: hookEventName is Stop" "Stop" "$EVT"
assert_contains "stop mode: additionalContext carries message" "stop hook message" "$CTX"

# --- test_default_mode_still_archives_delivered_messages ---
echo ""
echo "Test: default_mode_still_archives_delivered_messages"
IFS='|' read -r BRIDGE PROJ_A PROJ_B SID_A SID_B <<< "$(setup_fixture archive-default)"
MSG_ID=$(BRIDGE_DIR="$BRIDGE" BRIDGE_SESSION_ID="$SID_A" bash "$SEND_MSG" "$SID_B" query "archive me")
BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ_B" BRIDGE_SESSION_ID="$SID_B" bash "$CHECK_INBOX" > /dev/null
INBOX_DIR="$BRIDGE/projects/archive-default/sessions/$SID_B/inbox"
assert_file_exists "successful emission: message archived to .delivered/" "$INBOX_DIR/.delivered/$MSG_ID.json"
if [ -f "$INBOX_DIR/$MSG_ID.json" ]; then
  echo "  FAIL: message still present in inbox root after successful emission"; FAIL=$((FAIL + 1))
else
  echo "  PASS: message removed from inbox root after successful emission"; PASS=$((PASS + 1))
fi

# --- test_summary_mode_does_not_archive ---
echo ""
echo "Test: summary_mode_does_not_archive"
IFS='|' read -r BRIDGE PROJ_A PROJ_B SID_A SID_B <<< "$(setup_fixture archive-summary)"
MSG_ID=$(BRIDGE_DIR="$BRIDGE" BRIDGE_SESSION_ID="$SID_A" bash "$SEND_MSG" "$SID_B" query "do not archive me")
BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ_B" BRIDGE_SESSION_ID="$SID_B" bash "$CHECK_INBOX" --summary-only > /dev/null
INBOX_DIR="$BRIDGE/projects/archive-summary/sessions/$SID_B/inbox"
if [ -f "$INBOX_DIR/.delivered/$MSG_ID.json" ]; then
  echo "  FAIL: summary-only mode archived a message it never scanned"; FAIL=$((FAIL + 1))
else
  echo "  PASS: summary-only mode did not archive"; PASS=$((PASS + 1))
fi
assert_json_field "message remains pending after summary-only" "$INBOX_DIR/$MSG_ID.json" ".status" "pending"

# --- test_default_mode_emission_failure_prevents_archival_side_effect ---
# The #28-flagged detection gap: archival must be gated on the emission
# actually reaching the model, not merely on jq printing valid JSON. Simulate
# jq failure for the emission call ONLY (a fake `jq` wrapper that fails when
# invoked with a filter mentioning hookSpecificOutput, and otherwise delegates
# to the real jq — every other call in check-inbox.sh filters on plain message
# fields and never mentions hookSpecificOutput).
echo ""
echo "Test: default_mode_emission_failure_prevents_archival_side_effect"
IFS='|' read -r BRIDGE PROJ_A PROJ_B SID_A SID_B <<< "$(setup_fixture emit-failure)"
MSG_ID=$(BRIDGE_DIR="$BRIDGE" BRIDGE_SESSION_ID="$SID_A" bash "$SEND_MSG" "$SID_B" query "must not be lost")

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
OUTPUT=$(PATH="$FAKE_BIN_DIR:$PATH" BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ_B" BRIDGE_SESSION_ID="$SID_B" bash "$CHECK_INBOX" 2>/dev/null)
RC=$?
set -e
rm -rf "$FAKE_BIN_DIR"

INBOX_DIR="$BRIDGE/projects/emit-failure/sessions/$SID_B/inbox"
if [ -f "$INBOX_DIR/.delivered/$MSG_ID.json" ]; then
  echo "  FAIL: message archived to .delivered/ despite failed emission (#28 detection gap regression)"; FAIL=$((FAIL + 1))
else
  echo "  PASS: message NOT archived when emission failed"; PASS=$((PASS + 1))
fi
if [ -f "$INBOX_DIR/$MSG_ID.json" ]; then
  echo "  PASS: message restored to inbox (still deliverable on next check)"; PASS=$((PASS + 1))
  assert_json_field "restored message status is pending" "$INBOX_DIR/$MSG_ID.json" ".status" "pending"
else
  echo "  FAIL: message missing entirely — silently lost on emission failure"; FAIL=$((FAIL + 1))
fi
echo "  (script exit code on emission failure: $RC — informational, not asserted)"

print_results

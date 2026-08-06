#!/usr/bin/env bash
# tests/test-stale-read-sweep.sh — Tests for the _sweep_stale_read defensive
# fix (#29).
#
# A pre-v0.2.17 cached check-inbox.sh briefly in effect on the running
# plextura orchestrator (2026-07-17 through 2026-07-29, per the Local Plugin
# Cache Quirk) rewrote incoming messages with .status = "read" in-place
# instead of archiving them. Current scan filters only ever look for
# status:"pending", so those fossils sit in inbox/ forever — polluting
# list-inbox.sh --pending and forcing BRIDGE_STANDBY_IGNORE_PENDING=1 to keep
# standby usable.
#
# _sweep_stale_read runs once at scan-loop entry in both check-inbox.sh
# branches and once at bridge-listen.sh startup (before the pending-guard).
# It silently relocates status:"read" files to .delivered/ — no re-injection,
# no stdout/stderr, just the file move (+ an internal _log line).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK_INBOX="$PLUGIN_DIR/scripts/check-inbox.sh"
LISTEN="$PLUGIN_DIR/scripts/bridge-listen.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"; kill $(jobs -p) 2>/dev/null || true' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"

echo "=== test-stale-read-sweep.sh ==="

# Helper: write a v2.0 message JSON directly into an inbox dir with a given
# status. Mirrors write_msg() from test-list-inbox.sh but takes STATUS too,
# since the whole point here is fabricating status:"read" fossils.
write_msg() {
  local INBOX="$1" ID="$2" FROM="$3" TYPE="$4" CONTENT="$5" STATUS="$6"
  local TS
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -n \
    --arg id "$ID" --arg from "$FROM" --arg to "test" \
    --arg type "$TYPE" --arg ts "$TS" --arg content "$CONTENT" --arg status "$STATUS" \
    '{protocolVersion:"2.0", id:$id, conversationId:null, from:$from, to:$to,
      type:$type, timestamp:$ts, status:$status, content:$content, inReplyTo:null,
      metadata:{urgency:"normal", fromProject:"test", fromRole:"specialist"}}' \
    > "$INBOX/$ID.json"
}

# --- Test 1: sweep moves status:"read" files from inbox/*.json to inbox/.delivered/*.json ---
echo ""
echo "Test 1: sweep moves status:read fossil into .delivered/"
setup_project_session "$BRIDGE_DIR" "proj-1" "sess01" >/dev/null
INBOX1="$BRIDGE_DIR/projects/proj-1/sessions/sess01/inbox"
write_msg "$INBOX1" "msg-fossil0000a" "peer01" "query" "FOSSIL-CONTENT-1" "read"
BRIDGE_SESSION_ID="sess01" BRIDGE_DIR="$BRIDGE_DIR" bash "$CHECK_INBOX" >/dev/null
if [ -f "$INBOX1/msg-fossil0000a.json" ]; then
  echo "  FAIL: fossil still sitting in inbox/ at top level"; FAIL=$((FAIL + 1))
else
  echo "  PASS: fossil no longer at inbox/ top level"; PASS=$((PASS + 1))
fi
assert_file_exists "fossil relocated to .delivered/" "$INBOX1/.delivered/msg-fossil0000a.json"
assert_json_field "relocated fossil still has original id" "$INBOX1/.delivered/msg-fossil0000a.json" ".id" "msg-fossil0000a"

# --- Test 2: sweep leaves status:"pending" files untouched ---
echo ""
echo "Test 2: sweep leaves status:pending messages alone (still delivered normally)"
setup_project_session "$BRIDGE_DIR" "proj-2" "sess02" >/dev/null
INBOX2="$BRIDGE_DIR/projects/proj-2/sessions/sess02/inbox"
write_msg "$INBOX2" "msg-fossil0000b" "peer01" "query" "FOSSIL-CONTENT-2" "read"
write_msg "$INBOX2" "msg-live00000b" "peer01" "query" "LIVE-CONTENT-2" "pending"
OUTPUT=$(BRIDGE_SESSION_ID="sess02" BRIDGE_DIR="$BRIDGE_DIR" bash "$CHECK_INBOX")
CTX=$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "pending message content surfaced normally" "LIVE-CONTENT-2" "$CTX"
assert_file_exists "fossil relocated to .delivered/ (untouched by pending scan)" "$INBOX2/.delivered/msg-fossil0000b.json"
assert_file_exists "pending message archived to .delivered/ after normal delivery" "$INBOX2/.delivered/msg-live00000b.json"

# --- Test 3: sweep emits nothing on stdout/stderr (silent operation) ---
echo ""
echo "Test 3: sweep is silent — no fossil content or noise leaks to stdout/stderr"
setup_project_session "$BRIDGE_DIR" "proj-3" "sess03" >/dev/null
INBOX3="$BRIDGE_DIR/projects/proj-3/sessions/sess03/inbox"
write_msg "$INBOX3" "msg-fossil0000c" "peer01" "query" "SILENT-FOSSIL-CONTENT" "read"
OUT_FILE="$TEST_TMPDIR/t3.out"
ERR_FILE="$TEST_TMPDIR/t3.err"
BRIDGE_SESSION_ID="sess03" BRIDGE_DIR="$BRIDGE_DIR" bash "$CHECK_INBOX" >"$OUT_FILE" 2>"$ERR_FILE"
assert_eq "stdout is the plain continue:true response" '{"continue": true}' "$(cat "$OUT_FILE")"
assert_eq "stderr is empty" "" "$(cat "$ERR_FILE")"
if grep -q "SILENT-FOSSIL-CONTENT" "$OUT_FILE" "$ERR_FILE" 2>/dev/null; then
  echo "  FAIL: fossil content leaked to stdout/stderr"; FAIL=$((FAIL + 1))
else
  echo "  PASS: fossil content did not leak to stdout/stderr"; PASS=$((PASS + 1))
fi

# --- Test 4: sweep is idempotent (running twice on the same inbox is safe) ---
echo ""
echo "Test 4: running the sweep twice in a row is safe and non-duplicating"
setup_project_session "$BRIDGE_DIR" "proj-4" "sess04" >/dev/null
INBOX4="$BRIDGE_DIR/projects/proj-4/sessions/sess04/inbox"
write_msg "$INBOX4" "msg-fossil0000d" "peer01" "query" "FOSSIL-CONTENT-4" "read"
BRIDGE_SESSION_ID="sess04" BRIDGE_DIR="$BRIDGE_DIR" bash "$CHECK_INBOX" >/dev/null
OUT_FILE2="$TEST_TMPDIR/t4.out"
set +e
BRIDGE_SESSION_ID="sess04" BRIDGE_DIR="$BRIDGE_DIR" bash "$CHECK_INBOX" >"$OUT_FILE2" 2>"$TEST_TMPDIR/t4.err"
RC=$?
set -e
assert_eq "second run exits 0" "0" "$RC"
assert_eq "second run stdout unchanged (continue:true, nothing new to sweep)" '{"continue": true}' "$(cat "$OUT_FILE2")"
DELIVERED_COUNT=$(find "$INBOX4/.delivered" -maxdepth 1 -name "msg-fossil0000d.json" | wc -l)
assert_eq "exactly one archived copy — no duplication" "1" "$DELIVERED_COUNT"

# --- Test 5: sweep creates .delivered/ if missing ---
echo ""
echo "Test 5: sweep creates .delivered/ when it doesn't already exist"
setup_project_session "$BRIDGE_DIR" "proj-5" "sess05" >/dev/null
INBOX5="$BRIDGE_DIR/projects/proj-5/sessions/sess05/inbox"
write_msg "$INBOX5" "msg-fossil0000e" "peer01" "query" "FOSSIL-CONTENT-5" "read"
if [ -d "$INBOX5/.delivered" ]; then
  echo "  FAIL: .delivered/ unexpectedly pre-exists"; FAIL=$((FAIL + 1))
else
  echo "  PASS: .delivered/ absent before sweep runs"; PASS=$((PASS + 1))
fi
BRIDGE_SESSION_ID="sess05" BRIDGE_DIR="$BRIDGE_DIR" bash "$CHECK_INBOX" >/dev/null
assert_dir_exists ".delivered/ created by sweep" "$INBOX5/.delivered"
assert_file_exists "fossil landed inside newly-created .delivered/" "$INBOX5/.delivered/msg-fossil0000e.json"

# --- Test 6: after sweep, subsequent check-inbox.sh scan sees zero pending messages ---
echo ""
echo "Test 6: check-inbox.sh reports zero pending after fossils are swept"
setup_project_session "$BRIDGE_DIR" "proj-6" "sess06" >/dev/null
INBOX6="$BRIDGE_DIR/projects/proj-6/sessions/sess06/inbox"
write_msg "$INBOX6" "msg-fossil0000f" "peer01" "query" "FOSSIL-CONTENT-6a" "read"
write_msg "$INBOX6" "msg-fossil0000g" "peer01" "query" "FOSSIL-CONTENT-6b" "read"
OUTPUT=$(BRIDGE_SESSION_ID="sess06" BRIDGE_DIR="$BRIDGE_DIR" bash "$CHECK_INBOX")
CONTINUE=$(echo "$OUTPUT" | jq -r '.continue')
HAS_CTX=$(echo "$OUTPUT" | jq 'has("hookSpecificOutput")')
assert_eq "continue is true" "true" "$CONTINUE"
assert_eq "no hookSpecificOutput — nothing was ever pending" "false" "$HAS_CTX"

# --- Test 7: after sweep, bridge-listen.sh doesn't block/refuse on the swept messages ---
echo ""
echo "Test 7: bridge-listen.sh pending-guard does not trip on fossils alone"
setup_project_session "$BRIDGE_DIR" "proj-7" "sess07" >/dev/null
INBOX7="$BRIDGE_DIR/projects/proj-7/sessions/sess07/inbox"
write_msg "$INBOX7" "msg-fossil0000h" "peer01" "query" "FOSSIL-CONTENT-7" "read"
OUT_FILE7="$TEST_TMPDIR/t7.out"
set +e
BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "sess07" 2 >"$OUT_FILE7" 2>/dev/null
RC7=$?
set -e
assert_eq "listener exits 1 (timeout, not refusal)" "1" "$RC7"
assert_eq "BRIDGE_STATUS=timeout, not pending_messages" "BRIDGE_STATUS=timeout" "$(head -1 "$OUT_FILE7")"
assert_file_exists "fossil relocated to .delivered/ by the listener's sweep" "$INBOX7/.delivered/msg-fossil0000h.json"

# --- Test 8: sweep does NOT re-inject content (empty output, no hookSpecificOutput) ---
echo ""
echo "Test 8: swept fossil content never appears in any hook output"
setup_project_session "$BRIDGE_DIR" "proj-8" "sess08" >/dev/null
INBOX8="$BRIDGE_DIR/projects/proj-8/sessions/sess08/inbox"
write_msg "$INBOX8" "msg-fossil0000i" "peer01" "query" "NEVER-REINJECT-CONTENT" "read"
OUTPUT=$(BRIDGE_SESSION_ID="sess08" BRIDGE_DIR="$BRIDGE_DIR" bash "$CHECK_INBOX")
if echo "$OUTPUT" | grep -q "NEVER-REINJECT-CONTENT"; then
  echo "  FAIL: fossil content re-injected into hook output"; FAIL=$((FAIL + 1))
else
  echo "  PASS: fossil content absent from hook output"; PASS=$((PASS + 1))
fi
HAS_CTX8=$(echo "$OUTPUT" | jq 'has("hookSpecificOutput")')
assert_eq "no hookSpecificOutput block for a fossil-only inbox" "false" "$HAS_CTX8"
# Also verify --drain mode (SessionStart path) doesn't re-inject either.
setup_project_session "$BRIDGE_DIR" "proj-8b" "sess08b" >/dev/null
INBOX8B="$BRIDGE_DIR/projects/proj-8b/sessions/sess08b/inbox"
write_msg "$INBOX8B" "msg-fossil0000j" "peer01" "query" "NEVER-REINJECT-DRAIN" "read"
OUTPUT_DRAIN=$(BRIDGE_SESSION_ID="sess08b" BRIDGE_DIR="$BRIDGE_DIR" bash "$CHECK_INBOX" --drain)
if echo "$OUTPUT_DRAIN" | grep -q "NEVER-REINJECT-DRAIN"; then
  echo "  FAIL: fossil content re-injected via --drain"; FAIL=$((FAIL + 1))
else
  echo "  PASS: fossil content absent from --drain output"; PASS=$((PASS + 1))
fi

# ===================================================================
# Step 5 — pending-guard interaction: N status:read + M status:pending
# ===================================================================
echo ""
echo "--- pending-guard interaction (bridge-listen.sh) ---"

# --- Test 9: N read + M=0 pending — guard does NOT trip, fossils still swept ---
echo ""
echo "Test 9: N=2 read fossils, M=0 pending — guard does not trip"
setup_project_session "$BRIDGE_DIR" "proj-9" "sess09" >/dev/null
INBOX9="$BRIDGE_DIR/projects/proj-9/sessions/sess09/inbox"
write_msg "$INBOX9" "msg-fossil0000k" "peer01" "query" "FOSSIL-9-A" "read"
write_msg "$INBOX9" "msg-fossil0000l" "peer01" "query" "FOSSIL-9-B" "read"
OUT_FILE9="$TEST_TMPDIR/t9.out"
set +e
BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "sess09" 2 >"$OUT_FILE9" 2>/dev/null
RC9=$?
set -e
assert_eq "N=2,M=0: exit code is 1 (timeout, not refusal)" "1" "$RC9"
assert_eq "N=2,M=0: BRIDGE_STATUS=timeout" "BRIDGE_STATUS=timeout" "$(head -1 "$OUT_FILE9")"
DELIVERED9=$(find "$INBOX9/.delivered" -maxdepth 1 -name "*.json" 2>/dev/null | wc -l)
assert_eq "N=2,M=0: both fossils swept to .delivered/" "2" "$DELIVERED9"

# --- Test 10: N read + M>0 pending — guard DOES trip, on M only ---
echo ""
echo "Test 10: N=2 read fossils, M=1 pending — guard trips (pending_messages)"
setup_project_session "$BRIDGE_DIR" "proj-10" "sess10" >/dev/null
INBOX10="$BRIDGE_DIR/projects/proj-10/sessions/sess10/inbox"
write_msg "$INBOX10" "msg-fossil0000m" "peer01" "query" "FOSSIL-10-A" "read"
write_msg "$INBOX10" "msg-fossil0000n" "peer01" "query" "FOSSIL-10-B" "read"
write_msg "$INBOX10" "msg-live0000010" "peer01" "query" "LIVE-10" "pending"
OUT_FILE10="$TEST_TMPDIR/t10.out"
ERR_FILE10="$TEST_TMPDIR/t10.err"
set +e
BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "sess10" 5 >"$OUT_FILE10" 2>"$ERR_FILE10"
RC10=$?
set -e
assert_eq "N=2,M=1: exit code is 1 (refused)" "1" "$RC10"
assert_eq "N=2,M=1: BRIDGE_STATUS=pending_messages" "BRIDGE_STATUS=pending_messages" "$(head -1 "$OUT_FILE10")"
assert_contains "N=2,M=1: stderr reports exactly 1 pre-queued message (not 3)" "1 pre-queued message" "$(cat "$ERR_FILE10")"
DELIVERED10=$(find "$INBOX10/.delivered" -maxdepth 1 -name "*.json" 2>/dev/null | wc -l)
assert_eq "N=2,M=1: both fossils already swept before the guard tripped" "2" "$DELIVERED10"
assert_file_exists "N=2,M=1: pending message still sitting untouched in inbox" "$INBOX10/msg-live0000010.json"
STILL_PENDING_STATUS=$(jq -r '.status' "$INBOX10/msg-live0000010.json")
assert_eq "N=2,M=1: pending message status unchanged (never claimed)" "pending" "$STILL_PENDING_STATUS"

print_results

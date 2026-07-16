#!/usr/bin/env bash
# tests/test-list-inbox.sh — Tests for scripts/list-inbox.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIST_INBOX="$PLUGIN_DIR/scripts/list-inbox.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"

echo "=== test-list-inbox.sh ==="

# Helper: write a v2.0 pending message JSON into an inbox dir
write_msg() {
  local INBOX="$1" ID="$2" FROM="$3" TYPE="$4" CONTENT="$5" TIMESTAMP="$6"
  jq -n \
    --arg id "$ID" --arg from "$FROM" --arg to "test" \
    --arg type "$TYPE" --arg ts "$TIMESTAMP" --arg content "$CONTENT" \
    '{protocolVersion:"2.0", id:$id, conversationId:null, from:$from, to:$to,
      type:$type, timestamp:$ts, status:"pending", content:$content, inReplyTo:null,
      metadata:{urgency:"normal", fromProject:"test", fromRole:"specialist"}}' \
    > "$INBOX/$ID.json"
}

# --- Test 1: Empty inbox prints "No messages." ---
echo ""
echo "Test 1: Empty inbox prints 'No messages.'"
setup_project_session "$BRIDGE_DIR" "proj-empty" "abc111" >/dev/null
OUTPUT=$(BRIDGE_SESSION_ID="abc111" BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST_INBOX")
assert_contains "empty inbox message" "No messages." "$OUTPUT"

# --- Test 2: Pending messages appear in the default table ---
echo ""
echo "Test 2: Pending messages appear in table with id/from/type/subject"
setup_project_session "$BRIDGE_DIR" "proj-a" "abc222" >/dev/null
INBOX2="$BRIDGE_DIR/projects/proj-a/sessions/abc222/inbox"
NOW_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
write_msg "$INBOX2" "msg-aaa111111111" "xyz999" "query" "How do I fix JWT?" "$NOW_TS"
write_msg "$INBOX2" "msg-bbb222222222" "xyz999" "task-assign" "Migrate to v2" "$NOW_TS"
OUTPUT=$(BRIDGE_SESSION_ID="abc222" BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST_INBOX")
assert_contains "lists msg-aaa" "msg-aaa111111111" "$OUTPUT"
assert_contains "lists msg-bbb" "msg-bbb222222222" "$OUTPUT"
assert_contains "shows query type" "query" "$OUTPUT"
assert_contains "shows subject from content" "How do I fix JWT" "$OUTPUT"
assert_contains "table header has ID col" "ID" "$OUTPUT"
assert_contains "table header has SUBJECT col" "SUBJECT" "$OUTPUT"

# --- Test 3: --delivered shows only the .delivered/ directory ---
echo ""
echo "Test 3: --delivered shows .delivered/ messages and excludes pending"
mkdir -p "$INBOX2/.delivered"
write_msg "$INBOX2/.delivered" "msg-ccc333333333" "xyz999" "response" "Done — see PR #42" "$NOW_TS"
OUTPUT=$(BRIDGE_SESSION_ID="abc222" BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST_INBOX" --delivered)
assert_contains "delivered shows ccc" "msg-ccc333333333" "$OUTPUT"
if echo "$OUTPUT" | grep -q "msg-aaa111111111"; then
  echo "  FAIL: --delivered leaked pending message"; FAIL=$((FAIL + 1))
else
  echo "  PASS: --delivered excludes pending"; PASS=$((PASS + 1))
fi

# --- Test 4: --all shows both pending and delivered ---
echo ""
echo "Test 4: --all shows both pending and delivered"
OUTPUT=$(BRIDGE_SESSION_ID="abc222" BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST_INBOX" --all)
assert_contains "all includes pending aaa" "msg-aaa111111111" "$OUTPUT"
assert_contains "all includes delivered ccc" "msg-ccc333333333" "$OUTPUT"

# --- Test 5: --json emits a parseable JSON array with required fields ---
echo ""
echo "Test 5: --json emits a JSON array of {id, from, type, status, age, subject}"
OUTPUT=$(BRIDGE_SESSION_ID="abc222" BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST_INBOX" --all --json)
if echo "$OUTPUT" | jq . >/dev/null 2>&1; then
  echo "  PASS: output parses as JSON"; PASS=$((PASS + 1))
else
  echo "  FAIL: output is not valid JSON"; FAIL=$((FAIL + 1))
fi
FIRST_ID=$(echo "$OUTPUT" | jq -r '.[0].id')
assert_contains "first json record has msg- prefix id" "msg-" "$FIRST_ID"
HAS_ID=$(echo "$OUTPUT" | jq -r '.[0] | has("id")')
HAS_FROM=$(echo "$OUTPUT" | jq -r '.[0] | has("from")')
HAS_TYPE=$(echo "$OUTPUT" | jq -r '.[0] | has("type")')
HAS_STATUS=$(echo "$OUTPUT" | jq -r '.[0] | has("status")')
HAS_AGE=$(echo "$OUTPUT" | jq -r '.[0] | has("age")')
HAS_SUBJECT=$(echo "$OUTPUT" | jq -r '.[0] | has("subject")')
assert_eq "json has id" "true" "$HAS_ID"
assert_eq "json has from" "true" "$HAS_FROM"
assert_eq "json has type" "true" "$HAS_TYPE"
assert_eq "json has status" "true" "$HAS_STATUS"
assert_eq "json has age" "true" "$HAS_AGE"
assert_eq "json has subject" "true" "$HAS_SUBJECT"

# --- Test 6: --since DURATION filters out older messages ---
echo ""
echo "Test 6: --since 1h excludes messages older than 1 hour"
setup_project_session "$BRIDGE_DIR" "proj-b" "def444" >/dev/null
INBOX3="$BRIDGE_DIR/projects/proj-b/sessions/def444/inbox"
NOW_EPOCH=$(date -u +%s)
RECENT_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
OLD_EPOCH=$((NOW_EPOCH - 7200))  # 2 hours old
OLD_TS=$(date -u -r "$OLD_EPOCH" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -d "@$OLD_EPOCH" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
write_msg "$INBOX3" "msg-recent11111" "p1" "query" "fresh" "$RECENT_TS"
write_msg "$INBOX3" "msg-ancient1111" "p1" "query" "stale" "$OLD_TS"
OUTPUT=$(BRIDGE_SESSION_ID="def444" BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST_INBOX" --since 1h)
assert_contains "since=1h keeps recent" "msg-recent11111" "$OUTPUT"
if echo "$OUTPUT" | grep -q "msg-ancient1111"; then
  echo "  FAIL: --since 1h leaked 2h-old message"; FAIL=$((FAIL + 1))
else
  echo "  PASS: --since 1h excludes 2h-old message"; PASS=$((PASS + 1))
fi

# --- Test 7: --limit N truncates the result list ---
echo ""
echo "Test 7: --limit 1 returns only one record (json mode for exact count)"
OUTPUT=$(BRIDGE_SESSION_ID="abc222" BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST_INBOX" --all --limit 1 --json)
COUNT=$(echo "$OUTPUT" | jq 'length')
assert_eq "json array length is 1" "1" "$COUNT"

# --- Test 8: same-project peer can read another session's inbox ---
echo ""
echo "Test 8: same-project peer can read another session's inbox"
setup_project_session "$BRIDGE_DIR" "proj-x" "alice1" >/dev/null
setup_project_session "$BRIDGE_DIR" "proj-x" "bob222" >/dev/null
INBOX_BOB="$BRIDGE_DIR/projects/proj-x/sessions/bob222/inbox"
write_msg "$INBOX_BOB" "msg-peerread111" "alice1" "query" "ping" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
OUTPUT=$(BRIDGE_SESSION_ID="alice1" BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST_INBOX" "bob222")
assert_contains "same-project peer read shows msg" "msg-peerread111" "$OUTPUT"

# --- Test 9: cross-project caller is blocked by assert_same_project ---
echo ""
echo "Test 9: cross-project caller is denied (nonzero exit + no message id leaked)"
setup_project_session "$BRIDGE_DIR" "proj-y" "eve333" >/dev/null
CROSS_OUT=$(BRIDGE_SESSION_ID="eve333" BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST_INBOX" "bob222" 2>&1 || true)
CROSS_RC=0
BRIDGE_SESSION_ID="eve333" BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST_INBOX" "bob222" >/dev/null 2>&1 || CROSS_RC=$?
if [ "$CROSS_RC" -ne 0 ]; then
  echo "  PASS: cross-project exits nonzero"; PASS=$((PASS + 1))
else
  echo "  FAIL: cross-project should exit nonzero"; FAIL=$((FAIL + 1))
fi
if echo "$CROSS_OUT" | grep -q "msg-peerread111"; then
  echo "  FAIL: cross-project leaked msg-peerread111"; FAIL=$((FAIL + 1))
else
  echo "  PASS: cross-project did not leak target inbox content"; PASS=$((PASS + 1))
fi

# --- Test 10: unknown flag exits nonzero with stderr error ---
echo ""
echo "Test 10: unknown --flag exits nonzero"
setup_project_session "$BRIDGE_DIR" "proj-flags" "flag111" >/dev/null
RC=0
ERR=$(BRIDGE_SESSION_ID="flag111" BRIDGE_DIR="$BRIDGE_DIR" \
  bash "$LIST_INBOX" --bogus-flag 2>&1 >/dev/null) || RC=$?
if [ "$RC" -ne 0 ]; then
  echo "  PASS: --bogus-flag exits nonzero"; PASS=$((PASS + 1))
else
  echo "  FAIL: --bogus-flag should exit nonzero"; FAIL=$((FAIL + 1))
fi
assert_contains "stderr names the unknown flag" "--bogus-flag" "$ERR"

# --- Test 11: --since with garbage duration exits nonzero ---
echo ""
echo "Test 11: --since with non-parseable duration exits nonzero"
RC=0
ERR=$(BRIDGE_SESSION_ID="flag111" BRIDGE_DIR="$BRIDGE_DIR" \
  bash "$LIST_INBOX" --since "yesterday" 2>&1 >/dev/null) || RC=$?
if [ "$RC" -ne 0 ]; then
  echo "  PASS: --since yesterday exits nonzero"; PASS=$((PASS + 1))
else
  echo "  FAIL: --since yesterday should exit nonzero"; FAIL=$((FAIL + 1))
fi
assert_contains "stderr mentions invalid duration" "invalid --since" "$ERR"

# --- Test 12: bare integer --since is treated as seconds ---
echo ""
echo "Test 12: --since 60 (bare integer) is interpreted as seconds"
setup_project_session "$BRIDGE_DIR" "proj-secs" "sec111" >/dev/null
INBOX_S="$BRIDGE_DIR/projects/proj-secs/sessions/sec111/inbox"
NOW_EPOCH=$(date -u +%s)
RECENT_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TOO_OLD_EPOCH=$((NOW_EPOCH - 120))  # 2 minutes old
TOO_OLD_TS=$(date -u -r "$TOO_OLD_EPOCH" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -d "@$TOO_OLD_EPOCH" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
write_msg "$INBOX_S" "msg-secrecent11" "p" "ping" "fresh" "$RECENT_TS"
write_msg "$INBOX_S" "msg-sectooold11" "p" "ping" "stale" "$TOO_OLD_TS"
OUTPUT=$(BRIDGE_SESSION_ID="sec111" BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST_INBOX" --since 60)
assert_contains "bare-int --since keeps recent" "msg-secrecent11" "$OUTPUT"
if echo "$OUTPUT" | grep -q "msg-sectooold11"; then
  echo "  FAIL: --since 60 leaked 2min-old message"; FAIL=$((FAIL + 1))
else
  echo "  PASS: --since 60 excludes 2min-old message"; PASS=$((PASS + 1))
fi

print_results

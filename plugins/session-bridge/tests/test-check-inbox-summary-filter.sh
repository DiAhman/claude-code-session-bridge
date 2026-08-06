#!/usr/bin/env bash
# tests/test-check-inbox-summary-filter.sh — v0.3.3 Task 3: --stale-conv-days N
# filter on check-inbox.sh --summary-only conversation enumeration.
#
# Field motivation (v0.3.2 SDD ledger): the running plextura-suite accumulated
# 1,205 conversation files (343 "waiting") over time; --summary-only enumerated
# every non-resolved one on every PreCompact, dominating injected context.
# This filter skips conversations whose activity timestamp is older than N
# days (default 30, 0 disables) so the PreCompact blob stays proportional to
# recent activity rather than total lifetime history.
#
# Schema note: the conversation schema (conversation-create.sh) has no
# `.lastActivity` field today — only `.createdAt` (set once at creation) and
# `.resolvedAt`. The implementation reads
# `.lastActivity // .createdAt // "1970-01-01T00:00:00Z"` so today's
# conversations (which only ever carry createdAt) are filtered on a real,
# meaningful timestamp instead of always falling through to the epoch-0
# safety net — which would make every existing conversation stale-by-default
# and defeat "most recently waiting conversations stay visible" from the
# task brief. .lastActivity is read first so a future feature that starts
# maintaining it is honored automatically (additive, forward compatible).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK_INBOX="$PLUGIN_DIR/scripts/check-inbox.sh"
CREATE_PROJ="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"
CONV_CREATE="$PLUGIN_DIR/scripts/conversation-create.sh"
SEND_MSG="$PLUGIN_DIR/scripts/send-message.sh"

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

echo "=== test-check-inbox-summary-filter.sh ==="

# days_ago_iso N — ISO 8601 UTC timestamp N days in the past (GNU/BSD compatible).
days_ago_iso() {
  local n="$1"
  date -u -d "$n days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-"${n}"d +"%Y-%m-%dT%H:%M:%SZ"
}

# backdate_conv <conv-file> <iso-timestamp> — rewrite createdAt to simulate age.
backdate_conv() {
  local file="$1" ts="$2" tmp
  tmp=$(mktemp "${file}.XXXXXX")
  jq --arg ts "$ts" '.createdAt = $ts' "$file" > "$tmp" && mv "$tmp" "$file"
}

# setup_fixture <name> — bridge dir with one project, one joined (fresh-heartbeat)
# session. Echoes "bridge|project_dir|session_id".
setup_fixture() {
  local proj="$1"
  local d="$TEST_TMPDIR/$proj"
  local bridge="$d/bridge"
  local proj_dir="$d/proj-a"
  mkdir -p "$proj_dir"
  BRIDGE_DIR="$bridge" bash "$CREATE_PROJ" "$proj" > /dev/null
  local sid
  sid=$(BRIDGE_DIR="$bridge" PROJECT_DIR="$proj_dir" bash "$JOIN" "$proj" --name solo)
  kill_watchers "$bridge"
  echo "$bridge|$proj_dir|$sid"
}

# --- Test: default_filter_excludes_conv_older_than_30_days ---
echo ""
echo "Test: default_filter_excludes_conv_older_than_30_days"
IFS='|' read -r BRIDGE PROJ SID <<< "$(setup_fixture default-exclude)"
CONV_ID=$(BRIDGE_DIR="$BRIDGE" bash "$CONV_CREATE" "default-exclude" "$SID" "peer-x" "Old stale thread")
CONV_FILE="$BRIDGE/projects/default-exclude/conversations/$CONV_ID.json"
backdate_conv "$CONV_FILE" "$(days_ago_iso 40)"
OUTPUT=$(BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ" BRIDGE_SESSION_ID="$SID" bash "$CHECK_INBOX" --summary-only)
SYSTEM_MSG="$OUTPUT"
if echo "$SYSTEM_MSG" | grep -q "Old stale thread"; then
  echo "  FAIL: 40-day-old conversation appeared in default-window summary"; FAIL=$((FAIL + 1))
else
  echo "  PASS: 40-day-old conversation excluded from default-window summary"; PASS=$((PASS + 1))
fi

# --- Test: default_filter_includes_conv_within_30_days ---
echo ""
echo "Test: default_filter_includes_conv_within_30_days"
IFS='|' read -r BRIDGE PROJ SID <<< "$(setup_fixture default-include)"
CONV_ID=$(BRIDGE_DIR="$BRIDGE" bash "$CONV_CREATE" "default-include" "$SID" "peer-x" "Fresh active thread")
CONV_FILE="$BRIDGE/projects/default-include/conversations/$CONV_ID.json"
backdate_conv "$CONV_FILE" "$(days_ago_iso 5)"
OUTPUT=$(BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ" BRIDGE_SESSION_ID="$SID" bash "$CHECK_INBOX" --summary-only)
SYSTEM_MSG="$OUTPUT"
assert_contains "5-day-old conversation included in default-window summary" "Fresh active thread" "$SYSTEM_MSG"

# --- Test: custom_stale_conv_days_60_extends_window ---
echo ""
echo "Test: custom_stale_conv_days_60_extends_window"
IFS='|' read -r BRIDGE PROJ SID <<< "$(setup_fixture custom-60)"
CONV_ID=$(BRIDGE_DIR="$BRIDGE" bash "$CONV_CREATE" "custom-60" "$SID" "peer-x" "Forty day old thread")
CONV_FILE="$BRIDGE/projects/custom-60/conversations/$CONV_ID.json"
backdate_conv "$CONV_FILE" "$(days_ago_iso 40)"
# Sanity check: default window (30d) excludes a 40-day-old conversation.
OUTPUT_DEFAULT=$(BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ" BRIDGE_SESSION_ID="$SID" bash "$CHECK_INBOX" --summary-only)
SYS_DEFAULT="$OUTPUT_DEFAULT"
if echo "$SYS_DEFAULT" | grep -q "Forty day old thread"; then
  echo "  FAIL: sanity check — 40-day-old conversation should be excluded under default 30d window"; FAIL=$((FAIL + 1))
else
  echo "  PASS: sanity check — 40-day-old conversation excluded under default 30d window"; PASS=$((PASS + 1))
fi
OUTPUT_60=$(BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ" BRIDGE_SESSION_ID="$SID" bash "$CHECK_INBOX" --summary-only --stale-conv-days 60)
SYS_60="$OUTPUT_60"
assert_contains "--stale-conv-days 60 extends window to include 40-day-old conversation" "Forty day old thread" "$SYS_60"

# --- Test: stale_conv_days_zero_disables_filter ---
echo ""
echo "Test: stale_conv_days_zero_disables_filter"
IFS='|' read -r BRIDGE PROJ SID <<< "$(setup_fixture zero-disable)"
CONV_ID=$(BRIDGE_DIR="$BRIDGE" bash "$CONV_CREATE" "zero-disable" "$SID" "peer-x" "Ancient thread")
CONV_FILE="$BRIDGE/projects/zero-disable/conversations/$CONV_ID.json"
backdate_conv "$CONV_FILE" "$(days_ago_iso 400)"
OUTPUT=$(BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ" BRIDGE_SESSION_ID="$SID" bash "$CHECK_INBOX" --summary-only --stale-conv-days 0)
SYSTEM_MSG="$OUTPUT"
assert_contains "--stale-conv-days 0 disables filtering entirely (400-day-old conversation shown)" "Ancient thread" "$SYSTEM_MSG"

# --- Test: filter_only_applies_to_summary_only_mode ---
echo ""
echo "Test: filter_only_applies_to_summary_only_mode"
# Default (message-scan) mode has no concept of conversation staleness — it
# must keep surfacing pending inbox messages regardless of how old the
# conversation they belong to is, and regardless of any --stale-conv-days
# setting (default mode doesn't even consume the value; it's summary-only-only).
D="$TEST_TMPDIR/mode-scope"
BRIDGE="$D/bridge"
PROJ_A="$D/proj-a"; PROJ_B="$D/proj-b"
mkdir -p "$PROJ_A" "$PROJ_B"
BRIDGE_DIR="$BRIDGE" bash "$CREATE_PROJ" "mode-scope" > /dev/null
SID_A=$(BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ_A" bash "$JOIN" "mode-scope" --name sender)
SID_B=$(BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ_B" bash "$JOIN" "mode-scope" --name receiver)
kill_watchers "$BRIDGE"
CONV_ID=$(BRIDGE_DIR="$BRIDGE" bash "$CONV_CREATE" "mode-scope" "$SID_A" "$SID_B" "Old thread carrying a live message")
CONV_FILE="$BRIDGE/projects/mode-scope/conversations/$CONV_ID.json"
backdate_conv "$CONV_FILE" "$(days_ago_iso 400)"
BRIDGE_DIR="$BRIDGE" BRIDGE_SESSION_ID="$SID_A" bash "$SEND_MSG" "$SID_B" query "still deliver me" --conversation "$CONV_ID" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ_B" BRIDGE_SESSION_ID="$SID_B" bash "$CHECK_INBOX" --stale-conv-days 1)
CTX=$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "default mode delivers pending message despite ancient conversation + tight --stale-conv-days" "still deliver me" "$CTX"

# --- Test: summary_still_lists_pending_messages_even_if_all_conv_stale ---
echo ""
echo "Test: summary_still_lists_pending_messages_even_if_all_conv_stale"
# Summary-only mode itself never enumerates inbox messages (only sessions +
# conversations — see check-inbox.sh's Summary-only block; PreCompact only
# gets bare summary text on stdout, not the message-carrying
# additionalContext path). So "pending" here means: when every conversation
# is filtered out as stale, the summary must still degrade gracefully —
# exit 0, session roster intact — rather than silently break. Reshaping
# summary-only to surface actual inbox-message counts is out of scope for
# this task (flagged as a v0.3.4 follow-up per the Task 1 investigation /
# task-3 brief).
#
# v0.3.4 Task 2 note: --summary-only used to wrap this in a JSON envelope
# with a `continue: true` field; that assertion is gone now that the
# emission is bare text with no such field (see
# test-check-inbox-summary-emission.sh for the dedicated exit-code check).
IFS='|' read -r BRIDGE PROJ SID <<< "$(setup_fixture all-stale)"
CONV_ID=$(BRIDGE_DIR="$BRIDGE" bash "$CONV_CREATE" "all-stale" "$SID" "peer-x" "Only thread, very old")
CONV_FILE="$BRIDGE/projects/all-stale/conversations/$CONV_ID.json"
backdate_conv "$CONV_FILE" "$(days_ago_iso 400)"
OUTPUT=$(BRIDGE_DIR="$BRIDGE" PROJECT_DIR="$PROJ" BRIDGE_SESSION_ID="$SID" bash "$CHECK_INBOX" --summary-only)
SYSTEM_MSG="$OUTPUT"
assert_contains "all-conversations-stale summary: still reports session roster" "$SID" "$SYSTEM_MSG"
if echo "$SYSTEM_MSG" | grep -q "Only thread, very old"; then
  echo "  FAIL: stale conversation leaked into summary despite exceeding default window"; FAIL=$((FAIL + 1))
else
  echo "  PASS: stale conversation correctly absent from summary when fully filtered"; PASS=$((PASS + 1))
fi

print_results

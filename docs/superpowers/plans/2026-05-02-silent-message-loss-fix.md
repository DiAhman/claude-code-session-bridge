# Silent Message Loss Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop silent inbox-message loss reported in DiAhman/claude-code-session-bridge#17 by adding observability to `check-inbox.sh`, archiving delivered messages instead of deleting, and closing the listener's scan-then-watch startup race.

**Architecture:** Three coupled but minimal changes to the existing scripts. (1) `check-inbox.sh` gains a shared `_log()` writing to the same `bridge-listen.log` so both consumers leave a trail. (2) Both consumers replace immediate `rm -f` of claimed messages with `mv` into a per-inbox `.delivered/` archive directory; `cleanup.sh` prunes archive entries older than 24 hours. (3) `bridge-listen.sh` arms `inotifywait` *before* scanning so any file written during the scan is queued by the watcher and surfaces on the next loop iteration, eliminating the startup-window blind spot.

**Tech Stack:** bash, jq, inotifywait/fswatch, atomic-rename file-based queues, the existing 353-test bash test suite under `plugins/session-bridge/tests/`.

---

## File Structure

This plan touches the existing scripts and tests; no new top-level files are created. New runtime artifacts (the `.delivered/` archive directory) are created on demand inside each session's inbox.

**Modify:**
- `plugins/session-bridge/scripts/check-inbox.sh` — add `_log()`, log claim/output/restore, archive instead of delete
- `plugins/session-bridge/scripts/bridge-listen.sh` — invert scan/watch order, archive instead of delete
- `plugins/session-bridge/scripts/cleanup.sh` — prune `.delivered/` entries >24h old
- `plugins/session-bridge/tests/test-check-inbox.sh` — update Test 3 (deletion → archive); add log + archive tests
- `plugins/session-bridge/tests/test-bridge-listen.sh` — add archive + race-tolerance tests
- `plugins/session-bridge/tests/test-cleanup.sh` — add `.delivered/` prune test
- `plugins/session-bridge/.claude-plugin/plugin.json` — version bump 0.2.21 → 0.2.22
- `CLAUDE.md` — update v2 Key Concepts to mention archive + shared log

**Runtime artifacts (created on demand, not in repo):**
- `<session>/inbox/.delivered/msg-<id>.json` — archive of delivered messages, pruned after 24 h
- `<session>/bridge-listen.log` — now also contains entries from `check-inbox.sh`

---

## Task 1: Add `_log()` to `check-inbox.sh` (failing test first)

**Files:**
- Modify: `plugins/session-bridge/scripts/check-inbox.sh`
- Modify: `plugins/session-bridge/tests/test-check-inbox.sh`

This task introduces logging plumbing only. No behavior change yet; just verify a log line lands.

- [ ] **Step 1: Write the failing test**

Add to the bottom of `plugins/session-bridge/tests/test-check-inbox.sh`, before `print_results`:

```bash
# --- Test L1: check-inbox.sh writes a CLAIM log entry ---
echo ""
echo "Test L1: check-inbox.sh logs CLAIM entries to bridge-listen.log"
# Send a message from A to TARGET so check-inbox has something to claim
MSG_ID_L1=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SOURCE_ID" \
  bash "$SEND_MSG" "$TARGET_ID" query "log-test message" 2>/dev/null)
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$TARGET_ID" \
  bash "$CHECK_INBOX" >/dev/null 2>&1
LOG_FILE="$BRIDGE_DIR/sessions/$TARGET_ID/bridge-listen.log"
assert_file_exists "log file created" "$LOG_FILE"
LOG_CONTENT=$(cat "$LOG_FILE" 2>/dev/null || echo "")
assert_contains "log has CLAIM entry" "CLAIM id=$MSG_ID_L1" "$LOG_CONTENT"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd plugins/session-bridge && bash tests/test-check-inbox.sh
```

Expected: FAIL on `log file created` and `log has CLAIM entry`.

- [ ] **Step 3: Add `_log()` to `check-inbox.sh`**

In `plugins/session-bridge/scripts/check-inbox.sh`, immediately after the `_restore_claimed_files()` definition (around line 30), add:

```bash
# --- Logging (shared bridge-listen.log) ---
# Set after MY_INBOX is resolved; calls before that point are no-ops.
_LOG_FILE=""
_log() {
  [ -z "$_LOG_FILE" ] && return 0
  local TS
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$TS] ($$ check-inbox) $*" >> "$_LOG_FILE" 2>/dev/null || true
}
```

Then after the inbox-resolution block (just before `# --- Reset stop counter on UserPromptSubmit`, around line 75), add:

```bash
# Resolve log file location once we know which session/inbox we belong to
if [ -n "$MY_INBOX" ] && [ -d "$(dirname "$MY_INBOX")" ]; then
  _LOG_FILE="$(dirname "$MY_INBOX")/bridge-listen.log"
fi
```

Then in the project-scoped scan loop, immediately after the successful claim at line 226 (`mv "$MSG_FILE" "$CLAIMED_FILE" 2>/dev/null || continue`), add:

```bash
      _log "CLAIM id=$(jq -r .id "$CLAIMED_FILE" 2>/dev/null) type=$(jq -r .type "$CLAIMED_FILE" 2>/dev/null) from=$(jq -r .from "$CLAIMED_FILE" 2>/dev/null)"
```

Add the same line in the legacy scan loop after the corresponding claim mv (around line 309).

- [ ] **Step 4: Run test to verify it passes**

```bash
cd plugins/session-bridge && bash tests/test-check-inbox.sh
```

Expected: PASS on Test L1 and all prior tests still PASS.

- [ ] **Step 5: Commit**

```bash
git add plugins/session-bridge/scripts/check-inbox.sh plugins/session-bridge/tests/test-check-inbox.sh
git commit -m "$(cat <<'EOF'
feat: add CLAIM logging to check-inbox.sh

Hook-driven inbox consumption was previously invisible — only the
listener wrote to bridge-listen.log. This change writes CLAIM entries
to the same log when check-inbox.sh atomically claims a message,
making silent message loss diagnosable.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Log OUTPUT and RESTORE outcomes in `check-inbox.sh`

**Files:**
- Modify: `plugins/session-bridge/scripts/check-inbox.sh`
- Modify: `plugins/session-bridge/tests/test-check-inbox.sh`

Now log the *fate* of claimed files: successfully written to systemMessage / additionalContext, or restored on jq failure. This is what makes the trail useful.

- [ ] **Step 1: Write the failing tests**

Append to `plugins/session-bridge/tests/test-check-inbox.sh` before `print_results`:

```bash
# --- Test L2: check-inbox.sh logs OUTPUT entry on successful surface ---
echo ""
echo "Test L2: check-inbox.sh logs OUTPUT entry after writing systemMessage"
MSG_ID_L2=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SOURCE_ID" \
  bash "$SEND_MSG" "$TARGET_ID" query "output-log-test" 2>/dev/null)
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$TARGET_ID" \
  bash "$CHECK_INBOX" >/dev/null 2>&1
LOG_FILE="$BRIDGE_DIR/sessions/$TARGET_ID/bridge-listen.log"
LOG_CONTENT=$(cat "$LOG_FILE" 2>/dev/null || echo "")
assert_contains "log has OUTPUT entry" "OUTPUT mode=user-prompt count=1" "$LOG_CONTENT"

# --- Test L3: check-inbox.sh logs --stop-hook OUTPUT mode ---
echo ""
echo "Test L3: --stop-hook variant logs OUTPUT mode=stop-hook"
MSG_ID_L3=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SOURCE_ID" \
  bash "$SEND_MSG" "$TARGET_ID" query "stop-hook-log-test" 2>/dev/null)
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$TARGET_ID" \
  bash "$CHECK_INBOX" --stop-hook >/dev/null 2>&1 || true
LOG_CONTENT=$(cat "$LOG_FILE" 2>/dev/null || echo "")
assert_contains "log has stop-hook OUTPUT" "OUTPUT mode=stop-hook count=1" "$LOG_CONTENT"
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd plugins/session-bridge && bash tests/test-check-inbox.sh
```

Expected: FAIL on Test L2 (`log has OUTPUT entry`) and L3 (`log has stop-hook OUTPUT`).

- [ ] **Step 3: Wire OUTPUT and RESTORE log calls**

In `plugins/session-bridge/scripts/check-inbox.sh`, replace the existing tail of the file (the two `if jq -n ...; then ... else _restore_claimed_files; fi` blocks at lines 348–370) with:

```bash
# --- Stop hook output: block stop and inject messages as additionalContext ---
if [ "$STOP_HOOK" = true ]; then
  STOP_COUNTER=$((STOP_COUNTER + 1))
  if jq -n --arg reason "${TOTAL_COUNT} bridge message(s) pending" \
        --arg ctx "$SYSTEM_MSG" \
    '{decision: "block", reason: $reason, hookSpecificOutput: {hookEventName: "Stop", additionalContext: $ctx}}'; then
    [ -n "${STOP_COUNTER_FILE:-}" ] && echo "$STOP_COUNTER" > "$STOP_COUNTER_FILE"
    _log "OUTPUT mode=stop-hook count=$TOTAL_COUNT"
    for F in $FILES_TO_DELETE; do rm -f "$F" 2>/dev/null || true; done
  else
    _log "RESTORE mode=stop-hook count=$TOTAL_COUNT reason=jq-failed"
    _restore_claimed_files
  fi
  exit 0
fi

# --- Default mode: surface messages via systemMessage ---
# RATE_LIMITED runs from PostToolUse; non-rate-limited runs from UserPromptSubmit.
OUTPUT_MODE="user-prompt"
[ "$RATE_LIMITED" = true ] && OUTPUT_MODE="post-tool"
if jq -n --arg msg "$SYSTEM_MSG" '{continue: true, suppressOutput: false, systemMessage: $msg}'; then
  _log "OUTPUT mode=$OUTPUT_MODE count=$TOTAL_COUNT"
  for F in $FILES_TO_DELETE; do rm -f "$F" 2>/dev/null || true; done
else
  _log "RESTORE mode=$OUTPUT_MODE count=$TOTAL_COUNT reason=jq-failed"
  _restore_claimed_files
fi
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd plugins/session-bridge && bash tests/test-check-inbox.sh
```

Expected: PASS on L1, L2, L3, and all prior tests still PASS.

- [ ] **Step 5: Commit**

```bash
git add plugins/session-bridge/scripts/check-inbox.sh plugins/session-bridge/tests/test-check-inbox.sh
git commit -m "$(cat <<'EOF'
feat: log OUTPUT and RESTORE outcomes in check-inbox.sh

Mode tags (user-prompt / post-tool / stop-hook) make it possible to
correlate log entries to the originating hook, which is what's needed
to debug silent message loss reports.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Archive delivered messages in `check-inbox.sh` (instead of `rm -f`)

**Files:**
- Modify: `plugins/session-bridge/scripts/check-inbox.sh`
- Modify: `plugins/session-bridge/tests/test-check-inbox.sh`

Replace the immediate `rm -f` of claimed files with a `mv` into `.delivered/`. This converts silent loss into a recoverable, auditable archive.

- [ ] **Step 1: Update Test 3 (the existing deletion test) and add archive test**

Replace the existing Test 3 in `plugins/session-bridge/tests/test-check-inbox.sh` (around lines 64–72) with:

```bash
# --- Test 3: Message archived (not deleted) after check ---
echo ""
echo "Test 3: Message moved to .delivered/ after check"
MSG_FILE="$BRIDGE_DIR/sessions/$TARGET_ID/inbox/$MSG_ID.json"
if [ -f "$MSG_FILE" ]; then
  echo "  FAIL: message still in inbox at original path"; FAIL=$((FAIL + 1))
else
  echo "  PASS: message removed from inbox"; PASS=$((PASS + 1))
fi
ARCHIVE="$BRIDGE_DIR/sessions/$TARGET_ID/inbox/.delivered/$MSG_ID.json"
assert_file_exists "message archived in .delivered/" "$ARCHIVE"
```

Also append:

```bash
# --- Test A1: Archive content matches original message ---
echo ""
echo "Test A1: Archived file is valid JSON with original ID"
assert_json_field "archived file has correct id" "$ARCHIVE" ".id" "$MSG_ID"
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd plugins/session-bridge && bash tests/test-check-inbox.sh
```

Expected: FAIL on Test 3 archive assertion and Test A1.

- [ ] **Step 3: Replace `rm -f` with `mv` to `.delivered/`**

In `plugins/session-bridge/scripts/check-inbox.sh`, define a helper near the top (after `_restore_claimed_files`, around line 30):

```bash
# Archive a claimed file into <inbox>/.delivered/<msg-id>.json so it can be
# audited for 24h before cleanup prunes it. Falls back to rm -f if the move
# fails for any reason (full disk, permissions) — better to lose audit than
# leak claimed-but-undeleted files into the next listener's recovery sweep.
_archive_claimed() {
  local F="$1"
  [ -f "$F" ] || return 0
  local INBOX_DIR ORIG_NAME ARCHIVE_DIR
  INBOX_DIR=$(dirname "$F")
  ARCHIVE_DIR="$INBOX_DIR/.delivered"
  ORIG_NAME=$(basename "$F" | sed 's/^\.claimed_//')
  mkdir -p "$ARCHIVE_DIR" 2>/dev/null
  if ! mv "$F" "$ARCHIVE_DIR/$ORIG_NAME" 2>/dev/null; then
    rm -f "$F" 2>/dev/null || true
  fi
}
```

Then replace the two `for F in $FILES_TO_DELETE; do rm -f "$F" 2>/dev/null || true; done` loops (one in the stop-hook path, one in the default path — added in Task 2) with:

```bash
    for F in $FILES_TO_DELETE; do _archive_claimed "$F"; done
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd plugins/session-bridge && bash tests/test-check-inbox.sh
```

Expected: PASS on Test 3, Test A1, and all prior tests.

- [ ] **Step 5: Commit**

```bash
git add plugins/session-bridge/scripts/check-inbox.sh plugins/session-bridge/tests/test-check-inbox.sh
git commit -m "$(cat <<'EOF'
feat: archive claimed messages instead of rm -f in check-inbox.sh

Claimed files are now moved to <inbox>/.delivered/ rather than deleted.
On report of silent message loss, operators can grep the archive to
prove a message was claimed and surfaced to systemMessage.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Archive delivered messages in `bridge-listen.sh` (parity with check-inbox)

**Files:**
- Modify: `plugins/session-bridge/scripts/bridge-listen.sh`
- Modify: `plugins/session-bridge/tests/test-bridge-listen.sh`

Same archive policy for the listener. Currently `bridge-listen.sh:179` does `rm -f "$CLAIMED_FILE"` after stdout output — change to mv-into-archive.

- [ ] **Step 1: Update Test 2 and add archive assertion**

In `plugins/session-bridge/tests/test-bridge-listen.sh`, replace the existing Test 2 (lines 42–46) with:

```bash
# --- Test 2: Message archived (not deleted) after pickup ---
echo ""
echo "Test 2: Message archived to .delivered/ after pickup"
MSG_COUNT=$(find "$BRIDGE_DIR/sessions/$SESSION_B/inbox" -maxdepth 1 -name "*.json" 2>/dev/null | wc -l)
assert_eq "no messages at top of inbox" "0" "$MSG_COUNT"
ARCHIVE_COUNT=$(find "$BRIDGE_DIR/sessions/$SESSION_B/inbox/.delivered" -name "*.json" 2>/dev/null | wc -l)
assert_eq "one message in .delivered/" "1" "$ARCHIVE_COUNT"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd plugins/session-bridge && bash tests/test-bridge-listen.sh
```

Expected: FAIL on `one message in .delivered/`.

- [ ] **Step 3: Replace listener's `rm -f` with archive move**

In `plugins/session-bridge/scripts/bridge-listen.sh`, replace lines 178–179:

```bash
    # Delete AFTER output to prevent message loss on process death
    rm -f "$CLAIMED_FILE" 2>/dev/null || true
```

with:

```bash
    # Archive AFTER output to prevent message loss on process death.
    # Move into <inbox>/.delivered/ so cleanup.sh can prune in 24h. Fallback
    # to rm -f if move fails so we don't leak claimed-but-undeleted files.
    _ARCHIVE_DIR="$INBOX/.delivered"
    _ORIG_NAME=$(basename "$CLAIMED_FILE" | sed 's/^\.claimed_//')
    mkdir -p "$_ARCHIVE_DIR" 2>/dev/null
    if ! mv "$CLAIMED_FILE" "$_ARCHIVE_DIR/$_ORIG_NAME" 2>/dev/null; then
      rm -f "$CLAIMED_FILE" 2>/dev/null || true
    fi
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd plugins/session-bridge && bash tests/test-bridge-listen.sh
```

Expected: PASS on updated Test 2 and all prior tests.

- [ ] **Step 5: Commit**

```bash
git add plugins/session-bridge/scripts/bridge-listen.sh plugins/session-bridge/tests/test-bridge-listen.sh
git commit -m "$(cat <<'EOF'
feat: archive delivered messages in bridge-listen.sh

Mirrors the check-inbox.sh archive behavior so both consumers leave
the same evidence trail in <inbox>/.delivered/ for audit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Prune `.delivered/` archives older than 24 h in `cleanup.sh`

**Files:**
- Modify: `plugins/session-bridge/scripts/cleanup.sh`
- Modify: `plugins/session-bridge/tests/test-cleanup.sh`

The archive directory grows without bound otherwise. `cleanup.sh` already runs on `SessionEnd`; we extend it to prune archives across all sessions, like the existing outbox prune.

- [ ] **Step 1: Write the failing test**

Append to `plugins/session-bridge/tests/test-cleanup.sh` before `print_results`:

```bash
# --- Test D1: Cleanup prunes .delivered/ entries older than 24h ---
echo ""
echo "Test D1: Cleanup prunes .delivered/ files older than 24 hours"
DELIV_DIR="$BRIDGE_DIR/projects/proj-test/sessions/abc123/inbox/.delivered"
mkdir -p "$DELIV_DIR"
# Old file (2 days ago) — should be pruned
OLD_FILE="$DELIV_DIR/msg-old1234567890.json"
echo '{"id":"msg-old1234567890","status":"delivered"}' > "$OLD_FILE"
touch -d "2 days ago" "$OLD_FILE" 2>/dev/null || touch -A -480000 "$OLD_FILE" 2>/dev/null || true
# Fresh file — should survive
FRESH_FILE="$DELIV_DIR/msg-new1234567890.json"
echo '{"id":"msg-new1234567890","status":"delivered"}' > "$FRESH_FILE"

# Run cleanup with no session of its own (cleanup runs the prune block regardless)
BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$TEST_TMPDIR/no-such-project" \
  bash "$CLEANUP" 2>/dev/null || true

if [ -f "$OLD_FILE" ]; then
  echo "  FAIL: stale archive entry not pruned"; FAIL=$((FAIL + 1))
else
  echo "  PASS: stale archive entry pruned"; PASS=$((PASS + 1))
fi
assert_file_exists "fresh archive entry retained" "$FRESH_FILE"
```

(If `test-cleanup.sh` does not already define `CLEANUP`, add this near the top with the other path vars: `CLEANUP="$PLUGIN_DIR/scripts/cleanup.sh"`.)

- [ ] **Step 2: Run test to verify it fails**

```bash
cd plugins/session-bridge && bash tests/test-cleanup.sh
```

Expected: FAIL on `stale archive entry pruned`.

- [ ] **Step 3: Add prune block to `cleanup.sh`**

In `plugins/session-bridge/scripts/cleanup.sh`, immediately after the existing outbox prune block (line 223, before the resolved-conversations prune), insert:

```bash
# --- Prune .delivered/ archive entries older than 24 hours across all inboxes ---
# Files in <inbox>/.delivered/ are kept for forensic audit of message
# delivery; after 24h they are no longer useful for diagnosing losses.
DELIV_CUTOFF_EPOCH=$(date -u -v-24H +%s 2>/dev/null || date -u -d "24 hours ago" +%s 2>/dev/null || echo "")
if [ -n "$DELIV_CUTOFF_EPOCH" ]; then
  for DELIV_FILE in "$BRIDGE_DIR"/projects/*/sessions/*/inbox/.delivered/*.json \
                    "$BRIDGE_DIR"/sessions/*/inbox/.delivered/*.json; do
    [ -f "$DELIV_FILE" ] || continue
    F_MTIME=$(stat -c %Y "$DELIV_FILE" 2>/dev/null || stat -f %m "$DELIV_FILE" 2>/dev/null || echo "$DELIV_CUTOFF_EPOCH")
    [ "$F_MTIME" -lt "$DELIV_CUTOFF_EPOCH" ] && rm -f "$DELIV_FILE"
  done
fi
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd plugins/session-bridge && bash tests/test-cleanup.sh
```

Expected: PASS on Test D1 and all prior tests.

- [ ] **Step 5: Commit**

```bash
git add plugins/session-bridge/scripts/cleanup.sh plugins/session-bridge/tests/test-cleanup.sh
git commit -m "$(cat <<'EOF'
feat: prune .delivered/ archives older than 24h in cleanup.sh

Matches the existing outbox-archive policy. The 24h window is long
enough to let an operator investigate a "missing message" report
during the next business day.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Invert listener startup order — arm watcher before scan

**Files:**
- Modify: `plugins/session-bridge/scripts/bridge-listen.sh`
- Modify: `plugins/session-bridge/tests/test-bridge-listen.sh`

The current loop scans, then arms `inotifywait`. A file written between those calls is invisible to that watch cycle. Inverting closes the gap: arm the watcher first (events queue), then scan, then wait. Any race-window write surfaces as a queued event on the very next loop iteration.

- [ ] **Step 1: Write the failing race-coverage test**

Append to `plugins/session-bridge/tests/test-bridge-listen.sh` before `print_results`:

```bash
# --- Test R1: Pre-existing message delivered immediately on listener start ---
echo ""
echo "Test R1: Pre-existing inbox message picked up on first scan"
# Send a message BEFORE starting the listener — the file is already in inbox
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" query "race-pre-existing" > /dev/null
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 5)
assert_contains "delivers pre-existing message" "race-pre-existing" "$OUTPUT"

# --- Test R2: Listener loop iterates correctly after a delivery (re-scan picks up next) ---
echo ""
echo "Test R2: Two messages in rapid succession both deliver across two listener invocations"
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" query "race-burst-1" > /dev/null
BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_A" bash "$SEND_MSG" "$SESSION_B" query "race-burst-2" > /dev/null
OUTPUT1=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 5)
OUTPUT2=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LISTEN" "$SESSION_B" 5)
COMBINED="$OUTPUT1$OUTPUT2"
assert_contains "first burst message delivered" "race-burst-1" "$COMBINED"
assert_contains "second burst message delivered" "race-burst-2" "$COMBINED"
```

- [ ] **Step 2: Run tests to verify R1 already passes (regression baseline) and R2 may already pass**

```bash
cd plugins/session-bridge && bash tests/test-bridge-listen.sh
```

Expected: R1 and R2 PASS even before the inversion change. These are *regression guards* — they must keep passing after the refactor in Step 3.

- [ ] **Step 3: Invert the main loop**

In `plugins/session-bridge/scripts/bridge-listen.sh`, replace the entire `while true` loop (lines 121 through 256, ending at the closing `done`) with the version below.

The structural change: the body now (a) recovers orphan claims, (b) arms the watcher in the background, (c) scans the inbox, (d) if a message was delivered, kills the armed watcher and exits, (e) otherwise waits on the watcher.

```bash
while true; do
  # Timeout check (0 = infinite)
  if [ "$TIMEOUT" -gt 0 ] && [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    _log "TIMEOUT elapsed=${ELAPSED}s"
    echo "BRIDGE_STATUS=timeout"
    exit 1
  fi

  # Recover orphaned .claimed_ files older than 30 seconds (from killed processes)
  CLAIM_NOW=$(date +%s)
  for CLAIMED in "$INBOX"/.claimed_*.json; do
    [ -f "$CLAIMED" ] || continue
    CLAIM_MTIME=$(stat -c %Y "$CLAIMED" 2>/dev/null || stat -f %m "$CLAIMED" 2>/dev/null || echo "$CLAIM_NOW")
    [ $((CLAIM_NOW - CLAIM_MTIME)) -lt 30 ] && continue
    ORIG_NAME=$(basename "$CLAIMED" | sed 's/^\.claimed_//')
    mv "$CLAIMED" "$INBOX/$ORIG_NAME" 2>/dev/null || true
  done

  # ARM the watcher BEFORE scanning so events that fire during the scan
  # are queued and surface as the next event. Closes the scan-then-watch
  # startup race that previously could leave a fresh inbox file invisible
  # until a *subsequent* unrelated event woke the listener.
  INOTIFY_PID=""
  FSWATCH_PID=""
  WAIT_START=0
  WAIT_REMAINING=0
  case "$WATCHER" in
    inotifywait)
      if [ "$TIMEOUT" -gt 0 ]; then
        WAIT_REMAINING=$((TIMEOUT - ELAPSED))
      else
        WAIT_REMAINING=300
      fi
      _log "WAIT inotifywait -t $WAIT_REMAINING pid=$$"
      inotifywait -t "$WAIT_REMAINING" -e create "$INBOX" >/dev/null 2>&1 9>&- &
      INOTIFY_PID=$!
      echo "$INOTIFY_PID" > "$WATCHER_CHILD_FILE"
      ;;
    fswatch)
      if [ "$TIMEOUT" -gt 0 ]; then
        WAIT_REMAINING=$((TIMEOUT - ELAPSED))
      else
        WAIT_REMAINING=300
      fi
      WAIT_START=$(date +%s)
      timeout "$WAIT_REMAINING" fswatch --one-event "$INBOX" >/dev/null 2>&1 9>&- &
      FSWATCH_PID=$!
      echo "$FSWATCH_PID" > "$WATCHER_CHILD_FILE"
      ;;
    poll)
      : # No watcher to arm; scan + sleep below.
      ;;
  esac

  # Scan inbox AFTER arming the watcher so any concurrent write either
  # (a) is found by this scan or (b) wakes the armed watcher next loop.
  for MSG_FILE in "$INBOX"/*.json; do
    [ -f "$MSG_FILE" ] || continue
    STATUS=$(jq -r '.status' "$MSG_FILE" 2>/dev/null) || continue
    [ "$STATUS" = "pending" ] || continue

    MSG_BASENAME=$(basename "$MSG_FILE")
    CLAIMED_FILE="$INBOX/.claimed_${MSG_BASENAME}"
    mv "$MSG_FILE" "$CLAIMED_FILE" 2>/dev/null || continue

    MSG_ID=$(jq -r '.id' "$CLAIMED_FILE")
    FROM_ID=$(jq -r '.from' "$CLAIMED_FILE")
    TO_ID=$(jq -r '.to' "$CLAIMED_FILE")
    MSG_TYPE=$(jq -r '.type' "$CLAIMED_FILE")
    CONTENT=$(jq -r '.content' "$CLAIMED_FILE")
    FROM_PROJECT=$(jq -r '.metadata.fromProject // "unknown"' "$CLAIMED_FILE")
    IN_REPLY_TO=$(jq -r '.inReplyTo // ""' "$CLAIMED_FILE")
    CONV_ID=$(jq -r '.conversationId // ""' "$CLAIMED_FILE")

    # Skip messages FROM ourselves (echo prevention) — restore file if skipping
    if [ "$FROM_ID" = "$SESSION_ID" ]; then
      mv "$CLAIMED_FILE" "$MSG_FILE" 2>/dev/null || true
      continue
    fi

    _log "MESSAGE id=$MSG_ID type=$MSG_TYPE from=$FROM_ID ($FROM_PROJECT)"

    # Tear down the armed watcher before exiting so we don't leak a child.
    if [ -n "$INOTIFY_PID" ] && kill -0 "$INOTIFY_PID" 2>/dev/null; then
      kill "$INOTIFY_PID" 2>/dev/null || true
      wait "$INOTIFY_PID" 2>/dev/null || true
    fi
    if [ -n "$FSWATCH_PID" ] && kill -0 "$FSWATCH_PID" 2>/dev/null; then
      kill "$FSWATCH_PID" 2>/dev/null || true
      wait "$FSWATCH_PID" 2>/dev/null || true
    fi
    rm -f "$WATCHER_CHILD_FILE" 2>/dev/null

    echo "BRIDGE_STATUS=delivered"
    echo "MESSAGE_ID=$MSG_ID"
    echo "FROM_ID=$FROM_ID"
    echo "TO_ID=$TO_ID"
    echo "FROM_PROJECT=$FROM_PROJECT"
    echo "TYPE=$MSG_TYPE"
    echo "IN_REPLY_TO=$IN_REPLY_TO"
    echo "CONV_ID=$CONV_ID"
    echo "---"
    echo "$CONTENT"

    # Archive AFTER output so process death pre-output leaves the file
    # recoverable by the orphan sweep (it stays as .claimed_*).
    _ARCHIVE_DIR="$INBOX/.delivered"
    _ORIG_NAME=$(basename "$CLAIMED_FILE" | sed 's/^\.claimed_//')
    mkdir -p "$_ARCHIVE_DIR" 2>/dev/null
    if ! mv "$CLAIMED_FILE" "$_ARCHIVE_DIR/$_ORIG_NAME" 2>/dev/null; then
      rm -f "$CLAIMED_FILE" 2>/dev/null || true
    fi
    exit 0
  done

  # No message delivered this iteration — wait on the armed watcher (or sleep for poll).
  case "$WATCHER" in
    inotifywait)
      WATCH_RC=0
      wait "$INOTIFY_PID" 2>/dev/null || WATCH_RC=$?
      rm -f "$WATCHER_CHILD_FILE" 2>/dev/null
      case "$WATCH_RC" in
        0)
          _log "EVENT file created in inbox"
          ELAPSED=$((ELAPSED + 1))
          ;;
        2)
          _log "POLL timeout after ${WAIT_REMAINING}s, re-checking"
          ELAPSED=$((ELAPSED + WAIT_REMAINING))
          ;;
        *)
          _log "ERROR inotifywait rc=$WATCH_RC"
          if [ ! -d "$INBOX" ]; then
            _log "FATAL inbox directory gone"
            echo "Error: Inbox directory $INBOX no longer exists." >&2
            exit 1
          fi
          sleep "$INTERVAL"
          ELAPSED=$((ELAPSED + INTERVAL))
          ;;
      esac
      ;;
    fswatch)
      WATCH_RC=0
      wait "$FSWATCH_PID" 2>/dev/null || WATCH_RC=$?
      rm -f "$WATCHER_CHILD_FILE" 2>/dev/null
      WAIT_END=$(date +%s)
      WAIT_DURATION=$((WAIT_END - WAIT_START))
      if [ "$WATCH_RC" -ne 0 ] && [ "$WAIT_DURATION" -lt 2 ]; then
        _log "ERROR fswatch rc=$WATCH_RC duration=${WAIT_DURATION}s"
        if [ ! -d "$INBOX" ]; then
          _log "FATAL inbox directory gone"
          echo "Error: Inbox directory $INBOX no longer exists." >&2
          exit 1
        fi
        sleep "$INTERVAL"
        ELAPSED=$((ELAPSED + INTERVAL))
      else
        ELAPSED=$((ELAPSED + WAIT_DURATION))
      fi
      ;;
    poll)
      sleep "$INTERVAL"
      ELAPSED=$((ELAPSED + INTERVAL))
      ;;
  esac
done
```

- [ ] **Step 4: Run the full bridge-listen test suite to verify**

```bash
cd plugins/session-bridge && bash tests/test-bridge-listen.sh
```

Expected: All previously-passing tests (1, 3, 4, 5, 6, 7, S1, S2, S3, R1, R2, plus the archive Test 2 from Task 4) PASS.

- [ ] **Step 5: Commit**

```bash
git add plugins/session-bridge/scripts/bridge-listen.sh plugins/session-bridge/tests/test-bridge-listen.sh
git commit -m "$(cat <<'EOF'
fix: arm inotifywait before scan to close startup race

The listener loop previously scanned inbox before arming the watcher.
A file written in that window was missed by both the initial scan and
the watcher (inotify only fires on new creates), and would only surface
when an unrelated subsequent event woke the listener — by which time
check-inbox.sh hooks could have claimed and silently consumed it.

Inverting the order queues race-window events so they fire on the
next loop iteration. Closes one of three causes of issue #17.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Run full test suite, version bump, refresh docs

**Files:**
- Modify: `plugins/session-bridge/.claude-plugin/plugin.json`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Run the entire test suite**

```bash
cd plugins/session-bridge && bash test.sh
```

Expected: All 353+ existing tests PASS, plus the new tests added in Tasks 1, 2, 3, 4, 5, 6 — final count ~360+. If any test fails, stop and fix the underlying issue rather than the test.

- [ ] **Step 2: Bump the plugin version**

Edit `plugins/session-bridge/.claude-plugin/plugin.json`:

```json
{
  "name": "session-bridge",
  "version": "0.2.22",
  "description": "Peer-to-peer communication between Claude Code sessions on the same machine",
  ...
}
```

- [ ] **Step 3: Update CLAUDE.md v2 Key Concepts to mention archive + shared log**

In `CLAUDE.md`, find the "v2 Key Concepts" section (currently a bulleted list under "Bidirectional Bridge v2 (shipped)"). Update the version reference at the top of that section from `0.2.21` to `0.2.22`. Add this bullet at the end of the "v2 Key Concepts" list:

```markdown
- **Delivery audit**: every claimed message is archived to `<inbox>/.delivered/` (pruned after 24h by `cleanup.sh`); both `bridge-listen.sh` and `check-inbox.sh` write CLAIM/OUTPUT/RESTORE entries to a shared `bridge-listen.log`, so silent message loss is recoverable + diagnosable
```

Also bump the references that name the version (the "currently v0.2.21" mention in the project structure block, the "stable as of v0.2.21" line) to `v0.2.22`.

- [ ] **Step 4: Run the full suite once more after edits**

```bash
cd plugins/session-bridge && bash test.sh
```

Expected: still all PASS. Doc edits and version bump shouldn't affect tests.

- [ ] **Step 5: Final commit + tag**

```bash
git add plugins/session-bridge/.claude-plugin/plugin.json CLAUDE.md
git commit -m "$(cat <<'EOF'
chore: bump to v0.2.22 with delivery-loss fixes

Bundles three changes addressing issue #17:
- check-inbox.sh now logs CLAIM/OUTPUT/RESTORE to bridge-listen.log
- both consumers archive delivered messages to <inbox>/.delivered/
- bridge-listen.sh arms its watcher before scanning, closing the
  scan-then-watch startup race

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

(The user will decide whether to cut a GitHub release at this point — out of scope for the plan.)

---

## Self-Review

**1. Spec coverage:**

- Hypothesis 1 (scan-then-watch race) → Task 6 inverts the order. Covered.
- Hypothesis 2 (hook claim+lose, no log trail) → Tasks 1, 2 add the log trail; Tasks 3, 4 convert silent loss into recoverable archive. Covered.
- Cleanup of the new archive directory → Task 5. Covered.
- Version bump + CLAUDE.md sync → Task 7. Covered.

No gaps.

**2. Placeholder scan:**

No "TODO", "TBD", "implement later", "similar to", "appropriate error handling" instances. Every code step shows the exact code to paste. Tests show the exact assertions and the expected pass/fail of each step.

**3. Type / name consistency:**

- `_log()`, `_archive_claimed()`, `_restore_claimed_files()`, `_LOG_FILE` are consistently named in `check-inbox.sh` across Tasks 1–3.
- `INOTIFY_PID`, `FSWATCH_PID`, `WATCHER_CHILD_FILE`, `WAIT_REMAINING`, `WAIT_START` in `bridge-listen.sh` Task 6 reuse the variable names already established earlier in the file.
- The archive directory path `<inbox>/.delivered/` is identical across the check-inbox.sh archive (Task 3), the bridge-listen.sh archive (Tasks 4 and 6), and the cleanup prune (Task 5).
- Log entry shapes — `CLAIM id=... type=... from=...`, `OUTPUT mode=user-prompt|post-tool|stop-hook count=N`, `RESTORE mode=... count=N reason=jq-failed`, `MESSAGE id=...` — are consistent between what tests assert and what scripts emit.

No inconsistencies found.

# Session Lifecycle Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current "session ID is destroyed when watcher heartbeat goes stale" behavior with a proper four-state lifecycle (`active`, `offline`, `stale`, `removed`) backed by a dedicated heartbeat daemon, on-demand stale-detection with PID-liveness backstop, and a four-script split (`project-join` / `resume-session` / `close-session` / `remove-session` / `prune`) replacing the monolithic `cleanup.sh`.

**Architecture:** A new background daemon (`heartbeat-daemon.sh`) writes ISO 8601 timestamps to `<session-dir>/heartbeat` every 60s; a shared library (`scripts/lib/stale-check.sh`) determines staleness by combining heartbeat age, manifest `status` field, and PID liveness of the daemon. Lifecycle transitions move from monolithic `cleanup.sh` into four single-purpose scripts triggered by specific events (SessionEnd hook → graceful offline; user-explicit `/bridge remove` → destructive removal; user-explicit `/bridge prune` → disk maintenance; SessionStart hook → resume via `resume-session.sh` separate from first-time `project-join.sh`).

**Tech Stack:** bash, jq, inotifywait/fswatch, atomic-rename file primitives, existing 365-test bash test suite.

**Spec:** `docs/superpowers/specs/2026-05-25-session-lifecycle-redesign.md` (read first for context).

**Versioning:** This is a minor bump — new message type (`recipient-stale`), new commands, removed `/bridge stop`, but protocol version stays at 2.0. Target: v0.2.22 → v0.3.0.

**Critical constraint:** The user's plextura-suite runs against a live symlinked copy of this plugin. Every commit must leave the test suite green and the runtime functional. No intermediate breakage between commits.

---

## File Structure

### Create
- `plugins/session-bridge/scripts/lib/stale-check.sh` — sourced helper: `is_producer_alive`, `get_heartbeat_age`, `is_stale`, `set_status`
- `plugins/session-bridge/scripts/heartbeat-daemon.sh` — dedicated background producer writing `<session-dir>/heartbeat` every 60s, with EXIT trap
- `plugins/session-bridge/scripts/close-session.sh` — SessionEnd hook target; graceful offline transition (non-destructive)
- `plugins/session-bridge/scripts/resume-session.sh` — SessionStart hook target; adopts existing ID, errors loudly if missing
- `plugins/session-bridge/scripts/remove-session.sh` — `/bridge remove` command target; destructive removal
- `plugins/session-bridge/scripts/prune.sh` — `/bridge prune` command target; operator-controlled disk maintenance
- `plugins/session-bridge/tests/test-stale-check.sh` — tests for the lib helpers
- `plugins/session-bridge/tests/test-heartbeat-daemon.sh` — tests for the producer
- `plugins/session-bridge/tests/test-close-session.sh` — tests for graceful offline
- `plugins/session-bridge/tests/test-resume-session.sh` — tests for adoption + fail-loud
- `plugins/session-bridge/tests/test-remove-session.sh` — tests for destructive removal
- `plugins/session-bridge/tests/test-prune.sh` — tests for prune command

### Modify
- `plugins/session-bridge/scripts/project-join.sh` — strict first-time only, remove reuse path (moves to resume-session.sh)
- `plugins/session-bridge/scripts/auto-join.sh` — delegate to `resume-session.sh` instead of `project-join.sh`
- `plugins/session-bridge/scripts/inbox-watcher.sh` — remove heartbeat-writing duties (heartbeat-daemon.sh owns that now)
- `plugins/session-bridge/scripts/send-message.sh` — add `recipient-stale` and `session-removed` message types; before delivery, stale-detect recipient and emit notification
- `plugins/session-bridge/scripts/list-peers.sh` — read new heartbeat file via lib, surface `active`/`offline`/`stale` states
- `plugins/session-bridge/hooks/hooks.json` — SessionEnd hook command changes from `cleanup.sh` to `close-session.sh`
- `plugins/session-bridge/commands/bridge.md` — add `/bridge close`, `/bridge remove`, `/bridge prune`; remove `/bridge stop`
- `plugins/session-bridge/skills/bridge-awareness/SKILL.md` — add `recipient-stale` + `session-removed` handling, update visibility lines
- `plugins/session-bridge/.claude-plugin/plugin.json` — version 0.2.22 → 0.3.0
- `CLAUDE.md` — update v2 Key Concepts, document the lifecycle model
- `plugins/session-bridge/tests/test-list-peers.sh` — update for new status display
- `plugins/session-bridge/tests/test-send-message.sh` — add recipient-stale flow tests
- `plugins/session-bridge/tests/test-project-join.sh` — update for strict-mode behavior
- `plugins/session-bridge/tests/test-auto-join.sh` — update for resume-session.sh delegation
- `plugins/session-bridge/tests/test-inbox-watcher.sh` — remove heartbeat-related expectations

### Delete
- `plugins/session-bridge/scripts/cleanup.sh` — responsibilities split into close-session/remove-session/prune
- `plugins/session-bridge/tests/test-cleanup.sh` — tests migrate to the appropriate new test files

---

## Task 1: Add stale-detection library

**Files:**
- Create: `plugins/session-bridge/scripts/lib/stale-check.sh`
- Create: `plugins/session-bridge/tests/test-stale-check.sh`

This task introduces shared helper functions used by `send-message.sh` and `list-peers.sh` in later tasks. No existing behavior changes.

- [ ] **Step 1: Write the failing test file**

Create `plugins/session-bridge/tests/test-stale-check.sh`:

```bash
#!/usr/bin/env bash
# tests/test-stale-check.sh — Tests for scripts/lib/stale-check.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$PLUGIN_DIR/scripts/lib/stale-check.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

echo "=== test-stale-check.sh ==="

# Source the lib for testing
# shellcheck source=/dev/null
source "$LIB"

# --- Test 1: get_heartbeat_age returns seconds since file content timestamp ---
echo ""
echo "Test 1: get_heartbeat_age returns age in seconds"
HB_FILE="$TEST_TMPDIR/heartbeat"
TS_120S_AGO=$(date -u -d "120 seconds ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-120S +"%Y-%m-%dT%H:%M:%SZ")
echo "$TS_120S_AGO" > "$HB_FILE"
AGE=$(get_heartbeat_age "$HB_FILE")
# Age should be ~120 (allow ±5s slack for test runtime)
if [ "$AGE" -ge 115 ] && [ "$AGE" -le 130 ]; then
  echo "  PASS: heartbeat age ~120s (got $AGE)"; PASS=$((PASS + 1))
else
  echo "  FAIL: heartbeat age expected ~120, got $AGE"; FAIL=$((FAIL + 1))
fi

# --- Test 2: get_heartbeat_age returns 99999999 when file missing ---
echo ""
echo "Test 2: get_heartbeat_age returns sentinel when file missing"
MISSING_AGE=$(get_heartbeat_age "$TEST_TMPDIR/does-not-exist")
assert_eq "missing file → sentinel" "99999999" "$MISSING_AGE"

# --- Test 3: is_producer_alive returns 0 for $$ (this script process) ---
echo ""
echo "Test 3: is_producer_alive returns true for live PID"
# Self-PID is alive but won't pass the cmdline check (we're a test script, not heartbeat-daemon)
# So this should return 1 (false) — defensive cmdline guard
if is_producer_alive "$$"; then
  echo "  FAIL: self-pid passed cmdline guard (should reject)"; FAIL=$((FAIL + 1))
else
  echo "  PASS: cmdline guard rejects non-daemon PID"; PASS=$((PASS + 1))
fi

# --- Test 4: is_producer_alive returns 1 for dead PID ---
echo ""
echo "Test 4: is_producer_alive returns false for dead PID"
# Spawn-and-kill a short-lived process to get a guaranteed-dead PID
sleep 0 &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
if is_producer_alive "$DEAD_PID"; then
  echo "  FAIL: dead PID reported alive"; FAIL=$((FAIL + 1))
else
  echo "  PASS: dead PID reported dead"; PASS=$((PASS + 1))
fi

# --- Test 5: is_producer_alive returns 1 for empty PID ---
echo ""
echo "Test 5: is_producer_alive returns false for empty PID"
if is_producer_alive ""; then
  echo "  FAIL: empty PID reported alive"; FAIL=$((FAIL + 1))
else
  echo "  PASS: empty PID reported dead"; PASS=$((PASS + 1))
fi

# --- Test 6: is_stale returns false when status=offline ---
echo ""
echo "Test 6: is_stale returns false when status=offline"
SESSION_DIR="$TEST_TMPDIR/session1"
mkdir -p "$SESSION_DIR"
echo '{"sessionId":"abc123","status":"offline"}' > "$SESSION_DIR/manifest.json"
TS_OLD=$(date -u -d "1 hour ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-1H +"%Y-%m-%dT%H:%M:%SZ")
echo "$TS_OLD" > "$SESSION_DIR/heartbeat"
if is_stale "$SESSION_DIR" 300; then
  echo "  FAIL: offline session reported stale"; FAIL=$((FAIL + 1))
else
  echo "  PASS: offline session not stale"; PASS=$((PASS + 1))
fi

# --- Test 7: is_stale returns true when status=active + heartbeat old + no daemon PID file ---
echo ""
echo "Test 7: is_stale returns true when status=active, heartbeat old, no daemon"
SESSION_DIR="$TEST_TMPDIR/session2"
mkdir -p "$SESSION_DIR"
echo '{"sessionId":"def456","status":"active"}' > "$SESSION_DIR/manifest.json"
echo "$TS_OLD" > "$SESSION_DIR/heartbeat"
# No watcher.pid file — daemon presumed dead
if is_stale "$SESSION_DIR" 300; then
  echo "  PASS: stale session correctly detected"; PASS=$((PASS + 1))
else
  echo "  FAIL: stale session not detected"; FAIL=$((FAIL + 1))
fi

# --- Test 8: is_stale returns false when status=active + heartbeat fresh ---
echo ""
echo "Test 8: is_stale returns false when heartbeat is fresh"
SESSION_DIR="$TEST_TMPDIR/session3"
mkdir -p "$SESSION_DIR"
echo '{"sessionId":"ghi789","status":"active"}' > "$SESSION_DIR/manifest.json"
TS_NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "$TS_NOW" > "$SESSION_DIR/heartbeat"
if is_stale "$SESSION_DIR" 300; then
  echo "  FAIL: fresh heartbeat reported stale"; FAIL=$((FAIL + 1))
else
  echo "  PASS: fresh heartbeat not stale"; PASS=$((PASS + 1))
fi

# --- Test 9: set_status writes new status field atomically ---
echo ""
echo "Test 9: set_status writes new status to manifest"
SESSION_DIR="$TEST_TMPDIR/session4"
mkdir -p "$SESSION_DIR"
echo '{"sessionId":"jkl012","status":"active","other":"keep"}' > "$SESSION_DIR/manifest.json"
set_status "$SESSION_DIR/manifest.json" "stale"
assert_json_field "status flipped to stale" "$SESSION_DIR/manifest.json" ".status" "stale"
assert_json_field "other field preserved" "$SESSION_DIR/manifest.json" ".other" "keep"

print_results
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd plugins/session-bridge && bash tests/test-stale-check.sh
```

Expected: FAIL with "No such file or directory" on `source "$LIB"` (the lib doesn't exist yet).

- [ ] **Step 3: Create the lib**

Create `plugins/session-bridge/scripts/lib/stale-check.sh`:

```bash
#!/usr/bin/env bash
# scripts/lib/stale-check.sh — Shared helpers for session staleness detection.
# Sourced by send-message.sh and list-peers.sh.
# Functions:
#   get_heartbeat_age <heartbeat-file>     → echoes age in seconds (or 99999999 if missing)
#   is_producer_alive <pid>                 → exit 0 if alive AND cmdline matches heartbeat-daemon
#   is_stale <session-dir> <threshold-sec>  → exit 0 if session is stale
#   set_status <manifest-file> <new-status> → atomic manifest update

get_heartbeat_age() {
  local HB_FILE="$1"
  if [ ! -f "$HB_FILE" ]; then
    echo "99999999"
    return 0
  fi
  local HB_STR HB_EPOCH NOW_EPOCH
  HB_STR=$(cat "$HB_FILE" 2>/dev/null | head -1)
  if [ -z "$HB_STR" ]; then
    echo "99999999"
    return 0
  fi
  # BSD date first (macOS), GNU date fallback (Linux)
  HB_EPOCH=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$HB_STR" +%s 2>/dev/null \
    || date -u -d "$HB_STR" +%s 2>/dev/null \
    || echo "0")
  if [ "$HB_EPOCH" -eq 0 ]; then
    echo "99999999"
    return 0
  fi
  NOW_EPOCH=$(date -u +%s)
  echo $((NOW_EPOCH - HB_EPOCH))
}

is_producer_alive() {
  local PID="$1"
  [ -z "$PID" ] && return 1
  kill -0 "$PID" 2>/dev/null || return 1
  # Defensive: verify the PID is actually our heartbeat-daemon (guards against PID reuse)
  if [ -r "/proc/$PID/cmdline" ]; then
    # Linux: read /proc/<pid>/cmdline (null-separated)
    tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null | grep -q "heartbeat-daemon\.sh"
  else
    # macOS: use ps
    ps -p "$PID" -o command= 2>/dev/null | grep -q "heartbeat-daemon\.sh"
  fi
}

is_stale() {
  local SESSION_DIR="$1"
  local THRESHOLD="${2:-300}"
  local MANIFEST="$SESSION_DIR/manifest.json"
  local HB_FILE="$SESSION_DIR/heartbeat"
  local PID_FILE="$SESSION_DIR/heartbeat-daemon.pid"

  [ -f "$MANIFEST" ] || return 1
  local STATUS
  STATUS=$(jq -r '.status // "active"' "$MANIFEST" 2>/dev/null)
  # Only "active" sessions can become stale; offline/stale/removed don't transition here
  [ "$STATUS" = "active" ] || return 1

  local AGE
  AGE=$(get_heartbeat_age "$HB_FILE")
  [ "$AGE" -lt "$THRESHOLD" ] && return 1

  # Heartbeat looks stale. But check if producer PID is still alive —
  # protects against false positives after system suspend/resume.
  local PID=""
  [ -f "$PID_FILE" ] && PID=$(cat "$PID_FILE" 2>/dev/null)
  if is_producer_alive "$PID"; then
    return 1
  fi

  return 0
}

set_status() {
  local MANIFEST="$1"
  local NEW_STATUS="$2"
  [ -f "$MANIFEST" ] || return 1
  local TMP
  TMP=$(mktemp "$(dirname "$MANIFEST")/manifest.XXXXXX")
  jq --arg s "$NEW_STATUS" '.status = $s' "$MANIFEST" > "$TMP" 2>/dev/null \
    && mv "$TMP" "$MANIFEST" \
    || { rm -f "$TMP"; return 1; }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd plugins/session-bridge && bash tests/test-stale-check.sh
```

Expected: PASS, all 9 assertions.

- [ ] **Step 5: Run full test suite to ensure no regression**

```bash
cd plugins/session-bridge && bash test.sh
```

Expected: 365 + 9 = 374 passed / 0 failed (numbers may vary by 1-2 from spec — that's fine).

- [ ] **Step 6: Commit**

```bash
git add plugins/session-bridge/scripts/lib/stale-check.sh plugins/session-bridge/tests/test-stale-check.sh
git commit -m "$(cat <<'EOF'
feat: add stale-check lib for session lifecycle redesign

Shared helpers for determining session staleness:
- get_heartbeat_age: parse timestamp from <session>/heartbeat file content
- is_producer_alive: PID liveness + cmdline guard (cross-platform)
- is_stale: combines status field, heartbeat age, PID liveness
- set_status: atomic manifest status update

This is foundation-only — no existing scripts use the lib yet.
Subsequent tasks wire send-message.sh and list-peers.sh through it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add heartbeat-daemon.sh (producer, not yet started)

**Files:**
- Create: `plugins/session-bridge/scripts/heartbeat-daemon.sh`
- Create: `plugins/session-bridge/tests/test-heartbeat-daemon.sh`

The daemon writes timestamps to `<session-dir>/heartbeat` every N seconds (configurable for testability). EXIT trap flips `status=active → stale` on unexpected death.

- [ ] **Step 1: Write the failing test**

Create `plugins/session-bridge/tests/test-heartbeat-daemon.sh`:

```bash
#!/usr/bin/env bash
# tests/test-heartbeat-daemon.sh — Tests for scripts/heartbeat-daemon.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DAEMON="$PLUGIN_DIR/scripts/heartbeat-daemon.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

echo "=== test-heartbeat-daemon.sh ==="

# Set up a fake session dir
SESSION_DIR="$TEST_TMPDIR/session"
mkdir -p "$SESSION_DIR"
echo '{"sessionId":"test01","status":"active"}' > "$SESSION_DIR/manifest.json"

# --- Test 1: Daemon writes heartbeat file on first tick ---
echo ""
echo "Test 1: heartbeat file is written on first tick"
HEARTBEAT_INTERVAL=1 bash "$DAEMON" "$SESSION_DIR" &
DAEMON_PID=$!
sleep 2  # wait for at least one tick
HB_FILE="$SESSION_DIR/heartbeat"
assert_file_exists "heartbeat file exists" "$HB_FILE"
HB_CONTENT=$(cat "$HB_FILE")
assert_contains "heartbeat contains ISO 8601 timestamp" "T" "$HB_CONTENT"
assert_contains "heartbeat ends with Z" "Z" "$HB_CONTENT"
kill "$DAEMON_PID" 2>/dev/null || true
wait "$DAEMON_PID" 2>/dev/null || true

# --- Test 2: Daemon updates heartbeat across multiple ticks ---
echo ""
echo "Test 2: heartbeat is updated across ticks"
SESSION_DIR2="$TEST_TMPDIR/session2"
mkdir -p "$SESSION_DIR2"
echo '{"sessionId":"test02","status":"active"}' > "$SESSION_DIR2/manifest.json"
HEARTBEAT_INTERVAL=1 bash "$DAEMON" "$SESSION_DIR2" &
DAEMON_PID=$!
sleep 1
HB1=$(cat "$SESSION_DIR2/heartbeat")
sleep 2
HB2=$(cat "$SESSION_DIR2/heartbeat")
if [ "$HB1" = "$HB2" ]; then
  echo "  FAIL: heartbeat did not update across ticks (HB1=$HB1, HB2=$HB2)"; FAIL=$((FAIL + 1))
else
  echo "  PASS: heartbeat updated across ticks"; PASS=$((PASS + 1))
fi
kill "$DAEMON_PID" 2>/dev/null || true
wait "$DAEMON_PID" 2>/dev/null || true

# --- Test 3: Daemon writes PID file ---
echo ""
echo "Test 3: heartbeat-daemon.pid file is written"
SESSION_DIR3="$TEST_TMPDIR/session3"
mkdir -p "$SESSION_DIR3"
echo '{"sessionId":"test03","status":"active"}' > "$SESSION_DIR3/manifest.json"
HEARTBEAT_INTERVAL=1 bash "$DAEMON" "$SESSION_DIR3" &
DAEMON_PID=$!
sleep 2
PID_FILE="$SESSION_DIR3/heartbeat-daemon.pid"
assert_file_exists "PID file exists" "$PID_FILE"
WRITTEN_PID=$(cat "$PID_FILE")
assert_eq "PID file contains daemon PID" "$DAEMON_PID" "$WRITTEN_PID"
kill "$DAEMON_PID" 2>/dev/null || true
wait "$DAEMON_PID" 2>/dev/null || true

# --- Test 4: EXIT trap flips status=active → stale on SIGTERM ---
echo ""
echo "Test 4: EXIT trap sets status=stale when killed while active"
SESSION_DIR4="$TEST_TMPDIR/session4"
mkdir -p "$SESSION_DIR4"
echo '{"sessionId":"test04","status":"active"}' > "$SESSION_DIR4/manifest.json"
HEARTBEAT_INTERVAL=1 bash "$DAEMON" "$SESSION_DIR4" &
DAEMON_PID=$!
sleep 2
kill -TERM "$DAEMON_PID"
wait "$DAEMON_PID" 2>/dev/null || true
sleep 1
assert_json_field "status flipped to stale" "$SESSION_DIR4/manifest.json" ".status" "stale"

# --- Test 5: EXIT trap is no-op when status=offline ---
echo ""
echo "Test 5: EXIT trap is no-op when status=offline"
SESSION_DIR5="$TEST_TMPDIR/session5"
mkdir -p "$SESSION_DIR5"
echo '{"sessionId":"test05","status":"active"}' > "$SESSION_DIR5/manifest.json"
HEARTBEAT_INTERVAL=1 bash "$DAEMON" "$SESSION_DIR5" &
DAEMON_PID=$!
sleep 2
# Simulate close-session.sh: flip status first, THEN kill daemon
jq '.status = "offline"' "$SESSION_DIR5/manifest.json" > "$SESSION_DIR5/manifest.tmp" && mv "$SESSION_DIR5/manifest.tmp" "$SESSION_DIR5/manifest.json"
kill -TERM "$DAEMON_PID"
wait "$DAEMON_PID" 2>/dev/null || true
sleep 1
assert_json_field "status remained offline" "$SESSION_DIR5/manifest.json" ".status" "offline"

print_results
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd plugins/session-bridge && bash tests/test-heartbeat-daemon.sh
```

Expected: FAIL — script doesn't exist.

- [ ] **Step 3: Create the daemon**

Create `plugins/session-bridge/scripts/heartbeat-daemon.sh`:

```bash
#!/usr/bin/env bash
# scripts/heartbeat-daemon.sh — Background heartbeat producer for a bridge session.
# Usage: heartbeat-daemon.sh <session-dir>
# Env: HEARTBEAT_INTERVAL (default 60s) — interval between heartbeat writes
# Writes <session-dir>/heartbeat every interval. Writes <session-dir>/heartbeat-daemon.pid on start.
# On EXIT (any signal): if manifest status=active, flips to "stale".
# Designed to run as a detached background process per session.
set -euo pipefail

SESSION_DIR="${1:?Usage: heartbeat-daemon.sh <session-dir>}"
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-60}"

if [ ! -d "$SESSION_DIR" ]; then
  echo "Error: session dir $SESSION_DIR does not exist" >&2
  exit 1
fi

MANIFEST="$SESSION_DIR/manifest.json"
HB_FILE="$SESSION_DIR/heartbeat"
PID_FILE="$SESSION_DIR/heartbeat-daemon.pid"
LOG_FILE="$SESSION_DIR/bridge-listen.log"

if [ ! -f "$MANIFEST" ]; then
  echo "Error: manifest $MANIFEST does not exist" >&2
  exit 1
fi

# Source the stale-check lib for set_status (used in EXIT trap)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/stale-check.sh
source "$SCRIPT_DIR/lib/stale-check.sh"

# Logging helper (shares bridge-listen.log convention from v0.2.22)
_log() {
  local TS
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$TS] ($$ heartbeat-daemon) $*" >> "$LOG_FILE" 2>/dev/null || true
}

# EXIT trap: classify our death and update status accordingly.
_on_exit() {
  local CURRENT_STATUS
  CURRENT_STATUS=$(jq -r '.status // ""' "$MANIFEST" 2>/dev/null || echo "")
  case "$CURRENT_STATUS" in
    active)
      set_status "$MANIFEST" "stale"
      _log "EXIT producer dying unexpectedly (status was active → stale)"
      ;;
    offline|stale|removed)
      _log "EXIT clean (status=$CURRENT_STATUS)"
      ;;
    *)
      _log "EXIT unknown status='$CURRENT_STATUS'"
      ;;
  esac
  rm -f "$PID_FILE" 2>/dev/null || true
}
trap _on_exit EXIT INT TERM

# Record our PID for the on-demand stale-detector
echo "$$" > "$PID_FILE"
_log "START interval=${HEARTBEAT_INTERVAL}s session_dir=$SESSION_DIR"

# Write an initial heartbeat immediately so consumers don't see a stale window
_write_heartbeat() {
  local NOW TMP
  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  TMP=$(mktemp "$SESSION_DIR/heartbeat.XXXXXX")
  echo "$NOW" > "$TMP"
  mv "$TMP" "$HB_FILE" 2>/dev/null || rm -f "$TMP"
}

_write_heartbeat

# Main loop: tick every HEARTBEAT_INTERVAL seconds
while true; do
  sleep "$HEARTBEAT_INTERVAL" &
  SLEEP_PID=$!
  # Wait but allow signal interruption (the trap will run on TERM/INT)
  wait "$SLEEP_PID" 2>/dev/null || true
  # Confirm manifest still exists; if not, the session was removed — exit
  [ -f "$MANIFEST" ] || exit 0
  _write_heartbeat
done
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd plugins/session-bridge && bash tests/test-heartbeat-daemon.sh
```

Expected: PASS, all 5 tests (5 assertions in Test 1-3, 1 in Test 4, 1 in Test 5 = ~10 assertions).

- [ ] **Step 5: Run full test suite**

```bash
cd plugins/session-bridge && bash test.sh
```

Expected: still passing. heartbeat-daemon.sh exists but isn't called by any other script yet — no behavioral change.

- [ ] **Step 6: Commit**

```bash
git add plugins/session-bridge/scripts/heartbeat-daemon.sh plugins/session-bridge/tests/test-heartbeat-daemon.sh
git commit -m "$(cat <<'EOF'
feat: add heartbeat-daemon.sh background producer

Dedicated background process per session writing ISO 8601 timestamps
to <session-dir>/heartbeat every HEARTBEAT_INTERVAL seconds (default
60). EXIT trap classifies the daemon's own death: if manifest
status=active, flips to "stale"; if already offline/removed, no-op.

The daemon is standalone — nothing calls it yet. Subsequent tasks
wire it into project-join.sh (launch) and close-session.sh (kill).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Launch heartbeat-daemon.sh from project-join.sh and inbox-watcher.sh's relauncher

**Files:**
- Modify: `plugins/session-bridge/scripts/project-join.sh`
- Modify: `plugins/session-bridge/tests/test-project-join.sh`

Wire up the daemon so newly-created sessions get one. Don't yet remove inbox-watcher.sh's heartbeat — they coexist for one task.

- [ ] **Step 1: Write the failing test**

Append to `plugins/session-bridge/tests/test-project-join.sh` before `print_results`:

```bash
# --- Test HB1: heartbeat-daemon is launched on session create ---
echo ""
echo "Test HB1: heartbeat-daemon.sh starts when a new session is created"
PROJECT_HB1="$TEST_TMPDIR/proj-hb1"
mkdir -p "$PROJECT_HB1/.claude"
SID_HB1=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_HB1" \
  bash "$JOIN" "$PROJECT_NAME" --role specialist --name "hb1-test")
sleep 2  # give daemon time to write first heartbeat
HB_FILE="$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$SID_HB1/heartbeat"
PID_FILE="$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$SID_HB1/heartbeat-daemon.pid"
assert_file_exists "heartbeat file created" "$HB_FILE"
assert_file_exists "heartbeat-daemon PID file created" "$PID_FILE"
DAEMON_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
  echo "  PASS: heartbeat-daemon is alive"; PASS=$((PASS + 1))
  kill "$DAEMON_PID" 2>/dev/null || true
else
  echo "  FAIL: heartbeat-daemon not alive"; FAIL=$((FAIL + 1))
fi
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd plugins/session-bridge && bash tests/test-project-join.sh
```

Expected: FAIL on `heartbeat file created`.

- [ ] **Step 3: Wire daemon launch into project-join.sh**

In `plugins/session-bridge/scripts/project-join.sh`, find the existing inbox-watcher launch in the "Create new session" path (near the bottom of the file, after the manifest write):

```bash
# Start inbox watcher in background — verify it actually started
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCHER_SCRIPT="$SCRIPT_DIR/inbox-watcher.sh"
if [ -f "$WATCHER_SCRIPT" ]; then
  BRIDGE_DIR="$BRIDGE_DIR" bash "$WATCHER_SCRIPT" "$SESSION_ID" "$PROJECT_NAME" >/dev/null 2>&1 &
  WATCHER_PID=$!
  ...
fi
```

Immediately after the watcher launch block (still inside the "Create new session" path, before `echo -n "$SESSION_ID"`), add:

```bash
# Start heartbeat daemon (separate from watcher; owns the heartbeat file)
HEARTBEAT_SCRIPT="$SCRIPT_DIR/heartbeat-daemon.sh"
if [ -f "$HEARTBEAT_SCRIPT" ]; then
  bash "$HEARTBEAT_SCRIPT" "$SESSION_DIR" >/dev/null 2>&1 &
  HB_PID=$!
  sleep 0.1
  if kill -0 "$HB_PID" 2>/dev/null; then
    disown "$HB_PID" 2>/dev/null || true
  else
    echo "Warning: heartbeat-daemon failed to start" >&2
  fi
fi
```

Also add the same block in the "Reuse existing session" path, immediately after the existing watcher-restart block, but only launch if no daemon is already running. Find the block:

```bash
if [ "$NEED_WATCHER" = true ]; then
  BRIDGE_DIR="$BRIDGE_DIR" bash "$WATCHER_SCRIPT" "$EXISTING_ID" "$PROJECT_NAME" >/dev/null 2>&1 &
  WATCHER_PID=$!
  ...
fi
```

After that `fi`, add:

```bash
# Heartbeat daemon: launch if not already running for this session
HEARTBEAT_SCRIPT="$SCRIPT_DIR/heartbeat-daemon.sh"
HB_PID_FILE="$EXISTING_DIR/heartbeat-daemon.pid"
NEED_HEARTBEAT=true
if [ -f "$HB_PID_FILE" ]; then
  OLD_HB_PID=$(cat "$HB_PID_FILE" 2>/dev/null || echo "")
  if [ -n "$OLD_HB_PID" ] && kill -0 "$OLD_HB_PID" 2>/dev/null; then
    NEED_HEARTBEAT=false
  fi
fi
if [ "$NEED_HEARTBEAT" = true ] && [ -f "$HEARTBEAT_SCRIPT" ]; then
  bash "$HEARTBEAT_SCRIPT" "$EXISTING_DIR" >/dev/null 2>&1 &
  HB_PID=$!
  sleep 0.1
  kill -0 "$HB_PID" 2>/dev/null && disown "$HB_PID" 2>/dev/null || true
fi
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd plugins/session-bridge && bash tests/test-project-join.sh
```

Expected: PASS on HB1, and all prior tests still pass.

- [ ] **Step 5: Run full test suite**

```bash
cd plugins/session-bridge && bash test.sh
```

Expected: still green. New sessions now spawn the heartbeat daemon alongside the watcher.

- [ ] **Step 6: Commit**

```bash
git add plugins/session-bridge/scripts/project-join.sh plugins/session-bridge/tests/test-project-join.sh
git commit -m "$(cat <<'EOF'
feat: launch heartbeat-daemon.sh on session create/reuse

project-join.sh now spawns heartbeat-daemon.sh alongside
inbox-watcher.sh in both the create-new-session and
reuse-existing-session paths. The daemon writes timestamps to
<session-dir>/heartbeat every 60s and is independent of the watcher.

inbox-watcher.sh's heartbeat-writing duties remain in place for
this commit — they will be removed in a subsequent task once all
consumers have been migrated to read from the new heartbeat file.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Migrate list-peers.sh to use new stale-check + heartbeat file

**Files:**
- Modify: `plugins/session-bridge/scripts/list-peers.sh`
- Modify: `plugins/session-bridge/tests/test-list-peers.sh`

`list-peers.sh` currently uses `lastHeartbeat` field with a 300s threshold; migrate to use `is_stale` from the lib (which reads `<session>/heartbeat` file + PID check). Add `offline` to the displayed states.

- [ ] **Step 1: Write the failing test**

Append to `plugins/session-bridge/tests/test-list-peers.sh` before `print_results`:

```bash
# --- Test LP-S1: list-peers displays offline status from manifest ---
echo ""
echo "Test LP-S1: offline status shown in /bridge peers output"
# Manually set a session's status to offline
TARGET_MANIFEST="$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$SESSION_B/manifest.json"
TMP=$(mktemp "$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$SESSION_B/manifest.XXXXXX")
jq '.status = "offline"' "$TARGET_MANIFEST" > "$TMP" && mv "$TMP" "$TARGET_MANIFEST"
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST_PEERS" --project "$PROJECT_NAME")
assert_contains "displays offline" "offline" "$OUTPUT"

# --- Test LP-S2: stale status detected via lib (no heartbeat file + status=active) ---
echo ""
echo "Test LP-S2: stale status detected when status=active but no heartbeat file"
# Flip back to active, but no heartbeat file
TMP=$(mktemp "$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$SESSION_B/manifest.XXXXXX")
jq '.status = "active"' "$TARGET_MANIFEST" > "$TMP" && mv "$TMP" "$TARGET_MANIFEST"
rm -f "$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$SESSION_B/heartbeat"
rm -f "$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$SESSION_B/heartbeat-daemon.pid"
OUTPUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$LIST_PEERS" --project "$PROJECT_NAME")
assert_contains "displays stale" "stale" "$OUTPUT"
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd plugins/session-bridge && bash tests/test-list-peers.sh
```

Expected: FAIL on `displays offline` and `displays stale`.

- [ ] **Step 3: Migrate list-peers.sh to use the lib**

Replace the project-scoped loop in `plugins/session-bridge/scripts/list-peers.sh:33-46` with:

```bash
  for MANIFEST in "$PROJ_SESSIONS_DIR"/*/manifest.json; do
    [ -f "$MANIFEST" ] || continue
    SID=$(jq -r '.sessionId' "$MANIFEST")
    PNAME=$(jq -r '.projectName' "$MANIFEST")
    ROLE=$(jq -r '.role // ""' "$MANIFEST")
    SPEC=$(jq -r '.specialty // ""' "$MANIFEST")
    MANIFEST_STATUS=$(jq -r '.status // "active"' "$MANIFEST")
    SESSION_PATH="$(dirname "$MANIFEST")"

    # Determine display status:
    #   - "offline" or "removed" → as-is
    #   - "stale" → as-is (already detected by lib elsewhere or by daemon EXIT trap)
    #   - "active" → check via is_stale (may flip to stale due to silent producer)
    case "$MANIFEST_STATUS" in
      offline|removed|stale)
        STATUS="$MANIFEST_STATUS"
        ;;
      active)
        if is_stale "$SESSION_PATH" "$STALE_SECONDS"; then
          # On-demand stale-flip: write it back so consumers see it
          set_status "$MANIFEST" "stale"
          STATUS="stale"
        else
          STATUS="active"
        fi
        ;;
      *)
        STATUS="$MANIFEST_STATUS"
        ;;
    esac

    printf "  %-10s %-20s %-12s %-15s %s\n" "$SID" "$PNAME" "$ROLE" "$STATUS" "$SPEC"
    FOUND=$((FOUND + 1))
  done
```

Also at the top of the file, after `BRIDGE_DIR=...`, add the lib source:

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/stale-check.sh
source "$SCRIPT_DIR/lib/stale-check.sh"
```

Apply the same status-resolution change to the legacy-sessions block (lines 54-83 originally) — replace its `STATUS=...` computation with the same case block.

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd plugins/session-bridge && bash tests/test-list-peers.sh
```

Expected: PASS on LP-S1, LP-S2, all prior tests still pass.

- [ ] **Step 5: Run full test suite**

```bash
cd plugins/session-bridge && bash test.sh
```

Expected: still green.

- [ ] **Step 6: Commit**

```bash
git add plugins/session-bridge/scripts/list-peers.sh plugins/session-bridge/tests/test-list-peers.sh
git commit -m "$(cat <<'EOF'
feat: list-peers.sh reads new heartbeat file + surfaces offline/stale

Migrates the status-display logic from the misnamed lastHeartbeat
timestamp to is_stale() from scripts/lib/stale-check.sh. Adds
"offline" as a first-class displayed state (was indistinguishable
from "active" before because nothing wrote it). Surfaces "stale"
when the heartbeat-daemon's PID is dead AND the heartbeat file
is older than STALE_SECONDS.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Migrate send-message.sh to use new stale-check + emit recipient-stale notification

**Files:**
- Modify: `plugins/session-bridge/scripts/send-message.sh`
- Modify: `plugins/session-bridge/tests/test-send-message.sh`

Add `recipient-stale` and `session-removed` to valid message types. Before delivery, check whether the recipient is stale; if so, flip recipient's status, deliver the original message, AND emit a synthetic `recipient-stale` notification back to the sender.

- [ ] **Step 1: Write the failing test**

Append to `plugins/session-bridge/tests/test-send-message.sh` before `print_results`:

```bash
# --- Test SM-S1: send to active recipient — no stale notification ---
echo ""
echo "Test SM-S1: send to active recipient does not generate recipient-stale"
# A is sender, B is recipient — both fresh
MSG_ID_S1=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" \
  bash "$SEND" "$TARGET_ID" query "hello fresh" 2>/dev/null)
# Sender inbox should NOT have a recipient-stale notification
NOTIF_COUNT=$(find "$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$SENDER_ID/inbox" \
  -maxdepth 1 -name "*.json" -exec grep -l '"type":"recipient-stale"' {} \; 2>/dev/null | wc -l)
assert_eq "no recipient-stale for fresh recipient" "0" "$NOTIF_COUNT"

# --- Test SM-S2: send to stale recipient → still delivers, emits recipient-stale ---
echo ""
echo "Test SM-S2: send to stale recipient delivers + emits recipient-stale"
# Force recipient B into stale-detectable state:
# Status=active, no heartbeat file, no daemon PID file
TARGET_DIR="$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$TARGET_ID"
TMP=$(mktemp "$TARGET_DIR/manifest.XXXXXX")
jq '.status = "active"' "$TARGET_DIR/manifest.json" > "$TMP" && mv "$TMP" "$TARGET_DIR/manifest.json"
rm -f "$TARGET_DIR/heartbeat" "$TARGET_DIR/heartbeat-daemon.pid"

MSG_ID_S2=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" \
  bash "$SEND" "$TARGET_ID" query "to stale recipient" 2>/dev/null)
# Original message DID land in recipient's inbox
ORIG_IN_TARGET=$(find "$TARGET_DIR/inbox" -maxdepth 1 -name "$MSG_ID_S2.json" 2>/dev/null | wc -l)
assert_eq "original message delivered to recipient inbox" "1" "$ORIG_IN_TARGET"
# Recipient status was flipped to stale
assert_json_field "recipient flipped to stale" "$TARGET_DIR/manifest.json" ".status" "stale"
# Sender got a recipient-stale notification back
NOTIF=$(find "$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$SENDER_ID/inbox" \
  -maxdepth 1 -name "*.json" -exec grep -l '"type":"recipient-stale"' {} \; 2>/dev/null | head -1)
if [ -n "$NOTIF" ]; then
  echo "  PASS: sender received recipient-stale notification"; PASS=$((PASS + 1))
  assert_contains "notification mentions stale recipient id" "$TARGET_ID" "$(cat "$NOTIF")"
else
  echo "  FAIL: no recipient-stale notification in sender inbox"; FAIL=$((FAIL + 1))
fi

# --- Test SM-S3: recipient-stale type is accepted by validation ---
echo ""
echo "Test SM-S3: recipient-stale and session-removed pass type validation"
# Reset B to active so we can send to it
TMP=$(mktemp "$TARGET_DIR/manifest.XXXXXX")
jq '.status = "active"' "$TARGET_DIR/manifest.json" > "$TMP" && mv "$TMP" "$TARGET_DIR/manifest.json"
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$TARGET_DIR/heartbeat"
# Sending a recipient-stale message manually should not error on type validation
OUT=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" \
  bash "$SEND" "$TARGET_ID" recipient-stale "manual test" 2>&1 || true)
if echo "$OUT" | grep -q "Unknown message type"; then
  echo "  FAIL: recipient-stale rejected by type validation"; FAIL=$((FAIL + 1))
else
  echo "  PASS: recipient-stale accepted"; PASS=$((PASS + 1))
fi
OUT=$(BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SENDER_ID" \
  bash "$SEND" "$TARGET_ID" session-removed "manual test" 2>&1 || true)
if echo "$OUT" | grep -q "Unknown message type"; then
  echo "  FAIL: session-removed rejected"; FAIL=$((FAIL + 1))
else
  echo "  PASS: session-removed accepted"; PASS=$((PASS + 1))
fi
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd plugins/session-bridge && bash tests/test-send-message.sh
```

Expected: FAIL on `recipient flipped to stale`, `sender received recipient-stale notification`, and possibly the type-validation tests.

- [ ] **Step 3: Update VALID_TYPES and add stale-detection block in send-message.sh**

In `plugins/session-bridge/scripts/send-message.sh`, line 16:

```diff
-VALID_TYPES=" ping query response task-assign task-update task-complete task-cancel escalate task-redirect human-input-needed human-response routing-query session-ended "
+VALID_TYPES=" ping query response task-assign task-update task-complete task-cancel escalate task-redirect human-input-needed human-response routing-query session-ended session-removed recipient-stale "
```

Also update the error message on line 19 to match.

Then, near the top after the BRIDGE_DIR assignment, source the lib:

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/stale-check.sh
source "$SCRIPT_DIR/lib/stale-check.sh"
```

After the existing path resolution (after line 76 where it checks `[ ! -d "$TARGET_INBOX" ]`), but BEFORE the conversation-management block, add:

```bash
# --- Stale-recipient detection ---
# If recipient is stale at delivery time, flip its status, deliver the message
# normally (it queues in the inbox), and remember to emit a recipient-stale
# notification back to the sender after the main send completes.
RECIPIENT_STALE_DETECTED=false
RECIPIENT_STALE_HEARTBEAT=""
RECIPIENT_NAME="unknown"
STALE_THRESHOLD_SEC="${BRIDGE_STALE_THRESHOLD:-300}"

# Only check stale-ness when delivering to project-scoped session
# (legacy sessions don't have the new heartbeat plumbing)
if [ -n "$SENDER_PROJECT_ID" ] && [ "$MSG_TYPE" != "recipient-stale" ]; then
  TARGET_DIR="$BRIDGE_DIR/projects/$SENDER_PROJECT_ID/sessions/$TARGET_ID"
  if [ -d "$TARGET_DIR" ] && is_stale "$TARGET_DIR" "$STALE_THRESHOLD_SEC"; then
    RECIPIENT_STALE_DETECTED=true
    RECIPIENT_STALE_HEARTBEAT=$(cat "$TARGET_DIR/heartbeat" 2>/dev/null | head -1 || echo "unknown")
    RECIPIENT_NAME=$(jq -r '.projectName // "unknown"' "$TARGET_DIR/manifest.json" 2>/dev/null)
    set_status "$TARGET_DIR/manifest.json" "stale"
  fi
fi
```

At the end of the file (after the existing outbox-copy block, before `echo -n "$MSG_ID"`), add the notification emission:

```bash
# --- Emit recipient-stale notification back to sender if needed ---
if [ "$RECIPIENT_STALE_DETECTED" = true ]; then
  NOTIF_ID="msg-$(set +o pipefail; LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 12)"
  NOTIF_NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  NOTIF_CONTENT="Recipient $RECIPIENT_NAME ($TARGET_ID) is unresponsive. Last heartbeat: ${RECIPIENT_STALE_HEARTBEAT}. Message $MSG_ID was still delivered to recipient's inbox — it will be processed when the session revives. You may want to nudge the user to reopen the session."
  SENDER_INBOX="$BRIDGE_DIR/projects/$SENDER_PROJECT_ID/sessions/$SENDER_ID/inbox"
  if [ -d "$SENDER_INBOX" ]; then
    NOTIF_JSON=$(jq -n \
      --arg pv "2.0" \
      --arg id "$NOTIF_ID" \
      --arg from "$TARGET_ID" \
      --arg to "$SENDER_ID" \
      --arg type "recipient-stale" \
      --arg ts "$NOTIF_NOW" \
      --arg content "$NOTIF_CONTENT" \
      --arg fromProject "$SENDER_PROJECT" \
      --arg origMsg "$MSG_ID" \
      --arg staleId "$TARGET_ID" \
      --arg staleName "$RECIPIENT_NAME" \
      --arg lastHb "$RECIPIENT_STALE_HEARTBEAT" \
      --arg staleSince "$NOTIF_NOW" \
      '{
        protocolVersion: $pv,
        id: $id,
        conversationId: null,
        from: $from,
        to: $to,
        type: $type,
        timestamp: $ts,
        status: "pending",
        content: $content,
        inReplyTo: null,
        metadata: {
          urgency: "normal",
          fromProject: $fromProject,
          originalMessageId: $origMsg,
          staleRecipientId: $staleId,
          staleRecipientName: $staleName,
          lastHeartbeat: $lastHb,
          staleSince: $staleSince
        }
      }')
    NOTIF_TMP=$(mktemp "$SENDER_INBOX/$NOTIF_ID.XXXXXX")
    echo "$NOTIF_JSON" > "$NOTIF_TMP"
    mv "$NOTIF_TMP" "$SENDER_INBOX/$NOTIF_ID.json" || rm -f "$NOTIF_TMP"
  fi
fi
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd plugins/session-bridge && bash tests/test-send-message.sh
```

Expected: PASS on SM-S1, SM-S2, SM-S3.

- [ ] **Step 5: Run full test suite**

```bash
cd plugins/session-bridge && bash test.sh
```

Expected: still green.

- [ ] **Step 6: Commit**

```bash
git add plugins/session-bridge/scripts/send-message.sh plugins/session-bridge/tests/test-send-message.sh
git commit -m "$(cat <<'EOF'
feat: stale-recipient detection + recipient-stale notification

send-message.sh now checks the recipient's stale status (via
is_stale from the lib) before delivery. If stale, the recipient's
manifest is flipped to status=stale, the original message is
delivered normally (queues in the inbox), and a synthetic
recipient-stale notification is generated back to the sender so the
orchestrator surfaces "specialist unresponsive" to the user.

Adds recipient-stale and session-removed to the valid message
types list. The orchestrator skill will be updated in a subsequent
task to handle the recipient-stale type with a special visibility
line.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Create close-session.sh (graceful offline)

**Files:**
- Create: `plugins/session-bridge/scripts/close-session.sh`
- Create: `plugins/session-bridge/tests/test-close-session.sh`

New SessionEnd hook target. Does NOT destroy anything; transitions status to `offline`, kills the heartbeat daemon and listener, removes ephemeral PID files.

- [ ] **Step 1: Write the failing test**

Create `plugins/session-bridge/tests/test-close-session.sh`:

```bash
#!/usr/bin/env bash
# tests/test-close-session.sh — Tests for scripts/close-session.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
CREATE_PROJECT="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"
CLOSE="$PLUGIN_DIR/scripts/close-session.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_NAME="close-test"
PROJECT_A="$TEST_TMPDIR/proj-a"
mkdir -p "$PROJECT_A/.claude"

BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$CREATE_PROJECT" "$PROJECT_NAME" >/dev/null
SID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$JOIN" "$PROJECT_NAME" --role specialist --name "close-test")
sleep 2  # heartbeat daemon writes

echo "=== test-close-session.sh ==="
echo "  session=$SID"

SESSION_DIR="$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$SID"
MANIFEST="$SESSION_DIR/manifest.json"
HB_FILE="$SESSION_DIR/heartbeat"
PID_FILE="$SESSION_DIR/heartbeat-daemon.pid"

# Pre-condition checks
assert_file_exists "manifest exists pre-close" "$MANIFEST"
assert_file_exists "heartbeat file exists pre-close" "$HB_FILE"
assert_json_field "status is active pre-close" "$MANIFEST" ".status" "active"

# --- Test 1: close-session.sh flips status to offline ---
echo ""
echo "Test 1: status flips to offline"
BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$CLOSE"
assert_json_field "status flipped to offline" "$MANIFEST" ".status" "offline"

# --- Test 2: heartbeat-daemon is killed (PID file removed by daemon's own EXIT trap) ---
echo ""
echo "Test 2: heartbeat-daemon is killed"
sleep 1  # allow trap to run
if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "  FAIL: heartbeat-daemon still alive (PID $OLD_PID)"; FAIL=$((FAIL + 1))
  else
    echo "  PASS: heartbeat-daemon dead (stale PID file removed by trap)"; PASS=$((PASS + 1))
  fi
else
  echo "  PASS: heartbeat-daemon PID file removed"; PASS=$((PASS + 1))
fi

# --- Test 3: session dir is NOT destroyed (persistence-first) ---
echo ""
echo "Test 3: session directory preserved"
assert_dir_exists "session dir preserved" "$SESSION_DIR"
assert_file_exists "manifest preserved" "$MANIFEST"
assert_file_exists "heartbeat file preserved (forensic)" "$HB_FILE"
assert_dir_exists "inbox preserved" "$SESSION_DIR/inbox"
assert_dir_exists "outbox preserved" "$SESSION_DIR/outbox"

# --- Test 4: bridge-session pointer is preserved (for resume) ---
echo ""
echo "Test 4: bridge-session pointer preserved"
assert_file_exists ".claude/bridge-session preserved" "$PROJECT_A/.claude/bridge-session"
assert_file_exists ".claude/bridge-role preserved" "$PROJECT_A/.claude/bridge-role"

# --- Test 5: close on already-offline session is idempotent (no error) ---
echo ""
echo "Test 5: close on already-offline session is idempotent"
if BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$CLOSE" 2>&1; then
  echo "  PASS: idempotent close"; PASS=$((PASS + 1))
else
  echo "  FAIL: close errored on already-offline"; FAIL=$((FAIL + 1))
fi

print_results
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd plugins/session-bridge && bash tests/test-close-session.sh
```

Expected: FAIL — script doesn't exist.

- [ ] **Step 3: Create close-session.sh**

Create `plugins/session-bridge/scripts/close-session.sh`:

```bash
#!/usr/bin/env bash
# scripts/close-session.sh — Graceful offline transition.
# Called by SessionEnd hook (non-destructive). Sets status=offline,
# kills the heartbeat-daemon + inbox-watcher + listener, removes
# ephemeral runtime PID files. Does NOT destroy session dir or
# remove bridge-session pointer — those persist for resume-session.sh.
set -euo pipefail

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
BRIDGE_SESSION_FILE="$PROJECT_DIR/.claude/bridge-session"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/stale-check.sh
source "$SCRIPT_DIR/lib/stale-check.sh"

# Find session ID
SESSION_ID=""
if [ -n "${BRIDGE_SESSION_ID:-}" ]; then
  SESSION_ID="$BRIDGE_SESSION_ID"
elif [ -f "$BRIDGE_SESSION_FILE" ]; then
  SESSION_ID=$(cat "$BRIDGE_SESSION_FILE" 2>/dev/null || echo "")
fi

if [ -z "$SESSION_ID" ]; then
  exit 0  # No bridge session here; nothing to close
fi

# Resolve session directory
SESSION_DIR=""
for PM in "$BRIDGE_DIR"/projects/*/sessions/"$SESSION_ID"/manifest.json; do
  [ -f "$PM" ] || continue
  SESSION_DIR=$(dirname "$PM")
  break
done
if [ -z "$SESSION_DIR" ] && [ -d "$BRIDGE_DIR/sessions/$SESSION_ID" ]; then
  SESSION_DIR="$BRIDGE_DIR/sessions/$SESSION_ID"
fi

if [ -z "$SESSION_DIR" ] || [ ! -d "$SESSION_DIR" ]; then
  exit 0
fi

MANIFEST="$SESSION_DIR/manifest.json"
[ -f "$MANIFEST" ] || exit 0

# Step 1 (CRITICAL ORDER): flip status to offline BEFORE killing the daemon.
# This prevents a race where the heartbeat-daemon's EXIT trap sees status=active
# and falsely marks the session as stale.
set_status "$MANIFEST" "offline"

# Step 2: kill heartbeat-daemon
HB_PID_FILE="$SESSION_DIR/heartbeat-daemon.pid"
if [ -f "$HB_PID_FILE" ]; then
  HB_PID=$(cat "$HB_PID_FILE" 2>/dev/null || echo "")
  if [ -n "$HB_PID" ] && kill -0 "$HB_PID" 2>/dev/null; then
    kill "$HB_PID" 2>/dev/null || true
  fi
fi

# Step 3: kill inbox-watcher
WATCHER_PID_FILE="$SESSION_DIR/watcher.pid"
if [ -f "$WATCHER_PID_FILE" ]; then
  W_PID=$(cat "$WATCHER_PID_FILE" 2>/dev/null || echo "")
  if [ -n "$W_PID" ] && kill -0 "$W_PID" 2>/dev/null; then
    kill "$W_PID" 2>/dev/null || true
  fi
fi

# Step 4: kill listener (bridge-listen.sh) if still in background
LISTENER_PID_FILE="$SESSION_DIR/bridge-listen-child.pid"
if [ -f "$LISTENER_PID_FILE" ]; then
  L_PID=$(cat "$LISTENER_PID_FILE" 2>/dev/null || echo "")
  if [ -n "$L_PID" ] && kill -0 "$L_PID" 2>/dev/null; then
    kill "$L_PID" 2>/dev/null || true
  fi
fi

# Step 5: remove ephemeral runtime PID files (heartbeat daemon's trap removes its own)
rm -f "$WATCHER_PID_FILE" "$LISTENER_PID_FILE" 2>/dev/null || true

# Persistence-first: do NOT remove session dir, manifest (beyond status field),
# bridge-listen.log, .delivered/, inbox, outbox, conversations,
# .claude/bridge-session, .claude/bridge-role. All preserved.

exit 0
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd plugins/session-bridge && bash tests/test-close-session.sh
```

Expected: PASS, all assertions.

- [ ] **Step 5: Run full test suite**

```bash
cd plugins/session-bridge && bash test.sh
```

Expected: still green. close-session.sh exists but isn't wired to any hook yet.

- [ ] **Step 6: Commit**

```bash
git add plugins/session-bridge/scripts/close-session.sh plugins/session-bridge/tests/test-close-session.sh
git commit -m "$(cat <<'EOF'
feat: add close-session.sh for graceful offline transition

New script for SessionEnd hook (not yet wired). Non-destructive:
flips status=offline FIRST (preventing race with daemon's EXIT
trap), then kills heartbeat-daemon, watcher, listener. Preserves
session dir, manifest, logs, .delivered archive, inbox, outbox,
conversations, and bridge-session pointer for resume-session.sh.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Wire close-session.sh into SessionEnd hook (replace cleanup.sh's hook role)

**Files:**
- Modify: `plugins/session-bridge/hooks/hooks.json`

The SessionEnd hook currently points at `cleanup.sh`. Swap it to `close-session.sh`. We keep `cleanup.sh` on disk for this commit so any other references are not broken; Task 13 will delete it.

- [ ] **Step 1: Modify hooks.json**

In `plugins/session-bridge/hooks/hooks.json`, find:

```json
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/cleanup.sh\"",
            "async": false
          }
        ]
      }
    ],
```

Change to:

```json
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/close-session.sh\"",
            "async": false
          }
        ]
      }
    ],
```

- [ ] **Step 2: Run full test suite**

```bash
cd plugins/session-bridge && bash test.sh
```

Expected: still green. Hook config change doesn't affect tests.

- [ ] **Step 3: Commit**

```bash
git add plugins/session-bridge/hooks/hooks.json
git commit -m "$(cat <<'EOF'
feat: SessionEnd hook now runs close-session.sh (non-destructive)

Cleanup behavior on /exit changes from destructive (cleanup.sh
removed session dir, notified peers) to non-destructive
(close-session.sh flips status=offline, kills daemons, preserves
everything). cleanup.sh stays on disk for one more commit
while we migrate its other responsibilities.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Create resume-session.sh and re-point auto-join.sh

**Files:**
- Create: `plugins/session-bridge/scripts/resume-session.sh`
- Create: `plugins/session-bridge/tests/test-resume-session.sh`
- Modify: `plugins/session-bridge/scripts/auto-join.sh`

`resume-session.sh` adopts an existing session ID by reading `.claude/bridge-session` and verifying the session dir + manifest still exist. Fails LOUDLY if missing (no silent new-ID creation).

- [ ] **Step 1: Write the failing test**

Create `plugins/session-bridge/tests/test-resume-session.sh`:

```bash
#!/usr/bin/env bash
# tests/test-resume-session.sh — Tests for scripts/resume-session.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREATE_PROJECT="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"
CLOSE="$PLUGIN_DIR/scripts/close-session.sh"
RESUME="$PLUGIN_DIR/scripts/resume-session.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_NAME="resume-test"
PROJECT_A="$TEST_TMPDIR/proj-a"
mkdir -p "$PROJECT_A/.claude"

BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$CREATE_PROJECT" "$PROJECT_NAME" >/dev/null
ORIGINAL_SID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$JOIN" "$PROJECT_NAME" --role specialist --name "resume-test")

echo "=== test-resume-session.sh ==="
echo "  original_sid=$ORIGINAL_SID"

# Cleanly close the session first
BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$CLOSE"
sleep 1

# --- Test 1: resume picks up existing session ID ---
echo ""
echo "Test 1: resume adopts existing session ID"
RESUMED_SID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$RESUME" 2>&1)
assert_eq "resumed SID matches original" "$ORIGINAL_SID" "$RESUMED_SID"

# --- Test 2: resume flips status back to active ---
echo ""
echo "Test 2: status flips offline → active on resume"
MANIFEST="$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$ORIGINAL_SID/manifest.json"
assert_json_field "status is active after resume" "$MANIFEST" ".status" "active"

# --- Test 3: heartbeat daemon is restarted ---
echo ""
echo "Test 3: heartbeat-daemon restarted on resume"
sleep 2
PID_FILE="$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$ORIGINAL_SID/heartbeat-daemon.pid"
assert_file_exists "heartbeat-daemon.pid exists after resume" "$PID_FILE"
HB_PID=$(cat "$PID_FILE")
if kill -0 "$HB_PID" 2>/dev/null; then
  echo "  PASS: heartbeat-daemon alive"; PASS=$((PASS + 1))
  kill "$HB_PID" 2>/dev/null || true
else
  echo "  FAIL: heartbeat-daemon not alive (PID=$HB_PID)"; FAIL=$((FAIL + 1))
fi

# --- Test 4: resume from stale → active also works ---
echo ""
echo "Test 4: resume from stale flips to active"
# Force stale by setting manifest status=stale
TMP=$(mktemp "$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$ORIGINAL_SID/manifest.XXXXXX")
jq '.status = "stale"' "$MANIFEST" > "$TMP" && mv "$TMP" "$MANIFEST"
RESUMED_SID2=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$RESUME" 2>&1)
assert_eq "stale resume yields original SID" "$ORIGINAL_SID" "$RESUMED_SID2"
assert_json_field "stale flipped to active" "$MANIFEST" ".status" "active"
# Kill the daemon spawned by this test step
sleep 2
NEW_HB_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
[ -n "$NEW_HB_PID" ] && kill "$NEW_HB_PID" 2>/dev/null || true

# --- Test 5: resume errors loudly if session dir is gone ---
echo ""
echo "Test 5: resume errors loudly when session was removed"
# Destroy the session dir to simulate /bridge remove
rm -rf "$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$ORIGINAL_SID"
# bridge-session pointer still says ORIGINAL_SID — but the dir is gone
OUT=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$RESUME" 2>&1 || true)
if echo "$OUT" | grep -q "no longer exists"; then
  echo "  PASS: emits loud error"; PASS=$((PASS + 1))
else
  echo "  FAIL: expected loud error about missing session"; FAIL=$((FAIL + 1))
  echo "    actual: $OUT"
fi
# AND should not silently mint a new ID
if echo "$OUT" | grep -qE '^[a-z0-9]{6}$'; then
  echo "  FAIL: silently minted new ID (forbidden)"; FAIL=$((FAIL + 1))
else
  echo "  PASS: did not silently mint new ID"; PASS=$((PASS + 1))
fi

print_results
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd plugins/session-bridge && bash tests/test-resume-session.sh
```

Expected: FAIL — resume-session.sh doesn't exist.

- [ ] **Step 3: Create resume-session.sh**

Create `plugins/session-bridge/scripts/resume-session.sh`:

```bash
#!/usr/bin/env bash
# scripts/resume-session.sh — Re-bind a Claude Code session to its existing bridge identity.
# Called by auto-join.sh (SessionStart hook target).
# Reads .claude/bridge-role for project context and .claude/bridge-session for prior SID.
# If valid: flips status active, restarts heartbeat-daemon, outputs SID.
# If invalid (session dir gone): emits loud error to stderr, does NOT silently
# create a new SID. Returns nonzero so auto-join.sh surfaces the error.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
BRIDGE_SESSION_FILE="$PROJECT_DIR/.claude/bridge-session"
BRIDGE_ROLE_FILE="$PROJECT_DIR/.claude/bridge-role"

if [ ! -f "$BRIDGE_ROLE_FILE" ]; then
  echo "Error: no .claude/bridge-role in $PROJECT_DIR — run /bridge project join first" >&2
  exit 1
fi
if [ ! -f "$BRIDGE_SESSION_FILE" ]; then
  echo "Error: no .claude/bridge-session in $PROJECT_DIR — run /bridge project join first" >&2
  exit 1
fi

PROJECT_NAME=$(jq -r '.project // ""' "$BRIDGE_ROLE_FILE")
SESSION_ID=$(cat "$BRIDGE_SESSION_FILE" 2>/dev/null | head -c 6)

if [ -z "$PROJECT_NAME" ] || [ -z "$SESSION_ID" ]; then
  echo "Error: corrupt .claude/bridge-* files in $PROJECT_DIR" >&2
  exit 1
fi

SESSION_DIR="$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$SESSION_ID"
MANIFEST="$SESSION_DIR/manifest.json"

if [ ! -d "$SESSION_DIR" ] || [ ! -f "$MANIFEST" ]; then
  cat >&2 <<EOF
=== BRIDGE RESUME FAILED ===
Session $SESSION_ID no longer exists in project $PROJECT_NAME.
This means the session was explicitly removed (/bridge remove)
or destroyed (long-term cleanup).
Run: /bridge project join $PROJECT_NAME
to re-register with a new ID. Existing conversations addressed
to the old ID will need to be re-routed.
=== END BRIDGE ===
EOF
  exit 1
fi

# Update manifest: flip status → active, refresh heartbeat field, apply role updates if changed
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAVED_ROLE=$(jq -r '.role // ""' "$BRIDGE_ROLE_FILE")
SAVED_SPEC=$(jq -r '.specialty // ""' "$BRIDGE_ROLE_FILE")
SAVED_NAME=$(jq -r '.name // ""' "$BRIDGE_ROLE_FILE")

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TMP=$(mktemp "$SESSION_DIR/manifest.XXXXXX")
jq --arg hb "$NOW" \
   --arg status "active" \
   --arg role "$SAVED_ROLE" \
   --arg spec "$SAVED_SPEC" \
   --arg name "$SAVED_NAME" \
   '.lastHeartbeat = $hb | .status = $status | .role = ($role // .role) | .specialty = ($spec // .specialty) | .projectName = ($name // .projectName)' \
   "$MANIFEST" > "$TMP" && mv "$TMP" "$MANIFEST" || { rm -f "$TMP"; exit 1; }

# Restart inbox-watcher if dead
WATCHER_SCRIPT="$SCRIPT_DIR/inbox-watcher.sh"
WATCHER_PID_FILE="$SESSION_DIR/watcher.pid"
NEED_WATCHER=true
if [ -f "$WATCHER_PID_FILE" ]; then
  OLD_W_PID=$(cat "$WATCHER_PID_FILE" 2>/dev/null || echo "")
  [ -n "$OLD_W_PID" ] && kill -0 "$OLD_W_PID" 2>/dev/null && NEED_WATCHER=false
fi
if [ "$NEED_WATCHER" = true ] && [ -f "$WATCHER_SCRIPT" ]; then
  BRIDGE_DIR="$BRIDGE_DIR" bash "$WATCHER_SCRIPT" "$SESSION_ID" "$PROJECT_NAME" >/dev/null 2>&1 &
  W_PID=$!
  sleep 0.1
  kill -0 "$W_PID" 2>/dev/null && echo "$W_PID" > "$WATCHER_PID_FILE" && disown "$W_PID" 2>/dev/null || true
fi

# Restart heartbeat-daemon if dead
HEARTBEAT_SCRIPT="$SCRIPT_DIR/heartbeat-daemon.sh"
HB_PID_FILE="$SESSION_DIR/heartbeat-daemon.pid"
NEED_HEARTBEAT=true
if [ -f "$HB_PID_FILE" ]; then
  OLD_HB_PID=$(cat "$HB_PID_FILE" 2>/dev/null || echo "")
  [ -n "$OLD_HB_PID" ] && kill -0 "$OLD_HB_PID" 2>/dev/null && NEED_HEARTBEAT=false
fi
if [ "$NEED_HEARTBEAT" = true ] && [ -f "$HEARTBEAT_SCRIPT" ]; then
  bash "$HEARTBEAT_SCRIPT" "$SESSION_DIR" >/dev/null 2>&1 &
  HB_PID=$!
  sleep 0.1
  kill -0 "$HB_PID" 2>/dev/null && disown "$HB_PID" 2>/dev/null || true
fi

# Emit the SID for auto-join.sh
echo -n "$SESSION_ID"
```

- [ ] **Step 4: Modify auto-join.sh to delegate to resume-session.sh**

In `plugins/session-bridge/scripts/auto-join.sh`, find the line that calls `project-join.sh`:

```bash
SESSION_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_DIR" bash "$SCRIPT_DIR/project-join.sh" "$PROJECT_NAME" 2>"$JOIN_ERR_FILE") || {
```

Change to:

```bash
SESSION_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_DIR" bash "$SCRIPT_DIR/resume-session.sh" 2>"$JOIN_ERR_FILE") || {
```

Also update the error message variable from "Could not rejoin project" to be a bit more specific:

```diff
-  ERRMSG="=== BRIDGE AUTO-JOIN FAILED ===\nCould not rejoin project '${PROJECT_NAME}'.\nDetail: ${DETAIL}\nRun: /bridge project join ${PROJECT_NAME}\n=== END BRIDGE ==="
+  ERRMSG="=== BRIDGE RESUME FAILED ===\nCould not resume session in project '${PROJECT_NAME}'.\nDetail: ${DETAIL}\nRun: /bridge project join ${PROJECT_NAME}\n=== END BRIDGE ==="
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd plugins/session-bridge && bash tests/test-resume-session.sh && bash tests/test-auto-join.sh
```

Expected: PASS on resume-session tests. test-auto-join may need small adjustments if it expected the old project-join.sh call — fix any failures by updating the test expectations to match the new error message format.

- [ ] **Step 6: Run full test suite**

```bash
cd plugins/session-bridge && bash test.sh
```

Expected: still green.

- [ ] **Step 7: Commit**

```bash
git add plugins/session-bridge/scripts/resume-session.sh plugins/session-bridge/scripts/auto-join.sh plugins/session-bridge/tests/test-resume-session.sh plugins/session-bridge/tests/test-auto-join.sh
git commit -m "$(cat <<'EOF'
feat: resume-session.sh adopts existing bridge identity

Replaces project-join.sh's reuse-on-resume path with a dedicated
script invoked from the SessionStart hook (via auto-join.sh).
Flips status offline|stale → active, restarts heartbeat-daemon
and inbox-watcher if dead, emits the existing SID.

Critical: errors LOUDLY (does NOT silently mint a new ID) if the
session dir was removed. This was the root cause of the original
issue user filed: a session destroyed by cleanup.sh's stale-prune
would silently reappear as a new SID, orphaning all in-flight
conversations.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Refactor project-join.sh to first-time-only strict mode

**Files:**
- Modify: `plugins/session-bridge/scripts/project-join.sh`
- Modify: `plugins/session-bridge/tests/test-project-join.sh`

Now that `resume-session.sh` owns the reuse path, `project-join.sh` becomes strict: it errors if `.claude/bridge-session` already exists or if a session for this project+path is already registered.

- [ ] **Step 1: Write the failing test**

Append to `plugins/session-bridge/tests/test-project-join.sh` before `print_results`:

```bash
# --- Test ST1: project-join errors if .claude/bridge-session already exists ---
echo ""
echo "Test ST1: project-join errors when bridge-session pointer exists"
PROJECT_ST1="$TEST_TMPDIR/proj-st1"
mkdir -p "$PROJECT_ST1/.claude"
SID_ST1=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_ST1" bash "$JOIN" "$PROJECT_NAME" --role specialist --name "st1")
# Try to join again — should error
OUT=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_ST1" bash "$JOIN" "$PROJECT_NAME" 2>&1 || true)
if echo "$OUT" | grep -q "already.*member\|already.*registered"; then
  echo "  PASS: rejects re-join with existing bridge-session"; PASS=$((PASS + 1))
else
  echo "  FAIL: expected 'already a member' error, got: $OUT"; FAIL=$((FAIL + 1))
fi
# Cleanup
HB_PID_ST1=$(cat "$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$SID_ST1/heartbeat-daemon.pid" 2>/dev/null || echo "")
[ -n "$HB_PID_ST1" ] && kill "$HB_PID_ST1" 2>/dev/null || true
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd plugins/session-bridge && bash tests/test-project-join.sh
```

Expected: FAIL — second join silently reuses today, doesn't error.

- [ ] **Step 3: Refactor project-join.sh**

In `plugins/session-bridge/scripts/project-join.sh`, find the entire "Reuse existing session if bridge-session file points to a valid session in this project" block (currently lines 65-103). DELETE it.

Then, immediately after the `[ -z "$ROLE" ] && ROLE="specialist"` line (around line 63), insert this strict check:

```bash
# Strict mode: error if this PROJECT_DIR is already a member.
# Resumption is the job of resume-session.sh, not project-join.sh.
if [ -f "$BRIDGE_SESSION_FILE" ]; then
  EXISTING_ID=$(cat "$BRIDGE_SESSION_FILE" 2>/dev/null || echo "")
  if [ -n "$EXISTING_ID" ]; then
    EXISTING_DIR="$PROJECT_PATH/sessions/$EXISTING_ID"
    if [ -d "$EXISTING_DIR" ]; then
      echo "Error: $PROJECT_DIR is already a member of project '$PROJECT_NAME' as session $EXISTING_ID." >&2
      echo "  - To resume that session, just restart Claude Code (SessionStart hook auto-resumes)." >&2
      echo "  - To replace it with a new session, run: /bridge remove $EXISTING_ID" >&2
      exit 1
    fi
  fi
fi
```

Also, the existing daemon-restart code in the (now-removed) reuse block can be deleted since `resume-session.sh` handles it.

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd plugins/session-bridge && bash tests/test-project-join.sh
```

Expected: PASS on ST1 and all prior tests still pass.

- [ ] **Step 5: Run full test suite**

```bash
cd plugins/session-bridge && bash test.sh
```

Expected: still green. NOTE: any test that depended on `project-join.sh`'s reuse behavior may need updates; if so, fix them by routing through `resume-session.sh` instead.

- [ ] **Step 6: Commit**

```bash
git add plugins/session-bridge/scripts/project-join.sh plugins/session-bridge/tests/test-project-join.sh
git commit -m "$(cat <<'EOF'
refactor: project-join.sh is strict first-time only

Removes the "reuse existing session" path (moved to
resume-session.sh in the prior task). Now errors if PROJECT_DIR
already has .claude/bridge-session pointing to a valid session.
Caller is directed to either restart Claude Code (resume) or
explicitly /bridge remove the existing session first.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Strip heartbeat duties from inbox-watcher.sh

**Files:**
- Modify: `plugins/session-bridge/scripts/inbox-watcher.sh`
- Modify: `plugins/session-bridge/tests/test-inbox-watcher.sh`

heartbeat-daemon.sh now owns the heartbeat. Remove the redundant heartbeat-writing from inbox-watcher.sh.

- [ ] **Step 1: Update test expectations**

Find any test in `plugins/session-bridge/tests/test-inbox-watcher.sh` that asserts inbox-watcher.sh updates `lastHeartbeat`. Remove or update those assertions. (Other tests that just verify it watches the inbox should be untouched.)

Find the manifest-update test by grepping:

```bash
grep -n "lastHeartbeat\|update_heartbeat\|heartbeat" plugins/session-bridge/tests/test-inbox-watcher.sh
```

Update any failing-after-refactor test to instead assert that inbox-watcher.sh does NOT update `lastHeartbeat` (proving heartbeat-daemon is the sole writer).

- [ ] **Step 2: Modify inbox-watcher.sh**

In `plugins/session-bridge/scripts/inbox-watcher.sh`:

1. Delete the `update_heartbeat()` function (lines 21-28).
2. Delete the `LAST_HEARTBEAT`, `HEARTBEAT_INTERVAL` variables (lines 30-31).
3. Delete the heartbeat check inside the loop (lines 56-61):
   ```diff
   -  # Heartbeat check
   -  NOW_EPOCH=$(date +%s)
   -  if [ $((NOW_EPOCH - LAST_HEARTBEAT)) -ge $HEARTBEAT_INTERVAL ]; then
   -    update_heartbeat
   -    LAST_HEARTBEAT=$NOW_EPOCH
   -  fi
   ```
4. Update the header comment to remove "+ heartbeat":
   ```diff
   -# scripts/inbox-watcher.sh — Background inbox watcher + heartbeat.
   +# scripts/inbox-watcher.sh — Background inbox watcher for terminal notifications.
   ```
5. Remove the "Updates heartbeat every 60 seconds." sentence from the header.

- [ ] **Step 3: Run tests**

```bash
cd plugins/session-bridge && bash tests/test-inbox-watcher.sh
```

Expected: PASS.

- [ ] **Step 4: Run full test suite**

```bash
cd plugins/session-bridge && bash test.sh
```

Expected: still green.

- [ ] **Step 5: Commit**

```bash
git add plugins/session-bridge/scripts/inbox-watcher.sh plugins/session-bridge/tests/test-inbox-watcher.sh
git commit -m "$(cat <<'EOF'
refactor: inbox-watcher.sh stops updating heartbeat

heartbeat-daemon.sh owns the heartbeat file now (since Task 2).
inbox-watcher.sh's role is reduced to its name: watching the inbox
and printing terminal notifications when messages arrive.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Create remove-session.sh + session-removed message handling

**Files:**
- Create: `plugins/session-bridge/scripts/remove-session.sh`
- Create: `plugins/session-bridge/tests/test-remove-session.sh`

Explicit destructive removal. Notifies peers with a new `session-removed` message type, resolves open conversations, then `rm -rf`s the session dir.

- [ ] **Step 1: Write the failing test**

Create `plugins/session-bridge/tests/test-remove-session.sh`:

```bash
#!/usr/bin/env bash
# tests/test-remove-session.sh — Tests for scripts/remove-session.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREATE_PROJECT="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"
REMOVE="$PLUGIN_DIR/scripts/remove-session.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_NAME="remove-test"
PROJECT_A="$TEST_TMPDIR/proj-a"
PROJECT_B="$TEST_TMPDIR/proj-b"
mkdir -p "$PROJECT_A/.claude" "$PROJECT_B/.claude"

BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$CREATE_PROJECT" "$PROJECT_NAME" >/dev/null
SID_A=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$JOIN" "$PROJECT_NAME" --role orchestrator --name "orch")
SID_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$JOIN" "$PROJECT_NAME" --role specialist --name "spec")

echo "=== test-remove-session.sh ==="
echo "  orch=$SID_A  spec=$SID_B"
sleep 1

SESSION_B_DIR="$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$SID_B"

# --- Test 1: remove destroys session dir ---
echo ""
echo "Test 1: remove-session.sh destroys session directory"
BRIDGE_DIR="$BRIDGE_DIR" bash "$REMOVE" "$SID_B"
if [ -d "$SESSION_B_DIR" ]; then
  echo "  FAIL: session dir still exists"; FAIL=$((FAIL + 1))
else
  echo "  PASS: session dir destroyed"; PASS=$((PASS + 1))
fi

# --- Test 2: orchestrator receives session-removed notification ---
echo ""
echo "Test 2: orchestrator receives session-removed notification"
ORCH_INBOX="$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$SID_A/inbox"
NOTIF=$(find "$ORCH_INBOX" -maxdepth 1 -name "*.json" -exec grep -l '"type":"session-removed"' {} \; 2>/dev/null | head -1)
if [ -n "$NOTIF" ]; then
  echo "  PASS: orchestrator inbox has session-removed"; PASS=$((PASS + 1))
  assert_contains "notification names removed session" "$SID_B" "$(cat "$NOTIF")"
else
  echo "  FAIL: no session-removed notification in orchestrator inbox"; FAIL=$((FAIL + 1))
fi

# --- Test 3: remove on non-existent session is idempotent ---
echo ""
echo "Test 3: remove on non-existent session does not error"
if BRIDGE_DIR="$BRIDGE_DIR" bash "$REMOVE" "zzzzzz" 2>&1; then
  echo "  PASS: idempotent remove"; PASS=$((PASS + 1))
else
  echo "  FAIL: errored on non-existent session"; FAIL=$((FAIL + 1))
fi

# Kill remaining daemons
for PID_FILE in "$BRIDGE_DIR/projects/$PROJECT_NAME/sessions"/*/heartbeat-daemon.pid; do
  [ -f "$PID_FILE" ] || continue
  P=$(cat "$PID_FILE" 2>/dev/null || echo "")
  [ -n "$P" ] && kill "$P" 2>/dev/null || true
done

print_results
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd plugins/session-bridge && bash tests/test-remove-session.sh
```

Expected: FAIL — script doesn't exist.

- [ ] **Step 3: Create remove-session.sh**

Create `plugins/session-bridge/scripts/remove-session.sh`:

```bash
#!/usr/bin/env bash
# scripts/remove-session.sh — Destructive removal of a session from a project.
# Usage: remove-session.sh <session-id>
# Notifies peers via session-removed, resolves open conversations,
# kills daemons, removes session dir + bridge-session pointer.
# Idempotent: no-op if session doesn't exist.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }

SESSION_ID="${1:?Usage: remove-session.sh <session-id>}"
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve session dir + project
SESSION_DIR=""
PROJECT_ID=""
for PM in "$BRIDGE_DIR"/projects/*/sessions/"$SESSION_ID"/manifest.json; do
  [ -f "$PM" ] || continue
  PROJECT_ID=$(jq -r '.projectId' "$PM")
  SESSION_DIR=$(dirname "$PM")
  break
done

# Legacy fallback
if [ -z "$SESSION_DIR" ] && [ -d "$BRIDGE_DIR/sessions/$SESSION_ID" ]; then
  SESSION_DIR="$BRIDGE_DIR/sessions/$SESSION_ID"
fi

if [ -z "$SESSION_DIR" ] || [ ! -d "$SESSION_DIR" ]; then
  # Idempotent: silently succeed
  exit 0
fi

MANIFEST="$SESSION_DIR/manifest.json"

# Flip status=removed (signals daemon's EXIT trap to no-op)
if [ -f "$MANIFEST" ]; then
  # shellcheck source=lib/stale-check.sh
  source "$SCRIPT_DIR/lib/stale-check.sh"
  set_status "$MANIFEST" "removed"
  # Read manifest fields for the notification
  REMOVED_NAME=$(jq -r '.projectName // "unknown"' "$MANIFEST")
  REMOVED_PROJECT="$PROJECT_ID"
else
  REMOVED_NAME="unknown"
  REMOVED_PROJECT="${PROJECT_ID:-unknown}"
fi

# Kill daemons (give them a chance to log their exit)
for PID_FILE in "$SESSION_DIR/heartbeat-daemon.pid" "$SESSION_DIR/watcher.pid" "$SESSION_DIR/bridge-listen-child.pid"; do
  [ -f "$PID_FILE" ] || continue
  P=$(cat "$PID_FILE" 2>/dev/null || echo "")
  [ -n "$P" ] && kill "$P" 2>/dev/null || true
done

# Notify peers in the same project (project-scoped only)
if [ -n "$PROJECT_ID" ]; then
  for PEER_MANIFEST in "$BRIDGE_DIR/projects/$PROJECT_ID/sessions"/*/manifest.json; do
    [ -f "$PEER_MANIFEST" ] || continue
    PEER_ID=$(jq -r '.sessionId' "$PEER_MANIFEST")
    [ "$PEER_ID" = "$SESSION_ID" ] && continue
    BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_ID" \
      bash "$SCRIPT_DIR/send-message.sh" "$PEER_ID" session-removed \
      "Session $SESSION_ID ($REMOVED_NAME) has been removed from project $REMOVED_PROJECT." \
      2>/dev/null || true
  done

  # Resolve open conversations initiated by this session
  for CONV_FILE in "$BRIDGE_DIR/projects/$PROJECT_ID/conversations"/*.json; do
    [ -f "$CONV_FILE" ] || continue
    CONV_STATUS=$(jq -r '.status' "$CONV_FILE" 2>/dev/null)
    CONV_INIT=$(jq -r '.initiator' "$CONV_FILE" 2>/dev/null)
    if [ "$CONV_STATUS" != "resolved" ] && [ "$CONV_INIT" = "$SESSION_ID" ]; then
      BRIDGE_DIR="$BRIDGE_DIR" bash "$SCRIPT_DIR/conversation-update.sh" \
        "$PROJECT_ID" "$(jq -r '.conversationId' "$CONV_FILE")" "resolved" \
        --resolution "Session removed" 2>/dev/null || true
    fi
  done
fi

# Destroy the session directory
rm -rf "$SESSION_DIR"

# Remove .claude/bridge-session pointer if present (from any project dir we can locate)
for PD in "$BRIDGE_DIR"/projects/*/sessions/"$SESSION_ID"/manifest.json; do
  # Already removed
  break
done

# Check legacy pointer cleanup
# (the project dir's .claude/bridge-session belongs to PROJECT_DIR, which we
# don't strictly know here — leave it for resume-session.sh to error on)

# Per-session dotfiles
rm -f "$BRIDGE_DIR/.stop_counter_${SESSION_ID}" "$BRIDGE_DIR/.last_inbox_check_${SESSION_ID}" 2>/dev/null || true

exit 0
```

- [ ] **Step 4: Run tests**

```bash
cd plugins/session-bridge && bash tests/test-remove-session.sh
```

Expected: PASS.

- [ ] **Step 5: Run full test suite**

```bash
cd plugins/session-bridge && bash test.sh
```

Expected: still green.

- [ ] **Step 6: Commit**

```bash
git add plugins/session-bridge/scripts/remove-session.sh plugins/session-bridge/tests/test-remove-session.sh
git commit -m "$(cat <<'EOF'
feat: remove-session.sh for explicit destructive removal

Replaces cleanup.sh's BRIDGE_CLEANUP_CONFIRMED branch. Called by
the future /bridge remove command. Sets status=removed (silences
daemon EXIT trap), kills daemons, notifies peers via
session-removed, resolves open conversations initiated by this
session, then destroys the session directory.

Idempotent: removing a non-existent session is a no-op.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Create prune.sh and /bridge prune command

**Files:**
- Create: `plugins/session-bridge/scripts/prune.sh`
- Create: `plugins/session-bridge/tests/test-prune.sh`

Operator-controlled disk maintenance. Default thresholds are generous. Replaces the auto-prune behavior that lived in cleanup.sh.

- [ ] **Step 1: Write the failing test**

Create `plugins/session-bridge/tests/test-prune.sh`:

```bash
#!/usr/bin/env bash
# tests/test-prune.sh — Tests for scripts/prune.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PRUNE="$PLUGIN_DIR/scripts/prune.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
mkdir -p "$BRIDGE_DIR/projects/p1/sessions/s1/inbox/.delivered"
mkdir -p "$BRIDGE_DIR/projects/p1/sessions/s1/outbox"

echo "=== test-prune.sh ==="

# --- Test 1: --delivered N prunes files older than N days ---
echo ""
echo "Test 1: --delivered 7 prunes archive files older than 7 days"
OLD_FILE="$BRIDGE_DIR/projects/p1/sessions/s1/inbox/.delivered/msg-old.json"
echo '{}' > "$OLD_FILE"
touch -d "10 days ago" "$OLD_FILE" 2>/dev/null || touch -A -8640000 "$OLD_FILE" 2>/dev/null || true
FRESH_FILE="$BRIDGE_DIR/projects/p1/sessions/s1/inbox/.delivered/msg-fresh.json"
echo '{}' > "$FRESH_FILE"

BRIDGE_DIR="$BRIDGE_DIR" bash "$PRUNE" --delivered 7

if [ -f "$OLD_FILE" ]; then
  echo "  FAIL: old archive file not pruned"; FAIL=$((FAIL + 1))
else
  echo "  PASS: old archive pruned"; PASS=$((PASS + 1))
fi
assert_file_exists "fresh archive retained" "$FRESH_FILE"

# --- Test 2: --outbox N prunes outbox files older than N days ---
echo ""
echo "Test 2: --outbox 7 prunes outbox files older than 7 days"
OLD_OUT="$BRIDGE_DIR/projects/p1/sessions/s1/outbox/msg-old.json"
echo '{"timestamp":"2025-01-01T00:00:00Z"}' > "$OLD_OUT"
FRESH_OUT="$BRIDGE_DIR/projects/p1/sessions/s1/outbox/msg-fresh.json"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "{\"timestamp\":\"$NOW\"}" > "$FRESH_OUT"

BRIDGE_DIR="$BRIDGE_DIR" bash "$PRUNE" --outbox 7

if [ -f "$OLD_OUT" ]; then
  echo "  FAIL: old outbox file not pruned"; FAIL=$((FAIL + 1))
else
  echo "  PASS: old outbox pruned"; PASS=$((PASS + 1))
fi
assert_file_exists "fresh outbox retained" "$FRESH_OUT"

# --- Test 3: --dry-run prints what would be pruned, doesn't delete ---
echo ""
echo "Test 3: dry-run mode lists targets without deleting"
mkdir -p "$BRIDGE_DIR/projects/p1/sessions/s1/inbox/.delivered"
DRY_FILE="$BRIDGE_DIR/projects/p1/sessions/s1/inbox/.delivered/msg-dry.json"
echo '{}' > "$DRY_FILE"
touch -d "30 days ago" "$DRY_FILE" 2>/dev/null || touch -A -25920000 "$DRY_FILE" 2>/dev/null || true

OUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$PRUNE" --delivered 7 --dry-run 2>&1)
assert_file_exists "dry-run did not delete" "$DRY_FILE"
assert_contains "dry-run output mentions msg-dry" "msg-dry" "$OUT"

print_results
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd plugins/session-bridge && bash tests/test-prune.sh
```

Expected: FAIL.

- [ ] **Step 3: Create prune.sh**

Create `plugins/session-bridge/scripts/prune.sh`:

```bash
#!/usr/bin/env bash
# scripts/prune.sh — Operator-controlled disk maintenance.
# Usage: prune.sh [--delivered N] [--outbox N] [--conversations N] [--logs N] [--dry-run]
# N is days. Defaults are generous (7+) to favor persistence. Without flags, prints help.
set -euo pipefail

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"

DELIVERED_DAYS=""
OUTBOX_DAYS=""
CONVERSATIONS_DAYS=""
LOGS_DAYS=""
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --delivered) DELIVERED_DAYS="$2"; shift 2 ;;
    --outbox) OUTBOX_DAYS="$2"; shift 2 ;;
    --conversations) CONVERSATIONS_DAYS="$2"; shift 2 ;;
    --logs) LOGS_DAYS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --all)
      DELIVERED_DAYS="${2:-7}"
      OUTBOX_DAYS="${2:-7}"
      CONVERSATIONS_DAYS="${2:-30}"
      LOGS_DAYS="${2:-30}"
      shift 2
      ;;
    -h|--help|"")
      cat <<EOF
Usage: prune.sh [OPTIONS]

  --delivered N      Prune <inbox>/.delivered/*.json older than N days
  --outbox N         Prune outbox messages older than N days
  --conversations N  Prune resolved conversations older than N days
  --logs N           Prune bridge-listen.log lines older than N days (truncate)
  --all N            All four with N as the threshold (logs/convs use 30 if N omitted)
  --dry-run          List what would be deleted without deleting

Without flags, prints this help.

Defaults are generous (no auto-prune; ever). Operator must invoke
with explicit thresholds. Logs older than N use file mtime, since
log lines don't have parseable timestamps in the existing format.
EOF
      exit 0
      ;;
    *) echo "Warning: unknown flag '$1' ignored" >&2; shift ;;
  esac
done

_now_epoch=$(date -u +%s)
_secs_per_day=86400

_prune_files() {
  # $1: human label, $2: days threshold, $3+: glob patterns
  local LABEL="$1" DAYS="$2"
  shift 2
  local cutoff_epoch=$((_now_epoch - DAYS * _secs_per_day))
  local action="DELETE"
  $DRY_RUN && action="DRY-RUN"
  for PATTERN in "$@"; do
    for F in $PATTERN; do
      [ -f "$F" ] || continue
      local F_MTIME
      F_MTIME=$(stat -c %Y "$F" 2>/dev/null || stat -f %m "$F" 2>/dev/null || echo "$_now_epoch")
      if [ "$F_MTIME" -lt "$cutoff_epoch" ]; then
        echo "$action [$LABEL] $F"
        $DRY_RUN || rm -f "$F"
      fi
    done
  done
}

if [ -n "$DELIVERED_DAYS" ]; then
  _prune_files "delivered" "$DELIVERED_DAYS" \
    "$BRIDGE_DIR"/projects/*/sessions/*/inbox/.delivered/*.json \
    "$BRIDGE_DIR"/sessions/*/inbox/.delivered/*.json
fi

if [ -n "$OUTBOX_DAYS" ]; then
  _prune_files "outbox" "$OUTBOX_DAYS" \
    "$BRIDGE_DIR"/projects/*/sessions/*/outbox/msg-*.json \
    "$BRIDGE_DIR"/sessions/*/outbox/msg-*.json
fi

if [ -n "$CONVERSATIONS_DAYS" ]; then
  # Only resolved conversations are candidates for pruning
  cutoff_epoch=$((_now_epoch - CONVERSATIONS_DAYS * _secs_per_day))
  action="DELETE"
  $DRY_RUN && action="DRY-RUN"
  for CONV_FILE in "$BRIDGE_DIR"/projects/*/conversations/conv-*.json; do
    [ -f "$CONV_FILE" ] || continue
    CONV_STATUS=$(jq -r '.status // ""' "$CONV_FILE" 2>/dev/null || echo "")
    [ "$CONV_STATUS" = "resolved" ] || continue
    F_MTIME=$(stat -c %Y "$CONV_FILE" 2>/dev/null || stat -f %m "$CONV_FILE" 2>/dev/null || echo "$_now_epoch")
    if [ "$F_MTIME" -lt "$cutoff_epoch" ]; then
      echo "$action [conversation] $CONV_FILE"
      $DRY_RUN || rm -f "$CONV_FILE"
    fi
  done
fi

if [ -n "$LOGS_DAYS" ]; then
  cutoff_epoch=$((_now_epoch - LOGS_DAYS * _secs_per_day))
  action="TRUNCATE"
  $DRY_RUN && action="DRY-RUN-TRUNCATE"
  for LOG in "$BRIDGE_DIR"/projects/*/sessions/*/bridge-listen.log "$BRIDGE_DIR"/sessions/*/bridge-listen.log; do
    [ -f "$LOG" ] || continue
    F_MTIME=$(stat -c %Y "$LOG" 2>/dev/null || stat -f %m "$LOG" 2>/dev/null || echo "$_now_epoch")
    if [ "$F_MTIME" -lt "$cutoff_epoch" ]; then
      echo "$action [log] $LOG"
      $DRY_RUN || : > "$LOG"
    fi
  done
fi
```

- [ ] **Step 4: Run tests**

```bash
cd plugins/session-bridge && bash tests/test-prune.sh
```

Expected: PASS.

- [ ] **Step 5: Run full test suite**

```bash
cd plugins/session-bridge && bash test.sh
```

Expected: still green.

- [ ] **Step 6: Commit**

```bash
git add plugins/session-bridge/scripts/prune.sh plugins/session-bridge/tests/test-prune.sh
git commit -m "$(cat <<'EOF'
feat: prune.sh operator-controlled disk maintenance

Replaces the auto-prune behavior from cleanup.sh. Now must be
invoked explicitly with thresholds: --delivered N, --outbox N,
--conversations N, --logs N (all in days). --dry-run lists
without deleting.

Persistence-first: there is no default auto-pruning. The operator
explicitly chooses what to prune and how aggressive to be.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Delete cleanup.sh and test-cleanup.sh

**Files:**
- Delete: `plugins/session-bridge/scripts/cleanup.sh`
- Delete: `plugins/session-bridge/tests/test-cleanup.sh`

All responsibilities of cleanup.sh are now split across `close-session.sh`, `remove-session.sh`, and `prune.sh`. Nothing should reference it anymore (the hook was repointed in Task 7).

- [ ] **Step 1: Verify nothing references cleanup.sh**

```bash
grep -rn "cleanup\.sh" plugins/session-bridge/
```

Expected: no matches (or only matches in the deletion target and historical commit messages). If any test or script still references it, fix that reference first (likely a stale test).

- [ ] **Step 2: Delete the files**

```bash
git rm plugins/session-bridge/scripts/cleanup.sh plugins/session-bridge/tests/test-cleanup.sh
```

- [ ] **Step 3: Run full test suite**

```bash
cd plugins/session-bridge && bash test.sh
```

Expected: still green. The test count drops by however many tests were in test-cleanup.sh.

- [ ] **Step 4: Commit**

```bash
git commit -m "$(cat <<'EOF'
refactor: delete cleanup.sh — responsibilities split across new scripts

cleanup.sh used to do three jobs (lifecycle transitions, explicit
removal, auto-prune). Each is now owned by a focused script:
- close-session.sh: graceful offline (SessionEnd hook)
- remove-session.sh: destructive removal (/bridge remove)
- prune.sh: operator-controlled disk maintenance (/bridge prune)

The SessionEnd hook was repointed to close-session.sh in Task 7;
no remaining references to cleanup.sh.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Update bridge.md commands (remove /bridge stop, add /bridge close/remove/prune)

**Files:**
- Modify: `plugins/session-bridge/commands/bridge.md`

The `/bridge` slash command is documented in this markdown file. Add the three new sub-commands and remove the old `/bridge stop`. The actual command behavior is implemented in the script files we've already created.

- [ ] **Step 1: Read the current bridge.md to find /bridge stop**

```bash
grep -n "stop\|close\|remove\|prune" plugins/session-bridge/commands/bridge.md
```

Locate the section that documents `/bridge stop`. This is what the orchestrator reads to know what subcommands exist.

- [ ] **Step 2: Replace the /bridge stop section**

Edit `plugins/session-bridge/commands/bridge.md`. Wherever `/bridge stop` is documented (likely a heading or list item), replace with:

````markdown
### `/bridge close`

Gracefully close this session — transitions status to `offline`, kills the heartbeat daemon and inbox-watcher, preserves the session directory and all state (inbox, outbox, logs, conversations) for later resumption. Used when you're done for the day but expect to come back to the same specialist later.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/close-session.sh"
```

### `/bridge remove <session-id>`

**Destructive.** Removes a session from a project permanently. Notifies peers via `session-removed`, resolves open conversations, deletes the session directory. Use this only when you genuinely want to dismiss a specialist from the project roster — they will need to `/bridge project join` again to come back, getting a new session ID.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/remove-session.sh" "$SESSION_ID"
```

### `/bridge prune [options]`

Operator-controlled disk maintenance. There is no automatic pruning — call this when you actually want to reclaim disk.

Options:
- `--delivered N` — prune `<inbox>/.delivered/*.json` older than N days
- `--outbox N` — prune outbox messages older than N days
- `--conversations N` — prune resolved conversations older than N days
- `--logs N` — truncate bridge-listen.log files older than N days (by mtime)
- `--all N` — all four with N as threshold
- `--dry-run` — list what would be pruned without deleting

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/prune.sh" --delivered 7
```
````

Also update any earlier summary list of subcommands (typically at the top of the file) to replace `stop` with `close`/`remove`/`prune`.

- [ ] **Step 3: Verify no orphaned references**

```bash
grep -n "bridge stop\|/bridge stop" plugins/session-bridge/
```

Expected: zero remaining references.

- [ ] **Step 4: Run full test suite**

```bash
cd plugins/session-bridge && bash test.sh
```

Expected: still green (command doc changes don't affect tests).

- [ ] **Step 5: Commit**

```bash
git add plugins/session-bridge/commands/bridge.md
git commit -m "$(cat <<'EOF'
docs: replace /bridge stop with /bridge close, /bridge remove, /bridge prune

The lifecycle redesign splits the old destructive /bridge stop
into three intent-named commands:
- /bridge close: graceful offline (preserves everything)
- /bridge remove <id>: destructive removal (rare)
- /bridge prune [--flags]: operator-controlled disk maintenance

The orchestrator skill (next task) is updated to know which to
use in which scenario.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: Update bridge-awareness SKILL.md for recipient-stale + session-removed

**Files:**
- Modify: `plugins/session-bridge/skills/bridge-awareness/SKILL.md`

Add handling for the two new message types and update the lifecycle vocabulary the orchestrator uses.

- [ ] **Step 1: Locate the message-type handling section in SKILL.md**

```bash
grep -n "session-ended\|task-complete\|human-input-needed\|visibility lines" plugins/session-bridge/skills/bridge-awareness/SKILL.md
```

The skill has a section explaining how to handle each message type, and the visibility-lines format (`← <type> from <project>: <summary>` + `→ standby`).

- [ ] **Step 2: Add recipient-stale handling**

In the visibility-lines or message-type section, after the entry for `session-ended` (or in a similar location depending on the doc structure), add:

```markdown
- **`recipient-stale`**: a peer you sent a message to is unresponsive. The message DID land in their inbox; they'll see it when they revive. Surface this with a warning visibility line:
  ```
  ⚠ recipient-stale: <name> (<session-id>) unresponsive since <last-heartbeat> — <original-message-id> queued, may need user nudge
  ```
  Do NOT auto-retry, auto-reroute, or auto-escalate. Just surface the state. The user may decide to nudge the specialist (reopen the session) or wait.

- **`session-removed`**: a peer has been removed from the project. Surface with:
  ```
  ← session-removed from <name> (<session-id>): <reason>
  ```
  Update your internal roster — that session ID is gone for good. Any conversations addressed to it should be considered abandoned.
```

- [ ] **Step 3: Update the lifecycle vocabulary**

Find any reference to session status in the skill (typically explaining what `active`/`stale` means) and update to the new four-state model:
- `active` — runtime live, heartbeat fresh
- `offline` — clean voluntary exit, heartbeat absence expected
- `stale` — was supposed to be active but heartbeat producer died unexpectedly
- `removed` — explicitly removed from project (terminal)

- [ ] **Step 4: Update any /bridge stop references**

Find `/bridge stop` and replace with `/bridge close` where the user-facing recommendation is "close for the day," or `/bridge remove <id>` for genuine removal.

- [ ] **Step 5: Run full test suite**

```bash
cd plugins/session-bridge && bash test.sh
```

Expected: still green.

- [ ] **Step 6: Commit**

```bash
git add plugins/session-bridge/skills/bridge-awareness/SKILL.md
git commit -m "$(cat <<'EOF'
docs(skill): add recipient-stale + session-removed handling

Orchestrator now knows:
- Surface recipient-stale with ⚠ warning visibility line, do not
  auto-retry/reroute — wait for user decision
- Surface session-removed and update internal roster
- New four-state lifecycle vocabulary: active / offline / stale / removed
- /bridge stop is replaced by /bridge close (preserve) or /bridge
  remove (destructive)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 16: Version bump, CLAUDE.md update, full-suite verification

**Files:**
- Modify: `plugins/session-bridge/.claude-plugin/plugin.json`
- Modify: `CLAUDE.md`

Final administrative pass. Bump to 0.3.0 (minor — new message types, removed command, lifecycle protocol changes).

- [ ] **Step 1: Run full suite as baseline**

```bash
cd plugins/session-bridge && bash test.sh
```

Expected: all tests green. Record the count. If anything fails, stop and fix BEFORE this task.

- [ ] **Step 2: Bump plugin.json**

Edit `plugins/session-bridge/.claude-plugin/plugin.json`. Change `"version": "0.2.22"` to `"version": "0.3.0"`. No other fields.

- [ ] **Step 3: Update CLAUDE.md**

Update `CLAUDE.md`:

1. In Project Structure section, change `currently v0.2.22` to `currently v0.3.0`.
2. In "Bidirectional Bridge v2 (shipped)" section heading, change `stable as of v0.2.22` to `stable as of v0.3.0`.
3. In v2 Key Concepts list, REPLACE the `Delivery audit` bullet (which mentioned 24h auto-prune of `.delivered/`) with a new lifecycle bullet:

```markdown
- **Session lifecycle**: each session has a four-state machine — `active` (heartbeat producer alive), `offline` (cleanly `/bridge close`-ed or `/exit`-ed), `stale` (was supposed to be active but heartbeat went silent), `removed` (explicit `/bridge remove`, destructive). Recovery on resume is automatic: SessionStart hook → `resume-session.sh` adopts the existing ID, restarts the heartbeat-daemon, flips status back to `active`. No more silent ID changes on restart.
- **Persistence-first cleanup**: nothing is auto-deleted — `bridge-listen.log`, `<inbox>/.delivered/`, conversations, manifests, inboxes, outboxes all survive indefinitely. Disk maintenance is operator-controlled via `/bridge prune --delivered N --outbox N --conversations N --logs N`.
- **Stale detection**: on-demand only (during `send-message.sh` delivery and `/bridge peers` listing). Uses `<session-dir>/heartbeat` file content + PID-liveness check on `heartbeat-daemon.pid`. PID-liveness backstop prevents false positives across laptop sleep/wake.
- **`recipient-stale` notification**: sending to a stale recipient still delivers the message (it queues in the inbox) AND emits a `recipient-stale` notification back to the sender so the orchestrator surfaces the unresponsive state to the user.
```

4. If there's a "Local Plugin Cache Quirk" section, leave it. If there's a Prerequisites section, leave it.

- [ ] **Step 4: Run full suite again**

```bash
cd plugins/session-bridge && bash test.sh
```

Expected: still green.

- [ ] **Step 5: Final commit**

```bash
git add plugins/session-bridge/.claude-plugin/plugin.json CLAUDE.md
git commit -m "$(cat <<'EOF'
chore: bump to v0.3.0 with session lifecycle redesign

Minor bump (breaking changes):
- /bridge stop removed; use /bridge close (graceful, preserve) or
  /bridge remove <id> (destructive)
- New message types: recipient-stale, session-removed
- Four-state lifecycle: active / offline / stale / removed
- Heartbeat owned by dedicated heartbeat-daemon.sh writing
  <session-dir>/heartbeat
- cleanup.sh split into close-session.sh / remove-session.sh / prune.sh
- Persistence-first: no auto-pruning of logs, archives,
  conversations, or sessions

Closes the persistent-session-ID issue: sessions retain their
original ID across /exit + resume cycles. inbox queues survive
session offline → online transitions. The orchestrator's
conversation threading no longer orphans on specialist restart.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**1. Spec coverage:**

| Spec section | Implementing task |
|---|---|
| Lifecycle state machine (active/offline/stale/removed) | Tasks 1 (lib), 2 (daemon EXIT trap), 6 (close), 8 (resume), 11 (remove) |
| Heartbeat file (content not mtime) | Task 2 |
| EXIT trap defensive layer | Task 2 |
| Stale detection on-demand (send/list-peers) | Tasks 4, 5 |
| PID-liveness backstop | Task 1 |
| `recipient-stale` message type | Task 5 |
| `session-removed` message type | Tasks 5 (type validation), 11 (emission) |
| Script split (project-join / resume / close / remove / prune) | Tasks 6, 8, 9, 11, 12 |
| Hook config swap (SessionEnd → close-session.sh) | Task 7 |
| `cleanup.sh` deleted | Task 13 |
| `/bridge close`, `/bridge remove`, `/bridge prune` commands | Task 14 |
| `/bridge stop` removed (no alias) | Task 14 |
| Orchestrator skill updated for new message types | Task 15 |
| Version bump + CLAUDE.md | Task 16 |

All spec sections covered.

**2. Placeholder scan:**

No `TODO`, `TBD`, `implement later`, `similar to Task N`, or `add appropriate error handling` instances. Every code step shows the exact code. Tests show exact assertions and expected pass/fail.

**3. Type / name consistency:**

- `is_stale`, `is_producer_alive`, `get_heartbeat_age`, `set_status` are consistently named in lib (Task 1) and consumers (Tasks 4, 5, 6, 8, 11).
- `<session-dir>/heartbeat`, `<session-dir>/heartbeat-daemon.pid`, `<session-dir>/watcher.pid`, `<session-dir>/bridge-listen-child.pid` paths are consistent across all tasks.
- Status field values `active`, `offline`, `stale`, `removed` are spelled consistently in all assertions and writes.
- Message type strings `recipient-stale`, `session-removed` are consistent between VALID_TYPES (Task 5), emission (Tasks 5, 11), and skill doc (Task 15).
- Function `set_status` takes `manifest-file` then `new-status` — consistent between lib definition (Task 1) and all callers.
- `HEARTBEAT_INTERVAL` env var name consistent in Task 2 (daemon) and Task 2 tests.
- `BRIDGE_STALE_THRESHOLD` env var introduced in Task 5; used in send-message.sh, no other caller relies on it.

No inconsistencies found.

**4. Critical constraint check:**

The user's plextura-suite runs against a symlinked live copy. Each task's commit must leave the test suite green AND the runtime functional. Reviewing:

- Tasks 1-2: pure additions, no behavior change.
- Task 3: project-join.sh starts the new daemon alongside existing watcher heartbeat. Both writers; no consumer breakage yet.
- Tasks 4-5: list-peers and send-message use the lib. Tests confirm behavior. Live sessions don't break because the lib gracefully handles missing heartbeat files.
- Task 6: close-session.sh exists but isn't wired to hook yet.
- Task 7: hook repointed. The new close-session.sh is non-destructive — even if it misbehaves, no data is lost.
- Task 8: resume-session.sh exists; auto-join uses it. If it errors, error message tells user how to recover.
- Task 9: project-join.sh strict — would only error if someone double-joins, which isn't a normal flow.
- Task 10: inbox-watcher no longer writes heartbeat. Daemon already does, so no consumer sees a difference.
- Task 11-12: new scripts, not yet exposed via commands. Safe.
- Task 13: cleanup.sh deletion happens AFTER all consumers migrated. Hook is on close-session.sh from Task 7.
- Tasks 14-16: doc + version. No behavior change.

Each commit leaves the system runnable. Order is safe for the symlinked production deploy.

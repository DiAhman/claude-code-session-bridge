#!/usr/bin/env bash
# scripts/bridge-listen.sh — Block until a pending message arrives in THIS session's inbox.
# Usage: bridge-listen.sh <session-id> [timeout-seconds]
# If no session-id given, uses get-session-id.sh to find it.
# Uses inotifywait (Linux) or fswatch (macOS) for efficient waiting, falls back to polling.
# Outputs the message details when found.
# Exits 0 with message content on success, exits 1 on timeout.
set -euo pipefail

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Logging ---
_log() {
  local LOG_FILE="${SESSION_DIR:-/tmp}/bridge-listen.log"
  local TS
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$TS] ($$) $*" >> "$LOG_FILE" 2>/dev/null || true
}
# Truncate log if over 200 lines (keep tail) — called once at startup after SESSION_DIR is set
_log_rotate() {
  local LOG_FILE="$SESSION_DIR/bridge-listen.log"
  if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt 200 ]; then
    tail -100 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || true
  fi
}

# Get session ID: from argument, or from get-session-id.sh
if [ -n "${1:-}" ] && [ "${1:-}" != "0" ] && [ ${#1} -eq 6 ]; then
  # First arg is 6 chars — treat as session ID (session IDs are always 6 chars)
  SESSION_ID="$1"
  TIMEOUT="${2:-0}"
else
  # No session ID given, try to find it
  SESSION_ID=$(bash "$SCRIPT_DIR/get-session-id.sh" 2>/dev/null) || {
    echo "Error: No bridge session found. Run /bridge start first." >&2
    exit 1
  }
  TIMEOUT="${1:-0}"
fi

# Resolve inbox and session dir: project-scoped first, legacy fallback
INBOX=""
SESSION_DIR=""
for PROJ_MANIFEST in "$BRIDGE_DIR"/projects/*/sessions/"$SESSION_ID"/manifest.json; do
  [ -f "$PROJ_MANIFEST" ] || continue
  PROJ_ID=$(jq -r '.projectId' "$PROJ_MANIFEST")
  INBOX="$BRIDGE_DIR/projects/$PROJ_ID/sessions/$SESSION_ID/inbox"
  SESSION_DIR="$BRIDGE_DIR/projects/$PROJ_ID/sessions/$SESSION_ID"
  break
done
if [ -z "$INBOX" ]; then
  INBOX="$BRIDGE_DIR/sessions/$SESSION_ID/inbox"
  SESSION_DIR="$BRIDGE_DIR/sessions/$SESSION_ID"
fi

if [ ! -d "$INBOX" ]; then
  echo "Error: Session $SESSION_ID inbox not found." >&2
  exit 1
fi

# --- Exclusive lock: only one bridge-listen.sh per session ---
# Uses flock to prevent race conditions where multiple listeners spawn
# before the PID file cleanup can catch them. This is the definitive fix
# for the process leak that affected sessions with high message volume.
LOCK_FILE="$SESSION_DIR/bridge-listen.lock"
WATCHER_CHILD_FILE="$SESSION_DIR/bridge-listen-child.pid"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  _log "BLOCKED — another listener holds lock, exiting"
  exit 0
fi
# Lock acquired — we are the only listener for this session
_log_rotate
_log "START session=$SESSION_ID timeout=$TIMEOUT watcher=$( command -v inotifywait >/dev/null 2>&1 && echo inotifywait || (command -v fswatch >/dev/null 2>&1 && echo fswatch || echo poll) )"

# Kill any orphaned inotifywait/fswatch watching THIS inbox
# (catches reparented-to-init orphans from previous sessions)
for ORPHAN_PID in $(pgrep -f "inotifywait.*$INBOX" 2>/dev/null || true); do
  [ "$ORPHAN_PID" = "$$" ] && continue
  kill "$ORPHAN_PID" 2>/dev/null || true
done
for ORPHAN_PID in $(pgrep -f "fswatch.*$INBOX" 2>/dev/null || true); do
  [ "$ORPHAN_PID" = "$$" ] && continue
  kill "$ORPHAN_PID" 2>/dev/null || true
done

# Clean up on exit.
# IMPORTANT: Do NOT delete the lock file. flock releases the advisory lock
# automatically when the file descriptor closes (process exit). The lock file
# must persist on disk so the NEXT listener flocks the SAME inode. Deleting it
# causes the next listener to create a new file (new inode), bypassing the lock.
# Kill inotifywait/fswatch child on exit to prevent orphans
_cleanup_child() {
  if [ -n "${INOTIFY_PID:-}" ] && kill -0 "$INOTIFY_PID" 2>/dev/null; then
    kill "$INOTIFY_PID" 2>/dev/null || true
  fi
  if [ -n "${FSWATCH_PID:-}" ] && kill -0 "$FSWATCH_PID" 2>/dev/null; then
    kill "$FSWATCH_PID" 2>/dev/null || true
  fi
  rm -f "$WATCHER_CHILD_FILE" 2>/dev/null
}
trap '_log "EXIT signal=$?"; _cleanup_child; exit' EXIT INT TERM

# Detect filesystem watcher
if command -v inotifywait >/dev/null 2>&1; then
  WATCHER="inotifywait"
elif command -v fswatch >/dev/null 2>&1; then
  WATCHER="fswatch"
else
  WATCHER="poll"
fi

INOTIFY_PID=""
FSWATCH_PID=""
ELAPSED=0
INTERVAL=3

while true; do
  # Timeout check (0 = infinite)
  if [ "$TIMEOUT" -gt 0 ] && [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    _log "TIMEOUT elapsed=${ELAPSED}s"
    exit 1
  fi

  # Recover orphaned .claimed_ files older than 30 seconds (from killed processes)
  CLAIM_NOW=$(date +%s)
  for CLAIMED in "$INBOX"/.claimed_*.json; do
    [ -f "$CLAIMED" ] || continue
    CLAIM_MTIME=$(stat -c %Y "$CLAIMED" 2>/dev/null || stat -f %m "$CLAIMED" 2>/dev/null || echo "$CLAIM_NOW")
    [ $((CLAIM_NOW - CLAIM_MTIME)) -lt 30 ] && continue  # Skip recent — probably still being processed
    ORIG_NAME=$(basename "$CLAIMED" | sed 's/^\.claimed_//')
    mv "$CLAIMED" "$INBOX/$ORIG_NAME" 2>/dev/null || true
  done

  # Scan only THIS session's inbox
  for MSG_FILE in "$INBOX"/*.json; do
    [ -f "$MSG_FILE" ] || continue
    STATUS=$(jq -r '.status' "$MSG_FILE" 2>/dev/null) || continue
    [ "$STATUS" = "pending" ] || continue

    # Found a pending message — claim it atomically
    MSG_BASENAME=$(basename "$MSG_FILE")
    CLAIMED_FILE="$INBOX/.claimed_${MSG_BASENAME}"
    mv "$MSG_FILE" "$CLAIMED_FILE" 2>/dev/null || continue  # Another process got it

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

    # Output message details for the agent FIRST, then delete
    echo "MESSAGE_ID=$MSG_ID"
    echo "FROM_ID=$FROM_ID"
    echo "TO_ID=$TO_ID"
    echo "FROM_PROJECT=$FROM_PROJECT"
    echo "TYPE=$MSG_TYPE"
    echo "IN_REPLY_TO=$IN_REPLY_TO"
    echo "CONV_ID=$CONV_ID"
    echo "---"
    echo "$CONTENT"
    # Delete AFTER output to prevent message loss on process death
    rm -f "$CLAIMED_FILE" 2>/dev/null || true
    exit 0
  done

  # Wait for new files using the best available method
  case "$WATCHER" in
    inotifywait)
      if [ "$TIMEOUT" -gt 0 ]; then
        REMAINING=$((TIMEOUT - ELAPSED))
      else
        REMAINING=300  # 5-min blocks; loop re-checks inbox + directory existence between cycles
      fi
      # Run inotifywait in background so we can track its PID for cleanup.
      # Close fd 9 (flock) so the child doesn't inherit the lock.
      _log "WAIT inotifywait -t $REMAINING pid=$$"
      inotifywait -t "$REMAINING" -e create "$INBOX" >/dev/null 2>&1 9>&- &
      INOTIFY_PID=$!
      echo "$INOTIFY_PID" > "$WATCHER_CHILD_FILE"
      WATCH_RC=0
      wait "$INOTIFY_PID" 2>/dev/null || WATCH_RC=$?
      rm -f "$WATCHER_CHILD_FILE" 2>/dev/null
      case "$WATCH_RC" in
        0)
          _log "EVENT file created in inbox"
          ELAPSED=$((ELAPSED + 1))
          ;;
        2)
          _log "POLL timeout after ${REMAINING}s, re-checking"
          ELAPSED=$((ELAPSED + REMAINING))
          continue
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
      if [ "$TIMEOUT" -gt 0 ]; then
        REMAINING=$((TIMEOUT - ELAPSED))
      else
        REMAINING=300  # 5-min blocks; loop re-checks between cycles
      fi
      START_WAIT=$(date +%s)
      timeout "$REMAINING" fswatch --one-event "$INBOX" >/dev/null 2>&1 9>&- &
      FSWATCH_PID=$!
      echo "$FSWATCH_PID" > "$WATCHER_CHILD_FILE"
      WATCH_RC=0
      wait "$FSWATCH_PID" 2>/dev/null || WATCH_RC=$?
      rm -f "$WATCHER_CHILD_FILE" 2>/dev/null
      END_WAIT=$(date +%s)
      WAIT_DURATION=$((END_WAIT - START_WAIT))
      if [ "$WATCH_RC" -ne 0 ] && [ "$WAIT_DURATION" -lt 2 ]; then
        # fswatch crashed immediately — back off to prevent CPU spin
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

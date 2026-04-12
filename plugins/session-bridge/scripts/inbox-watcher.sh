#!/usr/bin/env bash
# scripts/inbox-watcher.sh — Background inbox watcher + heartbeat.
# Usage: inbox-watcher.sh <session-id> <project-id>
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge)
# Runs until killed. Watches inbox for new files, prints terminal notifications.
# Updates heartbeat every 60 seconds.
set -euo pipefail

SESSION_ID="${1:?Usage: inbox-watcher.sh <session-id> <project-id>}"
PROJECT_ID="${2:?Usage: inbox-watcher.sh <session-id> <project-id>}"

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
INBOX="$BRIDGE_DIR/projects/$PROJECT_ID/sessions/$SESSION_ID/inbox"
MANIFEST="$BRIDGE_DIR/projects/$PROJECT_ID/sessions/$SESSION_ID/manifest.json"

if [ ! -d "$INBOX" ]; then
  echo "Error: Inbox not found for session $SESSION_ID" >&2
  exit 1
fi

# Heartbeat update function
update_heartbeat() {
  [ -f "$MANIFEST" ] || return
  local NOW TMP
  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  TMP=$(mktemp "$(dirname "$MANIFEST")/manifest.XXXXXX")
  jq --arg hb "$NOW" '.lastHeartbeat = $hb' "$MANIFEST" > "$TMP" 2>/dev/null && mv "$TMP" "$MANIFEST" || rm -f "$TMP"
}

LAST_HEARTBEAT=$(date +%s)
HEARTBEAT_INTERVAL=60
WATCHER_FAIL_COUNT=0
MAX_WATCHER_FAILURES=5

# Detect watcher tool
if command -v inotifywait >/dev/null 2>&1; then
  WATCHER="inotifywait"
elif command -v fswatch >/dev/null 2>&1; then
  WATCHER="fswatch"
else
  WATCHER="poll"
fi

# Graceful shutdown — use background inotifywait + wait so SIGTERM can interrupt
RUNNING=true
CHILD_PID=""
trap 'RUNNING=false; [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null || true' TERM INT

while $RUNNING; do
  # Check inbox still exists (prevents hot spin if directory deleted)
  if [ ! -d "$INBOX" ]; then
    echo "Error: Inbox directory $INBOX no longer exists. Stopping watcher." >&2
    exit 1
  fi

  # Heartbeat check
  NOW_EPOCH=$(date +%s)
  if [ $((NOW_EPOCH - LAST_HEARTBEAT)) -ge $HEARTBEAT_INTERVAL ]; then
    update_heartbeat
    LAST_HEARTBEAT=$NOW_EPOCH
  fi

  case "$WATCHER" in
    inotifywait)
      # Run in background so SIGTERM trap can kill it
      inotifywait -t 30 -e create "$INBOX" >/dev/null 2>&1 &
      CHILD_PID=$!
      WATCH_RC=0
      wait "$CHILD_PID" 2>/dev/null || WATCH_RC=$?
      CHILD_PID=""
      case "$WATCH_RC" in
        0) WATCHER_FAIL_COUNT=0 ;;  # Event detected
        2) ;;  # Timeout — normal
        *)
          # Error — back off to prevent hot spin
          WATCHER_FAIL_COUNT=$((WATCHER_FAIL_COUNT + 1))
          if [ "$WATCHER_FAIL_COUNT" -ge "$MAX_WATCHER_FAILURES" ]; then
            echo "Error: inotifywait failed $WATCHER_FAIL_COUNT consecutive times. Stopping watcher." >&2
            exit 1
          fi
          sleep 2
          ;;
      esac
      ;;
    fswatch)
      timeout 30 fswatch --one-event "$INBOX" >/dev/null 2>&1 &
      CHILD_PID=$!
      wait "$CHILD_PID" 2>/dev/null || true
      CHILD_PID=""
      ;;
    poll)
      sleep 10 &
      CHILD_PID=$!
      wait "$CHILD_PID" 2>/dev/null || true
      CHILD_PID=""
      ;;
  esac

  $RUNNING || break

  # Check for new pending messages and notify
  for MSG_FILE in "$INBOX"/*.json; do
    [ -f "$MSG_FILE" ] || continue
    STATUS=$(jq -r '.status' "$MSG_FILE" 2>/dev/null) || continue
    [ "$STATUS" = "pending" ] || continue

    FROM=$(jq -r '.metadata.fromProject // "unknown"' "$MSG_FILE" 2>/dev/null)
    TYPE=$(jq -r '.type' "$MSG_FILE" 2>/dev/null)

    if [ "$TYPE" = "human-input-needed" ]; then
      printf '\n>> DECISION NEEDED from "%s" — run /bridge decisions or press Enter.\a\n' "$FROM" >&2
    else
      printf '\n>> Bridge: %s from "%s" — press Enter to process.\a\n' "$TYPE" "$FROM" >&2
    fi
    break  # Notify once per cycle
  done
done

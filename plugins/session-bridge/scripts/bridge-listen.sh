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

# Get session ID: from argument, or from get-session-id.sh
if [ -n "${1:-}" ] && [ "${1:-}" != "0" ] && ! echo "$1" | grep -qE '^[0-9]+$'; then
  # First arg looks like a session ID (not a number/timeout)
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

# --- Kill previous bridge-listen.sh instance (prevents process leak) ---
PID_FILE="$SESSION_DIR/bridge-listen.pid"
if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [ -n "$OLD_PID" ] && [ "$OLD_PID" != "$$" ]; then
    # Kill the old listener and its child processes (inotifywait/fswatch)
    pkill -P "$OLD_PID" 2>/dev/null || true
    kill "$OLD_PID" 2>/dev/null || true
  fi
fi
PID_TMP=$(mktemp "$SESSION_DIR/bridge-listen.pid.XXXXXX")
echo $$ > "$PID_TMP"
mv "$PID_TMP" "$PID_FILE"

# Clean up PID file on exit
trap 'rm -f "$PID_FILE" 2>/dev/null; exit' EXIT INT TERM

# Detect filesystem watcher
if command -v inotifywait >/dev/null 2>&1; then
  WATCHER="inotifywait"
elif command -v fswatch >/dev/null 2>&1; then
  WATCHER="fswatch"
else
  WATCHER="poll"
fi

ELAPSED=0
INTERVAL=3

while true; do
  # Timeout check (0 = infinite)
  if [ "$TIMEOUT" -gt 0 ] && [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    exit 1
  fi

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

    # Skip messages FROM ourselves (echo prevention) — restore file if skipping
    if [ "$FROM_ID" = "$SESSION_ID" ]; then
      mv "$CLAIMED_FILE" "$MSG_FILE" 2>/dev/null || true
      continue
    fi

    # Mark as read and restore to original filename
    TMP=$(mktemp "$INBOX/${MSG_ID}.XXXXXX")
    jq '.status = "read"' "$CLAIMED_FILE" > "$TMP" && mv "$TMP" "$MSG_FILE" && rm -f "$CLAIMED_FILE" || {
      mv "$CLAIMED_FILE" "$MSG_FILE" 2>/dev/null || true
      rm -f "$TMP" 2>/dev/null || true
    }

    # Output message details for the agent
    echo "MESSAGE_ID=$MSG_ID"
    echo "FROM_ID=$FROM_ID"
    echo "TO_ID=$TO_ID"
    echo "FROM_PROJECT=$FROM_PROJECT"
    echo "TYPE=$MSG_TYPE"
    echo "IN_REPLY_TO=$IN_REPLY_TO"
    echo "---"
    echo "$CONTENT"
    exit 0
  done

  # Wait for new files using the best available method
  case "$WATCHER" in
    inotifywait)
      if [ "$TIMEOUT" -gt 0 ]; then
        REMAINING=$((TIMEOUT - ELAPSED))
      else
        REMAINING="$INTERVAL"
      fi
      # Capture exit code — disable set -e for this command since
      # inotifywait returns 2 on timeout which would kill the script
      WATCH_RC=0
      inotifywait -t "$REMAINING" -e create "$INBOX" >/dev/null 2>&1 || WATCH_RC=$?
      case "$WATCH_RC" in
        0)
          # File event detected — re-scan
          ELAPSED=$((ELAPSED + 1))
          ;;
        2)
          # Timeout — update elapsed and let the loop re-check
          ELAPSED=$((ELAPSED + REMAINING))
          continue
          ;;
        *)
          # Error (code 1 = directory deleted, inotify limit, etc.)
          if [ ! -d "$INBOX" ]; then
            echo "Error: Inbox directory $INBOX no longer exists." >&2
            exit 1
          fi
          # Fall back to polling for this cycle to avoid hot spin
          sleep "$INTERVAL"
          ELAPSED=$((ELAPSED + INTERVAL))
          ;;
      esac
      ;;
    fswatch)
      if [ "$TIMEOUT" -gt 0 ]; then
        REMAINING=$((TIMEOUT - ELAPSED))
      else
        REMAINING="$INTERVAL"
      fi
      START_WAIT=$(date +%s)
      timeout "$REMAINING" fswatch --one-event "$INBOX" >/dev/null 2>&1 || true
      END_WAIT=$(date +%s)
      ELAPSED=$((ELAPSED + END_WAIT - START_WAIT))
      ;;
    poll)
      sleep "$INTERVAL"
      ELAPSED=$((ELAPSED + INTERVAL))
      ;;
  esac
done

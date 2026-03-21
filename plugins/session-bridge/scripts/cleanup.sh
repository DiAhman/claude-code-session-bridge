#!/usr/bin/env bash
# scripts/cleanup.sh — Clean up session on exit. Notify connected peers.
# Supports both legacy (sessions/) and project-scoped (projects/<name>/sessions/) sessions.
#
# IMPORTANT: For project-scoped sessions, this script checks whether the session
# is truly ending by looking for a .bridge-cleanup-confirmed marker file. Without
# it, the script only kills the watcher (lightweight cleanup) but does NOT remove
# the session directory or notify peers. This prevents spurious session-ended
# notifications during context compaction and other non-terminal lifecycle events.
set -euo pipefail

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
BRIDGE_SESSION_FILE="$PROJECT_DIR/.claude/bridge-session"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Find session ID
SESSION_ID=""
if [ -f "$BRIDGE_SESSION_FILE" ]; then
  SESSION_ID=$(cat "$BRIDGE_SESSION_FILE")
else
  # Check legacy sessions
  for MANIFEST_FILE in "$BRIDGE_DIR"/sessions/*/manifest.json; do
    [ -f "$MANIFEST_FILE" ] || continue
    MANIFEST_PATH=$(jq -r '.projectPath // ""' "$MANIFEST_FILE" 2>/dev/null)
    if [ "$MANIFEST_PATH" = "$PROJECT_DIR" ]; then
      SESSION_ID=$(jq -r '.sessionId' "$MANIFEST_FILE")
      break
    fi
  done
  # Check project-scoped sessions
  if [ -z "$SESSION_ID" ]; then
    for MANIFEST_FILE in "$BRIDGE_DIR"/projects/*/sessions/*/manifest.json; do
      [ -f "$MANIFEST_FILE" ] || continue
      MANIFEST_PATH=$(jq -r '.projectPath // ""' "$MANIFEST_FILE" 2>/dev/null)
      if [ "$MANIFEST_PATH" = "$PROJECT_DIR" ]; then
        SESSION_ID=$(jq -r '.sessionId' "$MANIFEST_FILE")
        break
      fi
    done
  fi
fi

if [ -z "$SESSION_ID" ]; then
  exit 0
fi

# Check if this session is in a project
PROJECT_ID=""
SESSION_DIR=""
for PROJ_MANIFEST in "$BRIDGE_DIR"/projects/*/sessions/"$SESSION_ID"/manifest.json; do
  [ -f "$PROJ_MANIFEST" ] || continue
  PROJECT_ID=$(jq -r '.projectId' "$PROJ_MANIFEST")
  SESSION_DIR="$BRIDGE_DIR/projects/$PROJECT_ID/sessions/$SESSION_ID"
  break
done

# Fall back to legacy path
if [ -z "$SESSION_DIR" ]; then
  SESSION_DIR="$BRIDGE_DIR/sessions/$SESSION_ID"
fi

WATCHER_PID_FILE="$SESSION_DIR/watcher.pid"

if [ -n "$PROJECT_ID" ]; then
  # --- Project-scoped cleanup ---
  # Only do full cleanup (notify peers, resolve conversations, remove session dir)
  # if this is a confirmed cleanup via /bridge stop or truly terminal event.
  # The SessionEnd hook fires during compaction and other non-terminal events —
  # doing full cleanup there causes spurious session-ended notifications.
  #
  # Confirmed cleanup: BRIDGE_CLEANUP_CONFIRMED=1 env var (set by /bridge stop)
  # or the session dir no longer has a running watcher (session truly dead).
  CONFIRMED="${BRIDGE_CLEANUP_CONFIRMED:-0}"

  # Heuristic: if the watcher is still running, this is likely a non-terminal event
  # IMPORTANT: check BEFORE killing the watcher
  if [ "$CONFIRMED" != "1" ] && [ -f "$WATCHER_PID_FILE" ]; then
    WATCHER_PID=$(cat "$WATCHER_PID_FILE" 2>/dev/null || echo "")
    if [ -n "$WATCHER_PID" ] && kill -0 "$WATCHER_PID" 2>/dev/null; then
      # Watcher still alive — this is NOT a real session end (likely compaction).
      # Do nothing — session is still active.
      exit 0
    fi
  fi

  # Past this point, we're doing full cleanup — kill the watcher first
  if [ -f "$WATCHER_PID_FILE" ]; then
    kill "$(cat "$WATCHER_PID_FILE")" 2>/dev/null || true
    rm -f "$WATCHER_PID_FILE"
  fi

  # Full cleanup — session is truly ending
  # Notify peers in the same project
  for PEER_MANIFEST in "$BRIDGE_DIR/projects/$PROJECT_ID/sessions"/*/manifest.json; do
    [ -f "$PEER_MANIFEST" ] || continue
    PEER_ID=$(jq -r '.sessionId' "$PEER_MANIFEST")
    [ "$PEER_ID" = "$SESSION_ID" ] && continue
    BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_ID" \
      bash "$SCRIPT_DIR/send-message.sh" "$PEER_ID" session-ended "Session ended" 2>/dev/null || true
  done

  # Resolve open conversations initiated by this session
  for CONV_FILE in "$BRIDGE_DIR/projects/$PROJECT_ID/conversations"/*.json; do
    [ -f "$CONV_FILE" ] || continue
    CONV_STATUS=$(jq -r '.status' "$CONV_FILE" 2>/dev/null)
    CONV_INIT=$(jq -r '.initiator' "$CONV_FILE" 2>/dev/null)
    if [ "$CONV_STATUS" != "resolved" ] && [ "$CONV_INIT" = "$SESSION_ID" ]; then
      BRIDGE_DIR="$BRIDGE_DIR" bash "$SCRIPT_DIR/conversation-update.sh" \
        "$PROJECT_ID" "$(jq -r '.conversationId' "$CONV_FILE")" "resolved" \
        --resolution "Session ended" 2>/dev/null || true
    fi
  done

  # Warn about unread messages before deletion
  if [ -d "$SESSION_DIR/inbox" ]; then
    PENDING_COUNT=$(grep -rl '"status":[[:space:]]*"pending"' "$SESSION_DIR/inbox/"*.json 2>/dev/null | wc -l | tr -d '[:space:]') || true
    PENDING_COUNT="${PENDING_COUNT:-0}"
    if [ "$PENDING_COUNT" -gt 0 ]; then
      echo "Warning: Destroying session $SESSION_ID with $PENDING_COUNT unread message(s)" >&2
    fi
  fi

  # Remove session directory (do NOT delete conversation files — shared project state)
  rm -rf "$SESSION_DIR"
else
  # --- Legacy cleanup ---

  # Kill inbox watcher if running (legacy sessions may also have one)
  if [ -f "$WATCHER_PID_FILE" ]; then
    kill "$(cat "$WATCHER_PID_FILE")" 2>/dev/null || true
    rm -f "$WATCHER_PID_FILE"
  fi

  # Find connected peers from inbox (senders) and outbox (recipients)
  PEER_IDS=""
  if [ -d "$SESSION_DIR/inbox" ]; then
    INBOX_PEERS=$(find "$SESSION_DIR/inbox" -name "*.json" \
      -exec jq -r '.from // empty' {} \; 2>/dev/null || true)
    PEER_IDS="${PEER_IDS} ${INBOX_PEERS}"
  fi
  if [ -d "$SESSION_DIR/outbox" ]; then
    OUTBOX_PEERS=$(find "$SESSION_DIR/outbox" -name "*.json" \
      -exec jq -r '.to // empty' {} \; 2>/dev/null || true)
    PEER_IDS="${PEER_IDS} ${OUTBOX_PEERS}"
  fi
  PEER_IDS=$(echo "$PEER_IDS" | tr ' ' '\n' | sort -u | grep -v '^$' || true)

  # Notify each peer
  for PEER_ID in $PEER_IDS; do
    if [ -d "$BRIDGE_DIR/sessions/$PEER_ID/inbox" ]; then
      BRIDGE_DIR="$BRIDGE_DIR" BRIDGE_SESSION_ID="$SESSION_ID" \
        bash "$SCRIPT_DIR/send-message.sh" "$PEER_ID" session-ended "Session ended" 2>/dev/null || true
    fi
  done

  # Remove session directory
  rm -rf "$SESSION_DIR"
fi

# Remove bridge-session pointer
rm -f "$BRIDGE_SESSION_FILE"

# Helper: validate ISO 8601 timestamp format (YYYY-MM-DDTHH:MM:SSZ)
is_valid_timestamp() {
  echo "$1" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
}

# Clean up stale sessions (heartbeat older than 30 minutes)
STALE_CUTOFF=$(date -u -v-30M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "30 minutes ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
if [ -n "$STALE_CUTOFF" ] && is_valid_timestamp "$STALE_CUTOFF"; then
  # Legacy sessions
  for STALE_MANIFEST in "$BRIDGE_DIR"/sessions/*/manifest.json; do
    [ -f "$STALE_MANIFEST" ] || continue
    STALE_DIR=$(dirname "$STALE_MANIFEST")
    STALE_HB=$(jq -r '.lastHeartbeat // ""' "$STALE_MANIFEST" 2>/dev/null || echo "")
    # Only compare if heartbeat is a valid timestamp (prevents "null" < "2026-..." deletion)
    if is_valid_timestamp "$STALE_HB" && [[ "$STALE_HB" < "$STALE_CUTOFF" ]]; then
      rm -rf "$STALE_DIR"
    fi
  done

  # Project-scoped sessions
  for STALE_MANIFEST in "$BRIDGE_DIR"/projects/*/sessions/*/manifest.json; do
    [ -f "$STALE_MANIFEST" ] || continue
    STALE_DIR=$(dirname "$STALE_MANIFEST")
    STALE_HB=$(jq -r '.lastHeartbeat // ""' "$STALE_MANIFEST" 2>/dev/null || echo "")
    if is_valid_timestamp "$STALE_HB" && [[ "$STALE_HB" < "$STALE_CUTOFF" ]]; then
      rm -rf "$STALE_DIR"
    fi
  done
fi

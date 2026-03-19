#!/usr/bin/env bash
# scripts/cleanup.sh — Clean up session on exit. Notify connected peers.
# Supports both legacy (sessions/) and project-scoped (projects/<name>/sessions/) sessions.
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

# Kill inbox watcher if running
WATCHER_PID_FILE="$SESSION_DIR/watcher.pid"
if [ -f "$WATCHER_PID_FILE" ]; then
  kill "$(cat "$WATCHER_PID_FILE")" 2>/dev/null || true
  rm -f "$WATCHER_PID_FILE"
fi

if [ -n "$PROJECT_ID" ]; then
  # --- Project-scoped cleanup ---

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

  # Remove session directory (do NOT delete conversation files — shared project state)
  rm -rf "$SESSION_DIR"
else
  # --- Legacy cleanup ---

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

# Clean up stale sessions (heartbeat older than 30 minutes) — legacy only
STALE_CUTOFF=$(date -u -v-30M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "30 minutes ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
if [ -n "$STALE_CUTOFF" ]; then
  for STALE_MANIFEST in "$BRIDGE_DIR"/sessions/*/manifest.json; do
    [ -f "$STALE_MANIFEST" ] || continue
    STALE_DIR=$(dirname "$STALE_MANIFEST")
    STALE_HB=$(jq -r '.lastHeartbeat // ""' "$STALE_MANIFEST" 2>/dev/null || echo "")
    if [ -n "$STALE_HB" ] && [[ "$STALE_HB" < "$STALE_CUTOFF" ]]; then
      rm -rf "$STALE_DIR"
    fi
  done
fi

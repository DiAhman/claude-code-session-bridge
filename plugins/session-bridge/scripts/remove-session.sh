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
else
  REMOVED_NAME="unknown"
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
      "Session $SESSION_ID ($REMOVED_NAME) has been removed from project $PROJECT_ID." \
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

# Per-session dotfiles
rm -f "$BRIDGE_DIR/.stop_counter_${SESSION_ID}" "$BRIDGE_DIR/.last_inbox_check_${SESSION_ID}" 2>/dev/null || true

exit 0

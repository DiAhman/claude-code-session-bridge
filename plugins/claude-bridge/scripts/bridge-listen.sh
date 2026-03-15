#!/usr/bin/env bash
# scripts/bridge-listen.sh — Block until a pending message arrives in any session's inbox.
# Usage: bridge-listen.sh [timeout-seconds]
# Polls every 3 seconds. Outputs the message details when found.
# Exits 0 with message content on success, exits 1 on timeout.
set -euo pipefail

TIMEOUT="${1:-0}"  # 0 = no timeout (wait forever)
BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/bridge}"
SESSIONS_DIR="$BRIDGE_DIR/sessions"

ELAPSED=0
INTERVAL=3

while true; do
  # Timeout check (0 = infinite)
  if [ "$TIMEOUT" -gt 0 ] && [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    exit 1
  fi

  # Scan all sessions for pending messages
  for SESSION_DIR in "$SESSIONS_DIR"/*/; do
    [ -d "$SESSION_DIR" ] || continue
    INBOX="$SESSION_DIR/inbox"
    [ -d "$INBOX" ] || continue

    for MSG_FILE in "$INBOX"/*.json; do
      [ -f "$MSG_FILE" ] || continue
      STATUS=$(jq -r '.status' "$MSG_FILE" 2>/dev/null) || continue
      [ "$STATUS" = "pending" ] || continue

      # Found a pending message!
      MSG_ID=$(jq -r '.id' "$MSG_FILE")
      FROM_ID=$(jq -r '.from' "$MSG_FILE")
      TO_ID=$(jq -r '.to' "$MSG_FILE")
      MSG_TYPE=$(jq -r '.type' "$MSG_FILE")
      CONTENT=$(jq -r '.content' "$MSG_FILE")
      FROM_PROJECT=$(jq -r '.metadata.fromProject // "unknown"' "$MSG_FILE")
      IN_REPLY_TO=$(jq -r '.inReplyTo // ""' "$MSG_FILE")

      # Mark as read
      TMP=$(mktemp "$INBOX/${MSG_ID}.XXXXXX")
      jq '.status = "read"' "$MSG_FILE" > "$TMP"
      mv "$TMP" "$MSG_FILE"

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
  done

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

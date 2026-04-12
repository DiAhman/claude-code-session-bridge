#!/usr/bin/env bash
# scripts/send-message.sh — Send a message to a peer's inbox (v2 protocol).
# Usage: send-message.sh <target-id> <type> <content> [in-reply-to] [--conversation <id>] [--urgency <level>] [--reply-to <id>]
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge), BRIDGE_SESSION_ID (required)
# Outputs: message ID to stdout
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }

TARGET_ID="$1"
MSG_TYPE="$2"
CONTENT="$3"
shift 3

# Validate message type
VALID_TYPES=" ping query response task-assign task-update task-complete task-cancel escalate task-redirect human-input-needed human-response routing-query session-ended "
if [[ "$VALID_TYPES" != *" $MSG_TYPE "* ]]; then
  echo "Error: Unknown message type '$MSG_TYPE'." >&2
  echo "Valid types: ping query response task-assign task-update task-complete task-cancel escalate task-redirect human-input-needed human-response routing-query session-ended" >&2
  exit 1
fi

# Parse remaining args: legacy positional in-reply-to + named flags
IN_REPLY_TO="null"
CONVERSATION_ID=""
URGENCY="normal"

# Legacy compat: if $1 exists and doesn't start with --, treat as in-reply-to
if [ $# -gt 0 ] && [ "${1:0:2}" != "--" ]; then
  IN_REPLY_TO="$1"
  shift
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --conversation) CONVERSATION_ID="$2"; shift 2 ;;
    --urgency) URGENCY="$2"; shift 2 ;;
    --reply-to) IN_REPLY_TO="$2"; shift 2 ;;
    *) echo "Warning: unknown flag '$1' ignored" >&2; shift ;;
  esac
done

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
SENDER_ID="${BRIDGE_SESSION_ID:?BRIDGE_SESSION_ID must be set}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Path resolution: find sender's project (if any) ---
SENDER_PROJECT_ID=""
for PROJ_MANIFEST in "$BRIDGE_DIR"/projects/*/sessions/"$SENDER_ID"/manifest.json; do
  [ -f "$PROJ_MANIFEST" ] || continue
  SENDER_PROJECT_ID=$(jq -r '.projectId' "$PROJ_MANIFEST")
  break
done

# --- Resolve target inbox + sender outbox ---
TARGET_INBOX=""
SENDER_OUTBOX=""

if [ -n "$SENDER_PROJECT_ID" ]; then
  PROJ_TARGET="$BRIDGE_DIR/projects/$SENDER_PROJECT_ID/sessions/$TARGET_ID/inbox"
  if [ -d "$PROJ_TARGET" ]; then
    TARGET_INBOX="$PROJ_TARGET"
    SENDER_OUTBOX="$BRIDGE_DIR/projects/$SENDER_PROJECT_ID/sessions/$SENDER_ID/outbox"
  fi
fi

# Legacy fallback
if [ -z "$TARGET_INBOX" ]; then
  TARGET_INBOX="$BRIDGE_DIR/sessions/$TARGET_ID/inbox"
  SENDER_OUTBOX="$BRIDGE_DIR/sessions/$SENDER_ID/outbox"
fi

if [ ! -d "$TARGET_INBOX" ]; then
  echo "Error: Target session $TARGET_ID not found" >&2
  exit 1
fi

# --- Conversation management (project-scoped sessions only) ---
CONV_FREE_TYPES=" ping session-ended routing-query "
CONV_CREATE_TYPES=" task-assign escalate "

if [[ "$CONV_FREE_TYPES" == *" $MSG_TYPE "* ]]; then
  CONVERSATION_ID="null"
elif [ -n "$SENDER_PROJECT_ID" ]; then
  # Project-scoped: enforce conversation protocol
  if [ -z "$CONVERSATION_ID" ]; then
    if [ "$MSG_TYPE" = "query" ] || [[ "$CONV_CREATE_TYPES" == *" $MSG_TYPE "* ]]; then
      # Auto-create conversation
      TOPIC="$CONTENT"
      [ ${#TOPIC} -gt 80 ] && TOPIC="${TOPIC:0:80}..."
      CONVERSATION_ID=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$SCRIPT_DIR/conversation-create.sh" \
        "$SENDER_PROJECT_ID" "$SENDER_ID" "$TARGET_ID" "$TOPIC") || {
        echo "Error: Failed to create conversation for $MSG_TYPE message to $TARGET_ID" >&2
        exit 1
      }
      BRIDGE_DIR="$BRIDGE_DIR" bash "$SCRIPT_DIR/conversation-update.sh" \
        "$SENDER_PROJECT_ID" "$CONVERSATION_ID" "waiting" || {
        echo "Warning: Conversation $CONVERSATION_ID created but could not set status to waiting" >&2
      }
    else
      echo "Error: Message type '$MSG_TYPE' requires --conversation for project-scoped sessions" >&2
      exit 1
    fi
  fi
  # Auto-resolve on task-complete/task-cancel
  if [ "$MSG_TYPE" = "task-complete" ] || [ "$MSG_TYPE" = "task-cancel" ]; then
    if [ "$CONVERSATION_ID" != "null" ]; then
      if ! BRIDGE_DIR="$BRIDGE_DIR" bash "$SCRIPT_DIR/conversation-update.sh" \
        "$SENDER_PROJECT_ID" "$CONVERSATION_ID" "resolved" \
        --resolution "$(echo "$CONTENT" | head -c 200)" 2>&1; then
        echo "Warning: Message sent but conversation $CONVERSATION_ID could not be resolved" >&2
      fi
    fi
  fi
else
  # Legacy session: no conversation enforcement, default to null
  [ -z "$CONVERSATION_ID" ] && CONVERSATION_ID="null"
fi

# --- Build and send message ---
MSG_ID="msg-$(set +o pipefail; LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 12)"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Read sender project name and role from manifest
SENDER_PROJECT="unknown"
SENDER_ROLE=""
for MANIFEST_PATH in \
  "$BRIDGE_DIR/projects/$SENDER_PROJECT_ID/sessions/$SENDER_ID/manifest.json" \
  "$BRIDGE_DIR/sessions/$SENDER_ID/manifest.json"; do
  if [ -f "$MANIFEST_PATH" ]; then
    SENDER_PROJECT=$(jq -r '.projectName // "unknown"' "$MANIFEST_PATH")
    SENDER_ROLE=$(jq -r '.role // ""' "$MANIFEST_PATH")
    break
  fi
done

# Format inReplyTo and conversationId as JSON values
if [ "$IN_REPLY_TO" = "null" ]; then
  IN_REPLY_TO_JSON="null"
else
  IN_REPLY_TO_JSON="\"$IN_REPLY_TO\""
fi

if [ "$CONVERSATION_ID" = "null" ]; then
  CONV_ID_JSON="null"
else
  CONV_ID_JSON="\"$CONVERSATION_ID\""
fi

MSG_JSON=$(jq -n \
  --arg pv "2.0" \
  --arg id "$MSG_ID" \
  --argjson conv "$CONV_ID_JSON" \
  --arg from "$SENDER_ID" \
  --arg to "$TARGET_ID" \
  --arg type "$MSG_TYPE" \
  --arg ts "$NOW" \
  --arg content "$CONTENT" \
  --argjson inReplyTo "$IN_REPLY_TO_JSON" \
  --arg urgency "$URGENCY" \
  --arg fromProject "$SENDER_PROJECT" \
  --arg fromRole "$SENDER_ROLE" \
  '{
    protocolVersion: $pv,
    id: $id,
    conversationId: $conv,
    from: $from,
    to: $to,
    type: $type,
    timestamp: $ts,
    status: "pending",
    content: $content,
    inReplyTo: $inReplyTo,
    metadata: {
      urgency: $urgency,
      fromProject: $fromProject,
      fromRole: $fromRole
    }
  }')

# Atomic write to target inbox
TMP_FILE=$(mktemp "$TARGET_INBOX/$MSG_ID.XXXXXX")
echo "$MSG_JSON" > "$TMP_FILE"
mv "$TMP_FILE" "$TARGET_INBOX/$MSG_ID.json" || { rm -f "$TMP_FILE"; exit 1; }

# Copy to sender outbox (audit log) with status=sent
if [ -d "$SENDER_OUTBOX" ]; then
  OUTBOX_JSON=$(echo "$MSG_JSON" | jq '.status = "sent"')
  TMP_FILE=$(mktemp "$SENDER_OUTBOX/$MSG_ID.XXXXXX")
  echo "$OUTBOX_JSON" > "$TMP_FILE"
  mv "$TMP_FILE" "$SENDER_OUTBOX/$MSG_ID.json" || { echo "Warning: outbox write failed for $MSG_ID" >&2; rm -f "$TMP_FILE"; }
fi

echo -n "$MSG_ID"

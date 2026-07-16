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
VALID_TYPES=" ping query response task-assign task-update task-complete task-cancel escalate task-redirect human-input-needed human-response routing-query session-ended session-removed recipient-stale "
if [[ "$VALID_TYPES" != *" $MSG_TYPE "* ]]; then
  echo "Error: Unknown message type '$MSG_TYPE'." >&2
  echo "Valid types: ping query response task-assign task-update task-complete task-cancel escalate task-redirect human-input-needed human-response routing-query session-ended session-removed recipient-stale" >&2
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
# shellcheck source=lib/stale-check.sh
source "$SCRIPT_DIR/lib/stale-check.sh"

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

# Sender session dir is the parent of the outbox in both project-scoped and legacy layouts.
SENDER_DIR="$(dirname "$SENDER_OUTBOX")"

# Self-heal: if our heartbeat-daemon has died (OOM, kill, crash) relaunch it
# before sending. Best-effort — never block message delivery. (#19)
if [ -d "$SENDER_DIR" ]; then
  ensure_producer_alive "$SENDER_DIR" || true
fi

if [ ! -d "$TARGET_INBOX" ]; then
  echo "Error: Target session $TARGET_ID not found" >&2
  exit 1
fi

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
# Also skip self-emitted recipient-stale messages to prevent feedback loops
if [ -n "$SENDER_PROJECT_ID" ] && [ "$MSG_TYPE" != "recipient-stale" ]; then
  TARGET_DIR="$BRIDGE_DIR/projects/$SENDER_PROJECT_ID/sessions/$TARGET_ID"
  if [ -d "$TARGET_DIR" ] && is_stale "$TARGET_DIR" "$STALE_THRESHOLD_SEC"; then
    RECIPIENT_STALE_DETECTED=true
    RECIPIENT_STALE_HEARTBEAT=$(head -1 "$TARGET_DIR/heartbeat" 2>/dev/null || true)
    [ -z "$RECIPIENT_STALE_HEARTBEAT" ] && RECIPIENT_STALE_HEARTBEAT="unknown"
    RECIPIENT_NAME=$(jq -r '.projectName // "unknown"' "$TARGET_DIR/manifest.json" 2>/dev/null)
    set_status "$TARGET_DIR/manifest.json" "stale"
  fi
fi

# --- Compacting-recipient warning (rate-limited 60s per (sender,recipient)) ---
# When the target session is mid-compaction we still deliver the message, but
# surface a one-line stderr warning so the calling agent knows a response may
# be delayed. Rate-limited via mtime of <sender-dir>/.compact-warned-<target>
# so a burst of sends doesn't spam the transcript.
if [ -n "$SENDER_PROJECT_ID" ] && [ "$MSG_TYPE" != "recipient-stale" ]; then
  TARGET_MANIFEST_FOR_LC="$BRIDGE_DIR/projects/$SENDER_PROJECT_ID/sessions/$TARGET_ID/manifest.json"
  if [ -f "$TARGET_MANIFEST_FOR_LC" ]; then
    TARGET_LC=$(jq -r '.lifecycle // "normal"' "$TARGET_MANIFEST_FOR_LC" 2>/dev/null)
    if [ "$TARGET_LC" = "compacting" ]; then
      SENDER_DIR_FOR_WARN="$BRIDGE_DIR/projects/$SENDER_PROJECT_ID/sessions/$SENDER_ID"
      WARN_FILE="$SENDER_DIR_FOR_WARN/.compact-warned-$TARGET_ID"
      EMIT_WARN=true
      if [ -f "$WARN_FILE" ]; then
        WARN_MTIME=$(stat -c %Y "$WARN_FILE" 2>/dev/null || stat -f %m "$WARN_FILE" 2>/dev/null || echo 0)
        NOW_EPOCH_W=$(date -u +%s)
        AGE_W=$((NOW_EPOCH_W - WARN_MTIME))
        [ "$AGE_W" -lt 60 ] && EMIT_WARN=false
      fi
      if [ "$EMIT_WARN" = true ]; then
        echo "Warning: recipient $TARGET_ID compacting — response may be delayed" >&2
        mkdir -p "$SENDER_DIR_FOR_WARN" 2>/dev/null || true
        : > "$WARN_FILE" 2>/dev/null || true
      fi
    fi
  fi
fi

# --- Conversation management (project-scoped sessions only) ---
CONV_FREE_TYPES=" ping session-ended routing-query recipient-stale session-removed "
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
      # Auto-resume: try to attach to the single open conversation between these
      # two participants. Default-on per v0.3.2 locked decision #4 — every
      # implicit attach emits a stderr marker so the agent and user can see it.
      # shellcheck source=lib/find-open-conversation.sh
      source "$SCRIPT_DIR/lib/find-open-conversation.sh"
      FOC_ERR=$(mktemp)
      set +e
      AUTO_CONV=$(find_open_conversation "$SENDER_ID" "$TARGET_ID" "$SENDER_PROJECT_ID" 2>"$FOC_ERR")
      FOC_RC=$?
      set -e
      if [ "$FOC_RC" -eq 2 ]; then
        echo "Error: Multiple open conversations between $SENDER_ID and $TARGET_ID — pass --conversation <id> to disambiguate." >&2
        cat "$FOC_ERR" >&2
        rm -f "$FOC_ERR"
        exit 1
      fi
      rm -f "$FOC_ERR"
      if [ -n "$AUTO_CONV" ]; then
        CONVERSATION_ID="$AUTO_CONV"
        echo "auto-attached to $CONVERSATION_ID" >&2
      else
        echo "Error: Message type '$MSG_TYPE' requires --conversation for project-scoped sessions." >&2
        echo "  No open conversation found between $SENDER_ID and $TARGET_ID." >&2
        echo "  Run '/bridge inbox' to find the conversation id, or pass --conversation <id> explicitly." >&2
        exit 1
      fi
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

# Bump sender heartbeat: outgoing traffic is unambiguous liveness proof. (#19)
# Best-effort — must NEVER fail message delivery.
if [ -d "$SENDER_DIR" ]; then
  write_heartbeat "$SENDER_DIR" || true
fi

# Copy to sender outbox (audit log) with status=sent
if [ -d "$SENDER_OUTBOX" ]; then
  OUTBOX_JSON=$(echo "$MSG_JSON" | jq '.status = "sent"')
  TMP_FILE=$(mktemp "$SENDER_OUTBOX/$MSG_ID.XXXXXX")
  echo "$OUTBOX_JSON" > "$TMP_FILE"
  mv "$TMP_FILE" "$SENDER_OUTBOX/$MSG_ID.json" || { echo "Warning: outbox write failed for $MSG_ID" >&2; rm -f "$TMP_FILE"; }
fi

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
      --arg fromProject "$RECIPIENT_NAME" \
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

echo -n "$MSG_ID"

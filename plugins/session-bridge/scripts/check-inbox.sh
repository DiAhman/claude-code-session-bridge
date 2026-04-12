#!/usr/bin/env bash
# scripts/check-inbox.sh — Check session inbox for pending messages.
# v3: rate limiting, early exit for non-bridge sessions, project-scoped scanning, Stop hook support.
# Usage: check-inbox.sh [--rate-limited] [--summary-only] [--stop-hook]
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge), BRIDGE_SESSION_ID, PROJECT_DIR
set -euo pipefail

# --- 1. Parse flags ---
RATE_LIMITED=false
SUMMARY_ONLY=false
STOP_HOOK=false
STOP_COUNTER=0
STOP_COUNTER_FILE=""
case "${1:-}" in
  --rate-limited) RATE_LIMITED=true ;;
  --summary-only) SUMMARY_ONLY=true ;;
  --stop-hook) STOP_HOOK=true ;;
esac

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"

# Restore claimed files on output failure — prevents message loss when jq crashes
_restore_claimed_files() {
  for F in $FILES_TO_DELETE; do
    [ -f "$F" ] || continue
    ORIG_NAME=$(basename "$F" | sed 's/^\.claimed_//')
    INBOX_DIR=$(dirname "$F")
    mv "$F" "$INBOX_DIR/$ORIG_NAME" 2>/dev/null || true
  done
}

# --- 2. Early exit for non-bridge sessions ---
# If neither BRIDGE_SESSION_ID env nor .claude/bridge-session file exists, this
# session has no bridge registration. Exit immediately with zero cost.
if [ -z "${BRIDGE_SESSION_ID:-}" ] && [ ! -f "${PROJECT_DIR:-.}/.claude/bridge-session" ]; then
  [ "$STOP_HOOK" = true ] && exit 0  # Stop hook: silent exit (no JSON)
  echo '{"continue": true}'
  exit 0
fi

# --- 3. Resolve this session's ID and inbox path ---
MY_SESSION_ID="${BRIDGE_SESSION_ID:-$(cat "${PROJECT_DIR:-.}/.claude/bridge-session" 2>/dev/null || echo "")}"
MY_INBOX=""
MY_PROJECT_ID=""
SESSIONS_DIR=""

# Check project-scoped sessions first
if [ -n "$MY_SESSION_ID" ]; then
  for PM in "$BRIDGE_DIR"/projects/*/sessions/"$MY_SESSION_ID"/manifest.json; do
    [ -f "$PM" ] || continue
    MY_PROJECT_ID=$(jq -r '.projectId' "$PM")
    MY_INBOX="$BRIDGE_DIR/projects/$MY_PROJECT_ID/sessions/$MY_SESSION_ID/inbox"
    SESSIONS_DIR="$BRIDGE_DIR/projects/$MY_PROJECT_ID/sessions"
    break
  done
fi

# Fall back to legacy flat sessions directory
if [ -z "$MY_INBOX" ] && [ -n "$MY_SESSION_ID" ]; then
  MY_INBOX="$BRIDGE_DIR/sessions/$MY_SESSION_ID/inbox"
  SESSIONS_DIR="$BRIDGE_DIR/sessions"
fi

# If we still can't resolve an inbox, exit cleanly
if [ -z "$MY_INBOX" ] || [ ! -d "$MY_INBOX" ]; then
  # For legacy mode without project: scan all sessions (backward compat)
  if [ -z "$MY_PROJECT_ID" ] && [ -d "$BRIDGE_DIR/sessions" ]; then
    SESSIONS_DIR="$BRIDGE_DIR/sessions"
  else
    [ "$STOP_HOOK" = true ] && exit 0  # Stop hook: silent exit
    echo '{"continue": true}'
    exit 0
  fi
fi

# --- Reset stop counter on UserPromptSubmit (default mode, no flags) ---
# When the user sends input, reset the safety counter. This signals the user
# is engaged, so any Stop hook loop is not runaway.
if [ "$RATE_LIMITED" = false ] && [ "$SUMMARY_ONLY" = false ] && [ "$STOP_HOOK" = false ] && [ -n "$MY_SESSION_ID" ]; then
  STOP_COUNTER_FILE="$BRIDGE_DIR/.stop_counter_${MY_SESSION_ID}"
  [ -f "$STOP_COUNTER_FILE" ] && echo "0" > "$STOP_COUNTER_FILE"
fi

# --- 4. Rate limiting (only with --rate-limited flag) ---
if [ "$RATE_LIMITED" = true ] && [ -n "$MY_SESSION_ID" ]; then
  # Per-session rate limit file (not global — prevents cross-session throttling)
  LAST_CHECK_FILE="$BRIDGE_DIR/.last_inbox_check_${MY_SESSION_ID}"
  NOW_EPOCH=$(date +%s)
  LAST=$(cat "$LAST_CHECK_FILE" 2>/dev/null || echo 0)
  if [ $((NOW_EPOCH - LAST)) -lt 5 ]; then
    # Check for critical urgency messages (fast grep, no jq)
    # Handle both compact ("urgency":"critical") and pretty-printed ("urgency": "critical") JSON
    if [ -d "$MY_INBOX" ]; then
      HAS_CRITICAL=$(find "$MY_INBOX" -name "*.json" -newer "$LAST_CHECK_FILE" \
        -exec grep -l '"urgency":[[:space:]]*"critical"' {} \; 2>/dev/null | head -1 || true)
    else
      HAS_CRITICAL=""
    fi
    if [ -z "$HAS_CRITICAL" ]; then
      echo '{"continue": true}'
      exit 0
    fi
  fi
  echo "$NOW_EPOCH" > "$LAST_CHECK_FILE"
fi

# --- 4b. Stop hook safety counter (prevents infinite block loops) ---
if [ "$STOP_HOOK" = true ] && [ -n "$MY_SESSION_ID" ]; then
  STOP_COUNTER_FILE="$BRIDGE_DIR/.stop_counter_${MY_SESSION_ID}"
  STOP_COUNTER=$(cat "$STOP_COUNTER_FILE" 2>/dev/null || echo 0)
  [[ "$STOP_COUNTER" =~ ^[0-9]+$ ]] || STOP_COUNTER=0  # Validate integer (empty/corrupt → 0)
  if [ "$STOP_COUNTER" -ge 10 ]; then
    # Safety cap reached — allow stop, reset counter. Messages stay pending
    # and will be picked up by PostToolUse or UserPromptSubmit hooks.
    echo "0" > "$STOP_COUNTER_FILE"
    exit 0
  fi
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- 5. Summary-only mode ---
if [ "$SUMMARY_ONLY" = true ]; then
  SESSION_INFO=""

  NOW_EPOCH=$(date +%s)
  STALE_THRESHOLD=3600  # 1 hour

  if [ -n "$MY_PROJECT_ID" ]; then
    # Project-scoped: include project context, conversations, peers
    for MANIFEST in "$SESSIONS_DIR"/*/manifest.json; do
      [ -f "$MANIFEST" ] || continue
      SID=$(jq -r '.sessionId' "$MANIFEST")
      SNAME=$(jq -r '.projectName' "$MANIFEST")
      SROLE=$(jq -r '.role // "unknown"' "$MANIFEST")
      # Check heartbeat freshness — skip sessions stale for over 1 hour
      LAST_HB=$(jq -r '.lastHeartbeat // ""' "$MANIFEST")
      if [ -n "$LAST_HB" ] && [ "$LAST_HB" != "null" ]; then
        HB_EPOCH=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$LAST_HB" +%s 2>/dev/null || date -u -d "$LAST_HB" +%s 2>/dev/null || echo 0)
        # Reject invalid epochs (before 2020-01-01) — prevents malformed timestamps from hiding sessions
        if [ "$HB_EPOCH" -lt 1577836800 ]; then
          continue  # Invalid epoch — skip session
        fi
        if [ $((NOW_EPOCH - HB_EPOCH)) -gt "$STALE_THRESHOLD" ]; then
          continue  # Skip stale session
        fi
      fi
      SSTATUS=$(jq -r '.status // "unknown"' "$MANIFEST")
      SESSION_INFO="${SESSION_INFO}\n- ${SNAME} (${SID}) [${SROLE}, ${SSTATUS}]"
    done

    # Active conversations
    CONV_INFO=""
    CONV_DIR="$BRIDGE_DIR/projects/$MY_PROJECT_ID/conversations"
    if [ -d "$CONV_DIR" ]; then
      for CONV_FILE in "$CONV_DIR"/conv-*.json; do
        [ -f "$CONV_FILE" ] || continue
        CSTATUS=$(jq -r '.status' "$CONV_FILE")
        [ "$CSTATUS" = "resolved" ] && continue
        CID=$(jq -r '.conversationId' "$CONV_FILE")
        CTOPIC=$(jq -r '.topic' "$CONV_FILE")
        CONV_INFO="${CONV_INFO}\n- ${CID}: ${CTOPIC} [${CSTATUS}]"
      done
    fi

    SUMMARY="=== CLAUDE BRIDGE STATE ===\nProject: ${MY_PROJECT_ID}\nSession: ${MY_SESSION_ID}\nActive sessions:${SESSION_INFO}"
    if [ -n "$CONV_INFO" ]; then
      SUMMARY="${SUMMARY}\n\nActive conversations:${CONV_INFO}"
    fi
    SUMMARY="${SUMMARY}\n\nTo send messages, use Bash: \${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh <peer-id> <type> \"<content>\" [in-reply-to]\n=== END BRIDGE ==="
  else
    # Legacy: scan all sessions
    for MANIFEST in "$SESSIONS_DIR"/*/manifest.json; do
      [ -f "$MANIFEST" ] || continue
      SID=$(jq -r '.sessionId' "$MANIFEST")
      SNAME=$(jq -r '.projectName' "$MANIFEST")
      SESSION_INFO="${SESSION_INFO}\n- ${SNAME} (${SID})"
    done

    if [ -z "$SESSION_INFO" ]; then
      echo '{"continue": true}'
      exit 0
    fi

    SUMMARY="=== CLAUDE BRIDGE STATE ===\nActive sessions:${SESSION_INFO}\n\nTo send messages, use Bash: \${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh <peer-id> <type> \"<content>\" [in-reply-to]\n=== END BRIDGE ==="
  fi

  jq -n --arg msg "$SUMMARY" '{continue: true, suppressOutput: false, systemMessage: $msg}'
  exit 0
fi

# --- 6. Normal mode: scan for pending inbox messages ---
ALL_MESSAGES=""
TOTAL_COUNT=0
FILES_TO_DELETE=""  # Deferred deletion — delete AFTER output to prevent message loss on process death

if [ -n "$MY_PROJECT_ID" ]; then
  # Project-scoped: only scan this session's own inbox
  INBOX="$MY_INBOX"
  if [ -d "$INBOX" ]; then
    SESSION_NAME="unknown"
    MANIFEST="$SESSIONS_DIR/$MY_SESSION_ID/manifest.json"
    if [ -f "$MANIFEST" ]; then
      SESSION_NAME=$(jq -r '.projectName // "unknown"' "$MANIFEST")
    fi

    # Recover orphaned .claimed_ files from killed processes
    # Only recover files older than 30 seconds to avoid racing with active processors
    CLAIM_NOW=$(date +%s)
    for CLAIMED in "$INBOX"/.claimed_*.json; do
      [ -f "$CLAIMED" ] || continue
      CLAIM_MTIME=$(stat -c %Y "$CLAIMED" 2>/dev/null || stat -f %m "$CLAIMED" 2>/dev/null || echo "$CLAIM_NOW")
      [ $((CLAIM_NOW - CLAIM_MTIME)) -lt 30 ] && continue  # Skip recent — probably still being processed
      ORIG_NAME=$(basename "$CLAIMED" | sed 's/^\.claimed_//')
      mv "$CLAIMED" "$INBOX/$ORIG_NAME" 2>/dev/null || true
    done

    for MSG_FILE in "$INBOX"/*.json; do
      [ -f "$MSG_FILE" ] || continue
      STATUS=$(jq -r '.status' "$MSG_FILE" 2>/dev/null) || continue
      [ "$STATUS" = "pending" ] || continue

      # Claim the message atomically — rename prevents double delivery from concurrent hooks
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
      MSG_URGENCY=$(jq -r '.metadata.urgency // "normal"' "$CLAIMED_FILE")

      TO_NAME="$SESSION_NAME"

      ALL_MESSAGES="${ALL_MESSAGES}\n--- Message for '${TO_NAME}' (${TO_ID}) from '${FROM_PROJECT}' (${FROM_ID}) [${MSG_TYPE}] ---"
      ALL_MESSAGES="${ALL_MESSAGES}\nMessage ID: ${MSG_ID}"
      if [ -n "$CONV_ID" ] && [ "$CONV_ID" != "null" ]; then
        ALL_MESSAGES="${ALL_MESSAGES}\nConversation: ${CONV_ID}"
      fi
      if [ -n "$IN_REPLY_TO" ] && [ "$IN_REPLY_TO" != "null" ]; then
        ALL_MESSAGES="${ALL_MESSAGES}\nIn reply to: ${IN_REPLY_TO}"
      fi
      if [ "$MSG_URGENCY" != "normal" ]; then
        ALL_MESSAGES="${ALL_MESSAGES}\nUrgency: ${MSG_URGENCY}"
      fi
      ALL_MESSAGES="${ALL_MESSAGES}\nContent: ${CONTENT}"
      ALL_MESSAGES="${ALL_MESSAGES}\n"
      ALL_MESSAGES="${ALL_MESSAGES}\nTo respond: BRIDGE_SESSION_ID=${TO_ID} bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh\" ${FROM_ID} response \"Your answer\" --reply-to ${MSG_ID} --conversation ${CONV_ID}"
      ALL_MESSAGES="${ALL_MESSAGES}\n"

      # Defer deletion — will delete AFTER output is written to stdout
      FILES_TO_DELETE="${FILES_TO_DELETE} ${CLAIMED_FILE}"

      TOTAL_COUNT=$((TOTAL_COUNT + 1))
    done
  fi
else
  # Legacy mode: scan ALL sessions for pending inbox messages
  for SESSION_DIR in "$SESSIONS_DIR"/*/; do
    [ -d "$SESSION_DIR" ] || continue
    INBOX="$SESSION_DIR/inbox"
    [ -d "$INBOX" ] || continue

    SESSION_ID=$(basename "$SESSION_DIR")

    # Only scan our own inbox in legacy mode
    if [ -n "$MY_SESSION_ID" ] && [ "$SESSION_ID" != "$MY_SESSION_ID" ]; then
      continue
    fi

    SESSION_NAME="unknown"
    MANIFEST="$SESSION_DIR/manifest.json"
    if [ -f "$MANIFEST" ]; then
      SESSION_NAME=$(jq -r '.projectName // "unknown"' "$MANIFEST")
    fi

    # Recover orphaned .claimed_ files older than 30 seconds
    CLAIM_NOW=$(date +%s)
    for CLAIMED in "$INBOX"/.claimed_*.json; do
      [ -f "$CLAIMED" ] || continue
      CLAIM_MTIME=$(stat -c %Y "$CLAIMED" 2>/dev/null || stat -f %m "$CLAIMED" 2>/dev/null || echo "$CLAIM_NOW")
      [ $((CLAIM_NOW - CLAIM_MTIME)) -lt 30 ] && continue
      ORIG_NAME=$(basename "$CLAIMED" | sed 's/^\.claimed_//')
      mv "$CLAIMED" "$INBOX/$ORIG_NAME" 2>/dev/null || true
    done

    for MSG_FILE in "$INBOX"/*.json; do
      [ -f "$MSG_FILE" ] || continue
      STATUS=$(jq -r '.status' "$MSG_FILE" 2>/dev/null) || continue
      [ "$STATUS" = "pending" ] || continue

      MSG_ID=$(jq -r '.id' "$MSG_FILE")
      FROM_ID=$(jq -r '.from' "$MSG_FILE")
      TO_ID=$(jq -r '.to' "$MSG_FILE")

      # Skip messages not addressed to this session
      if [ "$TO_ID" != "$SESSION_ID" ]; then
        continue
      fi

      # Claim atomically
      MSG_BASENAME=$(basename "$MSG_FILE")
      CLAIMED_FILE="$INBOX/.claimed_${MSG_BASENAME}"
      mv "$MSG_FILE" "$CLAIMED_FILE" 2>/dev/null || continue

      MSG_TYPE=$(jq -r '.type' "$CLAIMED_FILE")
      CONTENT=$(jq -r '.content' "$CLAIMED_FILE")
      FROM_PROJECT=$(jq -r '.metadata.fromProject // "unknown"' "$CLAIMED_FILE")
      IN_REPLY_TO=$(jq -r '.inReplyTo // ""' "$CLAIMED_FILE")

      TO_NAME="$SESSION_NAME"

      ALL_MESSAGES="${ALL_MESSAGES}\n--- Message for '${TO_NAME}' (${TO_ID}) from '${FROM_PROJECT}' (${FROM_ID}) [${MSG_TYPE}] ---"
      ALL_MESSAGES="${ALL_MESSAGES}\nMessage ID: ${MSG_ID}"
      if [ -n "$IN_REPLY_TO" ] && [ "$IN_REPLY_TO" != "null" ]; then
        ALL_MESSAGES="${ALL_MESSAGES}\nIn reply to: ${IN_REPLY_TO}"
      fi
      ALL_MESSAGES="${ALL_MESSAGES}\nContent: ${CONTENT}"
      ALL_MESSAGES="${ALL_MESSAGES}\n"
      ALL_MESSAGES="${ALL_MESSAGES}\nTo respond: BRIDGE_SESSION_ID=${TO_ID} bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh\" ${FROM_ID} response \"Your answer\" ${MSG_ID}"
      ALL_MESSAGES="${ALL_MESSAGES}\n"

      # Defer deletion — will delete AFTER output is written
      FILES_TO_DELETE="${FILES_TO_DELETE} ${CLAIMED_FILE}"

      TOTAL_COUNT=$((TOTAL_COUNT + 1))
    done
  done
fi

if [ "$TOTAL_COUNT" -eq 0 ]; then
  if [ "$STOP_HOOK" = true ]; then
    # No messages — allow stop, reset counter
    [ -n "${STOP_COUNTER_FILE:-}" ] && echo "0" > "$STOP_COUNTER_FILE"
    exit 0
  fi
  echo '{"continue": true}'
  exit 0
fi

SYSTEM_MSG="=== CLAUDE BRIDGE: ${TOTAL_COUNT} pending message(s) ===\nYou MUST respond to queries and acknowledge pings before doing anything else.${ALL_MESSAGES}\n=== END BRIDGE ==="

# --- Stop hook output: block stop and inject messages as additionalContext ---
if [ "$STOP_HOOK" = true ]; then
  STOP_COUNTER=$((STOP_COUNTER + 1))
  if jq -n --arg reason "${TOTAL_COUNT} bridge message(s) pending" \
        --arg ctx "$SYSTEM_MSG" \
    '{decision: "block", reason: $reason, hookSpecificOutput: {hookEventName: "Stop", additionalContext: $ctx}}'; then
    # Output succeeded — commit counter and delete claimed files
    [ -n "${STOP_COUNTER_FILE:-}" ] && echo "$STOP_COUNTER" > "$STOP_COUNTER_FILE"
    for F in $FILES_TO_DELETE; do rm -f "$F" 2>/dev/null || true; done
  else
    # jq failed — restore claimed files so they can be re-delivered
    _restore_claimed_files
  fi
  exit 0
fi

if jq -n --arg msg "$SYSTEM_MSG" '{continue: true, suppressOutput: false, systemMessage: $msg}'; then
  # Output succeeded — delete claimed files
  for F in $FILES_TO_DELETE; do rm -f "$F" 2>/dev/null || true; done
else
  # jq failed — restore claimed files so they can be re-delivered
  _restore_claimed_files
fi

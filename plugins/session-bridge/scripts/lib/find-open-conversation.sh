#!/usr/bin/env bash
# scripts/lib/find-open-conversation.sh — Find the unique open conversation
# between two peers within a project. Sourced by send-message.sh (Task 4 of
# v0.3.2) so the agent can omit --conversation when there's exactly one
# in-flight thread with the recipient.
#
# Function:
#   find_open_conversation <sender-id> <recipient-id> <project-id>
#     stdout = single conv-id on exactly-one match, empty on zero matches
#     exit 0 on zero or one match, exit 2 on multi-match
#     stderr = "Multiple open conversations: <id1> <id2> ..." on multi-match
#   Skips conversations whose .status is "resolved".
#   Matches participant pairs in either (initiator,responder) order.

: "${BRIDGE_DIR:=$HOME/.claude/session-bridge}"

find_open_conversation() {
  local SENDER="$1" RECIPIENT="$2" PROJECT="$3"
  local CONV_DIR="$BRIDGE_DIR/projects/$PROJECT/conversations"
  if [ ! -d "$CONV_DIR" ]; then
    echo ""
    return 0
  fi

  local MATCHES=()
  local F STATUS INIT RESP CID
  for F in "$CONV_DIR"/*.json; do
    [ -f "$F" ] || continue
    STATUS=$(jq -r '.status // ""' "$F" 2>/dev/null)
    [ "$STATUS" = "resolved" ] && continue
    INIT=$(jq -r '.initiator // ""' "$F" 2>/dev/null)
    RESP=$(jq -r '.responder // ""' "$F" 2>/dev/null)
    if { [ "$INIT" = "$SENDER" ] && [ "$RESP" = "$RECIPIENT" ]; } \
      || { [ "$INIT" = "$RECIPIENT" ] && [ "$RESP" = "$SENDER" ]; }; then
      CID=$(jq -r '.conversationId // ""' "$F" 2>/dev/null)
      [ -n "$CID" ] && MATCHES+=("$CID")
    fi
  done

  case "${#MATCHES[@]}" in
    0)
      echo ""
      return 0
      ;;
    1)
      echo "${MATCHES[0]}"
      return 0
      ;;
    *)
      echo "Multiple open conversations: ${MATCHES[*]}" >&2
      return 2
      ;;
  esac
}

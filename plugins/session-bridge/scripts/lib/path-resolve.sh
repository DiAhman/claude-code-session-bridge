#!/usr/bin/env bash
# scripts/lib/path-resolve.sh — Session/project path resolution helpers.
# Sourced by list-inbox.sh, send-message.sh, pre-compact.sh and friends.
# All resolve_* helpers print empty string and exit 0 when nothing is found —
# callers decide how to react to absence. assert_same_project is the only
# function that returns nonzero on failure.
#
# Functions:
#   resolve_session_dir <session-id>     → absolute path; project-scoped first, legacy fallback
#   resolve_inbox <session-id>           → <session-dir>/inbox or empty
#   resolve_outbox <session-id>          → <session-dir>/outbox or empty
#   resolve_project_id <session-id>      → manifest .projectId or empty
#   assert_same_project <caller> <target> → exit 0 iff both share a project-id

: "${BRIDGE_DIR:=$HOME/.claude/session-bridge}"

resolve_session_dir() {
  local SID="$1"
  if [ -z "$SID" ]; then
    echo ""
    return 0
  fi
  # Project-scoped first
  local CANDIDATE
  for CANDIDATE in "$BRIDGE_DIR"/projects/*/sessions/"$SID"; do
    if [ -d "$CANDIDATE" ]; then
      echo "$CANDIDATE"
      return 0
    fi
  done
  # Legacy fallback
  CANDIDATE="$BRIDGE_DIR/sessions/$SID"
  if [ -d "$CANDIDATE" ]; then
    echo "$CANDIDATE"
    return 0
  fi
  echo ""
  return 0
}

resolve_inbox() {
  local DIR
  DIR=$(resolve_session_dir "$1")
  if [ -z "$DIR" ]; then
    echo ""
    return 0
  fi
  echo "$DIR/inbox"
}

resolve_outbox() {
  local DIR
  DIR=$(resolve_session_dir "$1")
  if [ -z "$DIR" ]; then
    echo ""
    return 0
  fi
  echo "$DIR/outbox"
}

resolve_project_id() {
  local DIR
  DIR=$(resolve_session_dir "$1")
  if [ -z "$DIR" ] || [ ! -f "$DIR/manifest.json" ]; then
    echo ""
    return 0
  fi
  jq -r '.projectId // ""' "$DIR/manifest.json" 2>/dev/null
}

assert_same_project() {
  local CALLER="$1" TARGET="$2"
  local CALLER_PID TARGET_PID
  CALLER_PID=$(resolve_project_id "$CALLER")
  TARGET_PID=$(resolve_project_id "$TARGET")
  if [ -z "$CALLER_PID" ] || [ -z "$TARGET_PID" ]; then
    echo "Error: cannot determine project for caller=$CALLER (project='$CALLER_PID') or target=$TARGET (project='$TARGET_PID')" >&2
    return 1
  fi
  if [ "$CALLER_PID" != "$TARGET_PID" ]; then
    echo "Error: caller $CALLER (project=$CALLER_PID) and target $TARGET (project=$TARGET_PID) are in different projects" >&2
    return 1
  fi
  return 0
}

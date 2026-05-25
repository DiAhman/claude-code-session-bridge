#!/usr/bin/env bash
# scripts/project-join.sh — Register a session within a project.
# Usage: project-join.sh <project-name> [--role <role>] [--specialty "<desc>"] [--name "<name>"]
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge), PROJECT_DIR (default: pwd)
# Outputs: session ID to stdout
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }

PROJECT_NAME="${1:?Usage: project-join.sh <project-name> [--role <role>] [--specialty \"<desc>\"] [--name \"<name>\"]}"
shift

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
PROJECT_PATH="$BRIDGE_DIR/projects/$PROJECT_NAME"

if [ ! -d "$PROJECT_PATH" ]; then
  echo "Error: Project '$PROJECT_NAME' does not exist. Create it first with project-create.sh." >&2
  exit 1
fi

# Parse optional args — track which flags were explicitly provided
ROLE=""
SPECIALTY=""
CUSTOM_NAME=""
ROLE_SET=false
SPECIALTY_SET=false
NAME_SET=false
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="$2"; ROLE_SET=true; shift 2 ;;
    --specialty) SPECIALTY="$2"; SPECIALTY_SET=true; shift 2 ;;
    --name) CUSTOM_NAME="$2"; NAME_SET=true; shift 2 ;;
    *) shift ;;
  esac
done

BRIDGE_SESSION_FILE="$PROJECT_DIR/.claude/bridge-session"
BRIDGE_ROLE_FILE="$PROJECT_DIR/.claude/bridge-role"

# Load persisted role/specialty if no explicit flags provided
if [ "$ROLE_SET" = false ] && [ -f "$BRIDGE_ROLE_FILE" ]; then
  SAVED_ROLE=$(jq -r '.role // ""' "$BRIDGE_ROLE_FILE" 2>/dev/null)
  [ -n "$SAVED_ROLE" ] && ROLE="$SAVED_ROLE"
fi
if [ "$SPECIALTY_SET" = false ] && [ -f "$BRIDGE_ROLE_FILE" ]; then
  SAVED_SPEC=$(jq -r '.specialty // ""' "$BRIDGE_ROLE_FILE" 2>/dev/null)
  [ -n "$SAVED_SPEC" ] && SPECIALTY="$SAVED_SPEC"
fi
if [ "$NAME_SET" = false ] && [ -f "$BRIDGE_ROLE_FILE" ]; then
  SAVED_NAME=$(jq -r '.name // ""' "$BRIDGE_ROLE_FILE" 2>/dev/null)
  [ -n "$SAVED_NAME" ] && CUSTOM_NAME="$SAVED_NAME"
fi

# Apply defaults for anything still unset
[ -z "$ROLE" ] && ROLE="specialist"
SESSION_NAME="${CUSTOM_NAME:-$(basename "$PROJECT_DIR")}"

# Strict mode: error if this PROJECT_DIR is already a member.
# Resumption is the job of resume-session.sh, not project-join.sh.
if [ -f "$BRIDGE_SESSION_FILE" ]; then
  EXISTING_ID=$(cat "$BRIDGE_SESSION_FILE" 2>/dev/null || echo "")
  if [ -n "$EXISTING_ID" ]; then
    EXISTING_DIR="$PROJECT_PATH/sessions/$EXISTING_ID"
    if [ -d "$EXISTING_DIR" ]; then
      echo "Error: $PROJECT_DIR is already a member of project '$PROJECT_NAME' as session $EXISTING_ID." >&2
      echo "  - To resume that session, just restart Claude Code (SessionStart hook auto-resumes)." >&2
      echo "  - To replace it with a new session, run: /bridge remove $EXISTING_ID" >&2
      exit 1
    fi
  fi
fi

# Create new session
SESSION_ID=$(set +o pipefail; LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)
SESSION_DIR="$PROJECT_PATH/sessions/$SESSION_ID"
mkdir -p "$SESSION_DIR/inbox" "$SESSION_DIR/outbox"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TMP=$(mktemp "$SESSION_DIR/manifest.XXXXXX")
jq -n \
  --arg sid "$SESSION_ID" \
  --arg pid "$PROJECT_NAME" \
  --arg pname "$SESSION_NAME" \
  --arg ppath "$PROJECT_DIR" \
  --arg role "$ROLE" \
  --arg spec "$SPECIALTY" \
  --arg now "$NOW" \
  '{
    sessionId: $sid,
    projectId: $pid,
    projectName: $pname,
    projectPath: $ppath,
    role: $role,
    specialty: $spec,
    startedAt: $now,
    lastHeartbeat: $now,
    status: "active"
  }' > "$TMP" \
  && mv "$TMP" "$SESSION_DIR/manifest.json" \
  || { rm -f "$TMP"; exit 1; }

# Write bridge-session pointer (atomic) and persist role
mkdir -p "$PROJECT_DIR/.claude"
BS_TMP=$(mktemp "$PROJECT_DIR/.claude/bridge-session.XXXXXX")
echo -n "$SESSION_ID" > "$BS_TMP"
mv "$BS_TMP" "$BRIDGE_SESSION_FILE"
ROLE_TMP2=$(mktemp "$PROJECT_DIR/.claude/bridge-role.XXXXXX")
jq -n --arg role "$ROLE" --arg spec "$SPECIALTY" --arg name "$SESSION_NAME" --arg project "$PROJECT_NAME" \
  '{role: $role, specialty: $spec, name: $name, project: $project}' > "$ROLE_TMP2" \
  && mv "$ROLE_TMP2" "$BRIDGE_ROLE_FILE" \
  || rm -f "$ROLE_TMP2"

# Set BRIDGE_SESSION_ID in env file if available
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "BRIDGE_SESSION_ID=$SESSION_ID" >> "$CLAUDE_ENV_FILE"
fi

# Start inbox watcher in background — verify it actually started
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCHER_SCRIPT="$SCRIPT_DIR/inbox-watcher.sh"
if [ -f "$WATCHER_SCRIPT" ]; then
  BRIDGE_DIR="$BRIDGE_DIR" bash "$WATCHER_SCRIPT" "$SESSION_ID" "$PROJECT_NAME" >/dev/null 2>&1 &
  WATCHER_PID=$!
  sleep 0.1
  if kill -0 "$WATCHER_PID" 2>/dev/null; then
    echo "$WATCHER_PID" > "$SESSION_DIR/watcher.pid"
    disown "$WATCHER_PID"
  else
    echo "Warning: Inbox watcher failed to start" >&2
  fi
fi

# Start heartbeat daemon (separate from watcher; owns the heartbeat file)
HEARTBEAT_SCRIPT="$SCRIPT_DIR/heartbeat-daemon.sh"
if [ -f "$HEARTBEAT_SCRIPT" ]; then
  bash "$HEARTBEAT_SCRIPT" "$SESSION_DIR" >/dev/null 2>&1 &
  HB_PID=$!
  sleep 0.1
  if kill -0 "$HB_PID" 2>/dev/null; then
    disown "$HB_PID" 2>/dev/null || true
  else
    echo "Warning: heartbeat-daemon failed to start" >&2
  fi
fi

echo -n "$SESSION_ID"

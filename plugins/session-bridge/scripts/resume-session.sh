#!/usr/bin/env bash
# scripts/resume-session.sh — Re-bind a Claude Code session to its existing bridge identity.
# Called by auto-join.sh (SessionStart hook target).
# Reads .claude/bridge-role for project context and .claude/bridge-session for prior SID.
# If valid: flips status active, restarts heartbeat-daemon, outputs SID.
# If invalid (session dir gone): emits loud error to stderr, does NOT silently
# create a new SID. Returns nonzero so auto-join.sh surfaces the error.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
BRIDGE_SESSION_FILE="$PROJECT_DIR/.claude/bridge-session"
BRIDGE_ROLE_FILE="$PROJECT_DIR/.claude/bridge-role"

if [ ! -f "$BRIDGE_ROLE_FILE" ]; then
  echo "Error: no .claude/bridge-role in $PROJECT_DIR — run /bridge project join first" >&2
  exit 1
fi
if [ ! -f "$BRIDGE_SESSION_FILE" ]; then
  echo "Error: no .claude/bridge-session in $PROJECT_DIR — run /bridge project join first" >&2
  exit 1
fi

PROJECT_NAME=$(jq -r '.project // ""' "$BRIDGE_ROLE_FILE")
SESSION_ID=$(cat "$BRIDGE_SESSION_FILE" 2>/dev/null | head -c 6)

if [ -z "$PROJECT_NAME" ] || [ -z "$SESSION_ID" ]; then
  echo "Error: corrupt .claude/bridge-* files in $PROJECT_DIR" >&2
  exit 1
fi

SESSION_DIR="$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$SESSION_ID"
MANIFEST="$SESSION_DIR/manifest.json"

if [ ! -d "$SESSION_DIR" ] || [ ! -f "$MANIFEST" ]; then
  cat >&2 <<EOF
=== BRIDGE RESUME FAILED ===
Session $SESSION_ID no longer exists in project $PROJECT_NAME.
This means the session was explicitly removed (/bridge remove)
or destroyed (long-term cleanup).
Run: /bridge project join $PROJECT_NAME
to re-register with a new ID. Existing conversations addressed
to the old ID will need to be re-routed.
=== END BRIDGE ===
EOF
  exit 1
fi

# Update manifest: flip status → active, refresh heartbeat field, apply role updates if changed
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAVED_ROLE=$(jq -r '.role // ""' "$BRIDGE_ROLE_FILE")
SAVED_SPEC=$(jq -r '.specialty // ""' "$BRIDGE_ROLE_FILE")
SAVED_NAME=$(jq -r '.name // ""' "$BRIDGE_ROLE_FILE")

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TMP=$(mktemp "$SESSION_DIR/manifest.XXXXXX")
jq --arg hb "$NOW" \
   --arg status "active" \
   --arg role "$SAVED_ROLE" \
   --arg spec "$SAVED_SPEC" \
   --arg name "$SAVED_NAME" \
   '.lastHeartbeat = $hb | .status = $status | .role = (if $role == "" then .role else $role end) | .specialty = (if $spec == "" then .specialty else $spec end) | .projectName = (if $name == "" then .projectName else $name end)' \
   "$MANIFEST" > "$TMP" && mv "$TMP" "$MANIFEST" || { rm -f "$TMP"; exit 1; }

# Restart inbox-watcher if dead
WATCHER_SCRIPT="$SCRIPT_DIR/inbox-watcher.sh"
WATCHER_PID_FILE="$SESSION_DIR/watcher.pid"
NEED_WATCHER=true
if [ -f "$WATCHER_PID_FILE" ]; then
  OLD_W_PID=$(cat "$WATCHER_PID_FILE" 2>/dev/null || echo "")
  [ -n "$OLD_W_PID" ] && kill -0 "$OLD_W_PID" 2>/dev/null && NEED_WATCHER=false
fi
if [ "$NEED_WATCHER" = true ] && [ -f "$WATCHER_SCRIPT" ]; then
  BRIDGE_DIR="$BRIDGE_DIR" bash "$WATCHER_SCRIPT" "$SESSION_ID" "$PROJECT_NAME" >/dev/null 2>&1 &
  W_PID=$!
  sleep 0.1
  kill -0 "$W_PID" 2>/dev/null && echo "$W_PID" > "$WATCHER_PID_FILE" && disown "$W_PID" 2>/dev/null || true
fi

# Restart heartbeat-daemon if dead
HEARTBEAT_SCRIPT="$SCRIPT_DIR/heartbeat-daemon.sh"
HB_PID_FILE="$SESSION_DIR/heartbeat-daemon.pid"
NEED_HEARTBEAT=true
if [ -f "$HB_PID_FILE" ]; then
  OLD_HB_PID=$(cat "$HB_PID_FILE" 2>/dev/null || echo "")
  [ -n "$OLD_HB_PID" ] && kill -0 "$OLD_HB_PID" 2>/dev/null && NEED_HEARTBEAT=false
fi
if [ "$NEED_HEARTBEAT" = true ] && [ -f "$HEARTBEAT_SCRIPT" ]; then
  bash "$HEARTBEAT_SCRIPT" "$SESSION_DIR" >/dev/null 2>&1 &
  HB_PID=$!
  sleep 0.1
  kill -0 "$HB_PID" 2>/dev/null && disown "$HB_PID" 2>/dev/null || true
fi

# Emit the SID for auto-join.sh
echo -n "$SESSION_ID"

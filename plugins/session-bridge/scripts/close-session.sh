#!/usr/bin/env bash
# scripts/close-session.sh — Graceful offline transition.
# Called by SessionEnd hook (non-destructive). Sets status=offline,
# kills the heartbeat-daemon + inbox-watcher + listener, removes
# ephemeral runtime PID files. Does NOT destroy session dir or
# remove bridge-session pointer — those persist for resume-session.sh.
set -euo pipefail

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
BRIDGE_SESSION_FILE="$PROJECT_DIR/.claude/bridge-session"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/stale-check.sh
source "$SCRIPT_DIR/lib/stale-check.sh"

# Find session ID
SESSION_ID=""
if [ -n "${BRIDGE_SESSION_ID:-}" ]; then
  SESSION_ID="$BRIDGE_SESSION_ID"
elif [ -f "$BRIDGE_SESSION_FILE" ]; then
  SESSION_ID=$(cat "$BRIDGE_SESSION_FILE" 2>/dev/null || echo "")
fi

if [ -z "$SESSION_ID" ]; then
  exit 0  # No bridge session here; nothing to close
fi

# Resolve session directory
SESSION_DIR=""
for PM in "$BRIDGE_DIR"/projects/*/sessions/"$SESSION_ID"/manifest.json; do
  [ -f "$PM" ] || continue
  SESSION_DIR=$(dirname "$PM")
  break
done
if [ -z "$SESSION_DIR" ] && [ -d "$BRIDGE_DIR/sessions/$SESSION_ID" ]; then
  SESSION_DIR="$BRIDGE_DIR/sessions/$SESSION_ID"
fi

if [ -z "$SESSION_DIR" ] || [ ! -d "$SESSION_DIR" ]; then
  exit 0
fi

MANIFEST="$SESSION_DIR/manifest.json"
[ -f "$MANIFEST" ] || exit 0

# Step 1 (CRITICAL ORDER): flip status to offline BEFORE killing the daemon.
# This prevents a race where the heartbeat-daemon's EXIT trap sees status=active
# and falsely marks the session as stale.
set_status "$MANIFEST" "offline"

# Step 2: kill heartbeat-daemon
HB_PID_FILE="$SESSION_DIR/heartbeat-daemon.pid"
if [ -f "$HB_PID_FILE" ]; then
  HB_PID=$(cat "$HB_PID_FILE" 2>/dev/null || echo "")
  if [ -n "$HB_PID" ] && kill -0 "$HB_PID" 2>/dev/null; then
    kill "$HB_PID" 2>/dev/null || true
  fi
fi

# Step 3: kill inbox-watcher
WATCHER_PID_FILE="$SESSION_DIR/watcher.pid"
if [ -f "$WATCHER_PID_FILE" ]; then
  W_PID=$(cat "$WATCHER_PID_FILE" 2>/dev/null || echo "")
  if [ -n "$W_PID" ] && kill -0 "$W_PID" 2>/dev/null; then
    kill "$W_PID" 2>/dev/null || true
  fi
fi

# Step 4: kill any active inotifywait/fswatch child of bridge-listen.sh.
# The PID file holds the watcher child's PID (set by bridge-listen.sh, not
# the parent script's PID). Killing the watcher causes the parent's `wait`
# to return, allowing it to exit naturally on the next loop iteration.
LISTENER_PID_FILE="$SESSION_DIR/bridge-listen-child.pid"
if [ -f "$LISTENER_PID_FILE" ]; then
  L_PID=$(cat "$LISTENER_PID_FILE" 2>/dev/null || echo "")
  if [ -n "$L_PID" ] && kill -0 "$L_PID" 2>/dev/null; then
    kill "$L_PID" 2>/dev/null || true
  fi
fi

# Step 5: remove ephemeral runtime PID files (heartbeat daemon's trap removes its own)
rm -f "$WATCHER_PID_FILE" "$LISTENER_PID_FILE" 2>/dev/null || true

# Persistence-first: do NOT remove session dir, manifest (beyond status field),
# bridge-listen.log, .delivered/, inbox, outbox, conversations,
# .claude/bridge-session, .claude/bridge-role. All preserved.

exit 0

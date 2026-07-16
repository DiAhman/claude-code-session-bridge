#!/usr/bin/env bash
# scripts/heartbeat-daemon.sh — Background heartbeat producer for a bridge session.
# Usage: heartbeat-daemon.sh <session-dir>
# Env: HEARTBEAT_INTERVAL (default 60s) — interval between heartbeat writes
# Writes <session-dir>/heartbeat every interval. Writes <session-dir>/heartbeat-daemon.pid on start.
# On EXIT (any signal): if manifest status=active, flips to "stale".
# Designed to run as a detached background process per session.
set -euo pipefail

SESSION_DIR="${1:?Usage: heartbeat-daemon.sh <session-dir>}"
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-60}"

if [ ! -d "$SESSION_DIR" ]; then
  echo "Error: session dir $SESSION_DIR does not exist" >&2
  exit 1
fi

MANIFEST="$SESSION_DIR/manifest.json"
HB_FILE="$SESSION_DIR/heartbeat"
PID_FILE="$SESSION_DIR/heartbeat-daemon.pid"
LOG_FILE="$SESSION_DIR/bridge-listen.log"

if [ ! -f "$MANIFEST" ]; then
  echo "Error: manifest $MANIFEST does not exist" >&2
  exit 1
fi

# Source the stale-check lib for set_status (used in EXIT trap)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/stale-check.sh
source "$SCRIPT_DIR/lib/stale-check.sh"

# Logging helper (shares bridge-listen.log convention from v0.2.22)
_log() {
  local TS
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$TS] ($$ heartbeat-daemon) $*" >> "$LOG_FILE" 2>/dev/null || true
}

# EXIT trap: classify our death and update status accordingly.
_on_exit() {
  local CURRENT_STATUS
  CURRENT_STATUS=$(jq -r '.status // ""' "$MANIFEST" 2>/dev/null || echo "")
  case "$CURRENT_STATUS" in
    active)
      set_status "$MANIFEST" "stale"
      _log "EXIT producer dying unexpectedly (status was active → stale)"
      ;;
    offline|stale|removed)
      _log "EXIT clean (status=$CURRENT_STATUS)"
      ;;
    *)
      _log "EXIT unknown status='$CURRENT_STATUS'"
      ;;
  esac
  rm -f "$PID_FILE" 2>/dev/null || true
}
# EXIT handler runs whenever the shell exits. INT/TERM need to *cause* an
# exit (bash continues after a signal-handler returns unless we explicitly
# exit). Forwarding to `exit` triggers the EXIT trap once.
trap _on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# Record our PID for the on-demand stale-detector
echo "$$" > "$PID_FILE"
_log "START interval=${HEARTBEAT_INTERVAL}s session_dir=$SESSION_DIR"

# Write an initial heartbeat immediately so consumers don't see a stale window.
# write_heartbeat (from lib/stale-check.sh) is the single canonical implementation —
# shared with send-message.sh and bridge-listen.sh's on-traffic heartbeat bumps (#19).
write_heartbeat "$SESSION_DIR"

# Main loop: tick every HEARTBEAT_INTERVAL seconds
while true; do
  sleep "$HEARTBEAT_INTERVAL" &
  SLEEP_PID=$!
  # Wait but allow signal interruption (the trap will run on TERM/INT)
  wait "$SLEEP_PID" 2>/dev/null || true
  # Confirm manifest still exists; if not, the session was removed — exit
  [ -f "$MANIFEST" ] || exit 0
  write_heartbeat "$SESSION_DIR"
done

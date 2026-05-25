#!/usr/bin/env bash
# scripts/lib/stale-check.sh — Shared helpers for session staleness detection.
# Sourced by send-message.sh and list-peers.sh.
# Functions:
#   get_heartbeat_age <heartbeat-file>     → echoes age in seconds (or 99999999 if missing)
#   is_producer_alive <pid>                 → exit 0 if alive AND cmdline matches heartbeat-daemon
#   is_stale <session-dir> <threshold-sec>  → exit 0 if session is stale
#   set_status <manifest-file> <new-status> → atomic manifest update

get_heartbeat_age() {
  local HB_FILE="$1"
  if [ ! -f "$HB_FILE" ]; then
    echo "99999999"
    return 0
  fi
  local HB_STR HB_EPOCH NOW_EPOCH
  HB_STR=$(cat "$HB_FILE" 2>/dev/null | head -1)
  if [ -z "$HB_STR" ]; then
    echo "99999999"
    return 0
  fi
  # BSD date first (macOS), GNU date fallback (Linux)
  HB_EPOCH=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$HB_STR" +%s 2>/dev/null \
    || date -u -d "$HB_STR" +%s 2>/dev/null \
    || echo "0")
  if [ "$HB_EPOCH" -eq 0 ]; then
    echo "99999999"
    return 0
  fi
  NOW_EPOCH=$(date -u +%s)
  echo $((NOW_EPOCH - HB_EPOCH))
}

is_producer_alive() {
  local PID="$1"
  [ -z "$PID" ] && return 1
  kill -0 "$PID" 2>/dev/null || return 1
  # Defensive: verify the PID is actually our heartbeat-daemon (guards against PID reuse)
  if [ -r "/proc/$PID/cmdline" ]; then
    # Linux: read /proc/<pid>/cmdline (null-separated)
    { tr '\0' ' ' < "/proc/$PID/cmdline"; } 2>/dev/null | grep -qE "(^|/| )heartbeat-daemon\.sh( |$)"
  else
    # macOS: use ps
    ps -p "$PID" -o command= 2>/dev/null | grep -qE "(^|/| )heartbeat-daemon\.sh( |$)"
  fi
}

is_stale() {
  local SESSION_DIR="$1"
  local THRESHOLD="${2:-300}"
  local MANIFEST="$SESSION_DIR/manifest.json"
  local HB_FILE="$SESSION_DIR/heartbeat"
  local PID_FILE="$SESSION_DIR/heartbeat-daemon.pid"

  [ -f "$MANIFEST" ] || return 1
  local STATUS
  STATUS=$(jq -r '.status // "active"' "$MANIFEST" 2>/dev/null)
  # Only "active" sessions can become stale; offline/stale/removed don't transition here
  [ "$STATUS" = "active" ] || return 1

  local AGE
  AGE=$(get_heartbeat_age "$HB_FILE")
  [ "$AGE" -lt "$THRESHOLD" ] && return 1

  # Heartbeat looks stale. But check if producer PID is still alive —
  # protects against false positives after system suspend/resume.
  local PID=""
  [ -f "$PID_FILE" ] && PID=$(cat "$PID_FILE" 2>/dev/null)
  if is_producer_alive "$PID"; then
    return 1
  fi

  return 0
}

set_status() {
  local MANIFEST="$1"
  local NEW_STATUS="$2"
  [ -f "$MANIFEST" ] || return 1
  local TMP
  TMP=$(mktemp "$(dirname "$MANIFEST")/manifest.XXXXXX")
  jq --arg s "$NEW_STATUS" '.status = $s' "$MANIFEST" > "$TMP" 2>/dev/null \
    && mv "$TMP" "$MANIFEST" \
    || { rm -f "$TMP"; return 1; }
}

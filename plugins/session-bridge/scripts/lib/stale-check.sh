#!/usr/bin/env bash
# scripts/lib/stale-check.sh — Shared helpers for session staleness detection.
# Sourced by send-message.sh and list-peers.sh.
# Functions:
#   get_heartbeat_age <heartbeat-file>     → echoes age in seconds (or 99999999 if missing)
#   is_producer_alive <pid>                 → exit 0 if alive AND cmdline matches heartbeat-daemon
#   is_stale <session-dir> <threshold-sec>  → exit 0 if session is stale
#   set_status <manifest-file> <new-status> → atomic manifest update
#   write_heartbeat <session-dir>           → atomic mktemp+mv timestamp write
#   set_lifecycle <manifest-file> <value>   → atomic manifest .lifecycle update
#   ensure_producer_alive <session-dir>     → relaunch heartbeat-daemon if PID dead/missing
#                                              (spawn-at-most-one via flock on a dedicated
#                                              .lock file — safe under concurrent callers)

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

write_heartbeat() {
  local SESSION_DIR="$1"
  [ -d "$SESSION_DIR" ] || return 1
  local NOW TMP
  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  TMP=$(mktemp "$SESSION_DIR/heartbeat.XXXXXX") || return 1
  printf '%s' "$NOW" > "$TMP" || { rm -f "$TMP"; return 1; }
  mv "$TMP" "$SESSION_DIR/heartbeat" || { rm -f "$TMP"; return 1; }
}

set_lifecycle() {
  local MANIFEST="$1"
  local NEW_LIFECYCLE="$2"
  [ -f "$MANIFEST" ] || return 1
  local TMP
  TMP=$(mktemp "$(dirname "$MANIFEST")/manifest.XXXXXX") || return 1
  jq --arg l "$NEW_LIFECYCLE" '.lifecycle = $l' "$MANIFEST" > "$TMP" 2>/dev/null \
    && mv "$TMP" "$MANIFEST" \
    || { rm -f "$TMP"; return 1; }
}

ensure_producer_alive() {
  local SESSION_DIR="$1"
  local PID_FILE="$SESSION_DIR/heartbeat-daemon.pid"
  local LOCK_FILE="$SESSION_DIR/heartbeat-daemon.lock"
  local PID=""

  # Fast path: daemon already alive — cheap check, no lock needed.
  [ -f "$PID_FILE" ] && PID=$(cat "$PID_FILE" 2>/dev/null)
  if [ -n "$PID" ] && is_producer_alive "$PID"; then
    return 0
  fi

  # Slow path: producer looks dead/missing. Serialize spawn attempts via
  # flock on a DEDICATED lock file — not the PID file itself, since that file
  # is rm'd and recreated during spawn, which would fight with an fd bound to
  # it. This guarantees spawn-at-most-one under concurrent callers (task-5
  # brief assumes this mutex as Task 2's contract): whichever caller loses
  # the race blocks on flock, then re-checks under the lock and finds the
  # winner's daemon already alive, so it never spawns a duplicate.
  (
    flock -x 200

    # Re-check under the lock — another caller may have already spawned
    # while we were waiting on the lock.
    local RECHECK_PID=""
    [ -f "$PID_FILE" ] && RECHECK_PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$RECHECK_PID" ] && is_producer_alive "$RECHECK_PID"; then
      exit 0
    fi

    # Producer dead/missing — relaunch detached.
    # SCRIPT_DIR resolves to scripts/ (parent of lib/) regardless of caller's cwd.
    local LIB_DIR SCRIPT_DIR DAEMON NEW_PID
    LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SCRIPT_DIR="$(cd "$LIB_DIR/.." && pwd)"
    DAEMON="$SCRIPT_DIR/heartbeat-daemon.sh"
    [ -f "$DAEMON" ] || exit 1
    # Drop any stale PID file so the poll below unambiguously detects the NEW
    # daemon's write rather than an old (dead) PID that happened to linger.
    rm -f "$PID_FILE" 2>/dev/null || true
    # Exact detachment incantation from spec C3: setsid + nohup + redirected fds + disown.
    # setsid drops the controlling tty; nohup ignores SIGHUP; </dev/null disconnects
    # stdin; >/dev/null 2>&1 disconnects stdout/stderr — the daemon inherits none of
    # the caller's file descriptors. disown removes the job from this shell's table
    # so the caller's own exit/wait semantics are never entangled with the daemon.
    # 200>&- additionally closes the flock fd in the child: without it, the
    # long-running daemon inherits fd 200 and holds the lock open for its
    # entire lifetime (the daemon never exits), starving every other caller
    # blocked on `flock -x 200` forever — a real deadlock caught by Test 18.
    setsid nohup bash "$DAEMON" "$SESSION_DIR" </dev/null >/dev/null 2>&1 200>&- &
    NEW_PID=$!
    disown "$NEW_PID" 2>/dev/null || true
    # Bounded poll for the PID file rather than a blind sleep-then-hope: this
    # guarantees that whenever ensure_producer_alive returns 0, the daemon has
    # ALREADY written its PID file, so callers never observe a return-then-file
    # race. Cap at ~2s so a spawn that dies immediately still fails fast.
    local WAITED_MS=0
    while [ ! -f "$PID_FILE" ]; do
      kill -0 "$NEW_PID" 2>/dev/null || exit 1
      if [ "$WAITED_MS" -ge 2000 ]; then
        exit 1
      fi
      sleep 0.05
      WAITED_MS=$((WAITED_MS + 50))
    done
    exit 0
  ) 200>"$LOCK_FILE"
}

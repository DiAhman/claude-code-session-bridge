#!/usr/bin/env bash
# scripts/prune.sh — Operator-controlled disk maintenance.
# Usage: prune.sh [--delivered N] [--outbox N] [--conversations N] [--logs N] [--dry-run]
# N is days. Defaults are generous (7+) to favor persistence. Without flags, prints help.
set -euo pipefail

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"

DELIVERED_DAYS=""
OUTBOX_DAYS=""
CONVERSATIONS_DAYS=""
LOGS_DAYS=""
DRY_RUN=false

# Bare invocation prints help, matching the embedded usage text.
if [ $# -eq 0 ]; then
  set -- --help
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --delivered) DELIVERED_DAYS="$2"; shift 2 ;;
    --outbox) OUTBOX_DAYS="$2"; shift 2 ;;
    --conversations) CONVERSATIONS_DAYS="$2"; shift 2 ;;
    --logs) LOGS_DAYS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --all)
      if [ -z "${2:-}" ] || [[ "$2" == --* ]]; then
        echo "Error: --all requires N (days)" >&2
        exit 1
      fi
      DELIVERED_DAYS="$2"
      OUTBOX_DAYS="$2"
      CONVERSATIONS_DAYS="$2"
      LOGS_DAYS="$2"
      shift 2
      ;;
    -h|--help)
      cat <<EOF
Usage: prune.sh [OPTIONS]

  --delivered N      Prune <inbox>/.delivered/*.json older than N days
  --outbox N         Prune outbox messages older than N days
  --conversations N  Prune resolved conversations older than N days
  --logs N           Prune bridge-listen.log lines older than N days (truncate)
  --all N            All four with N as the threshold
  --dry-run          List what would be deleted without deleting

Without flags, prints this help.

Defaults are generous (no auto-prune; ever). Operator must invoke
with explicit thresholds. Logs older than N use file mtime, since
log lines don't have parseable timestamps in the existing format.
EOF
      exit 0
      ;;
    *) echo "Warning: unknown flag '$1' ignored" >&2; shift ;;
  esac
done

_now_epoch=$(date -u +%s)
_secs_per_day=86400

_prune_files() {
  # $1: human label, $2: days threshold, $3+: glob patterns
  local LABEL="$1" DAYS="$2"
  shift 2
  local cutoff_epoch=$((_now_epoch - DAYS * _secs_per_day))
  local action="DELETE"
  $DRY_RUN && action="DRY-RUN"
  for PATTERN in "$@"; do
    for F in $PATTERN; do
      [ -f "$F" ] || continue
      local F_MTIME
      F_MTIME=$(stat -c %Y "$F" 2>/dev/null || stat -f %m "$F" 2>/dev/null || echo "$_now_epoch")
      if [ "$F_MTIME" -lt "$cutoff_epoch" ]; then
        echo "$action [$LABEL] $F"
        $DRY_RUN || rm -f "$F"
      fi
    done
  done
}

if [ -n "$DELIVERED_DAYS" ]; then
  _prune_files "delivered" "$DELIVERED_DAYS" \
    "$BRIDGE_DIR"/projects/*/sessions/*/inbox/.delivered/*.json \
    "$BRIDGE_DIR"/sessions/*/inbox/.delivered/*.json
fi

if [ -n "$OUTBOX_DAYS" ]; then
  _prune_files "outbox" "$OUTBOX_DAYS" \
    "$BRIDGE_DIR"/projects/*/sessions/*/outbox/msg-*.json \
    "$BRIDGE_DIR"/sessions/*/outbox/msg-*.json
fi

if [ -n "$CONVERSATIONS_DAYS" ]; then
  # Only resolved conversations are candidates for pruning
  cutoff_epoch=$((_now_epoch - CONVERSATIONS_DAYS * _secs_per_day))
  action="DELETE"
  $DRY_RUN && action="DRY-RUN"
  for CONV_FILE in "$BRIDGE_DIR"/projects/*/conversations/conv-*.json; do
    [ -f "$CONV_FILE" ] || continue
    CONV_STATUS=$(jq -r '.status // ""' "$CONV_FILE" 2>/dev/null || echo "")
    [ "$CONV_STATUS" = "resolved" ] || continue
    F_MTIME=$(stat -c %Y "$CONV_FILE" 2>/dev/null || stat -f %m "$CONV_FILE" 2>/dev/null || echo "$_now_epoch")
    if [ "$F_MTIME" -lt "$cutoff_epoch" ]; then
      echo "$action [conversation] $CONV_FILE"
      $DRY_RUN || rm -f "$CONV_FILE"
    fi
  done
fi

if [ -n "$LOGS_DAYS" ]; then
  cutoff_epoch=$((_now_epoch - LOGS_DAYS * _secs_per_day))
  action="TRUNCATE"
  $DRY_RUN && action="DRY-RUN-TRUNCATE"
  for LOG in "$BRIDGE_DIR"/projects/*/sessions/*/bridge-listen.log "$BRIDGE_DIR"/sessions/*/bridge-listen.log; do
    [ -f "$LOG" ] || continue
    F_MTIME=$(stat -c %Y "$LOG" 2>/dev/null || stat -f %m "$LOG" 2>/dev/null || echo "$_now_epoch")
    if [ "$F_MTIME" -lt "$cutoff_epoch" ]; then
      echo "$action [log] $LOG"
      $DRY_RUN || : > "$LOG"
    fi
  done
fi

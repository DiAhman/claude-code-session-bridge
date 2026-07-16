#!/usr/bin/env bash
# scripts/list-inbox.sh — List messages in a session's inbox (operator forensics).
# Usage: list-inbox.sh [<target-session-id>] [--pending|--delivered|--all] [--since DURATION] [--limit N] [--json]
#   DURATION: integer with optional s|m|h|d suffix (bare integer = seconds). e.g. 30s, 10m, 1h, 7d.
#   When <target-session-id> is omitted, defaults to $BRIDGE_SESSION_ID.
#   Cross-session reads require caller and target to be in the same project.
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge), BRIDGE_SESSION_ID
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/path-resolve.sh
source "$SCRIPT_DIR/lib/path-resolve.sh"

# --- Duration parser: "30s", "10m", "1h", "7d", or bare integer = seconds ---
parse_duration() {
  local D="$1"
  if [[ "$D" =~ ^([0-9]+)([smhd]?)$ ]]; then
    local NUM="${BASH_REMATCH[1]}"
    local UNIT="${BASH_REMATCH[2]:-s}"
    case "$UNIT" in
      s) echo "$NUM" ;;
      m) echo $((NUM * 60)) ;;
      h) echo $((NUM * 3600)) ;;
      d) echo $((NUM * 86400)) ;;
    esac
    return 0
  fi
  echo "Error: invalid --since duration '$D' (expected N or N[s|m|h|d])" >&2
  return 1
}

# --- Age formatter: seconds → 5s / 12m / 3h / 2d ---
fmt_age() {
  local S="$1"
  if [ "$S" -lt 60 ]; then echo "${S}s"
  elif [ "$S" -lt 3600 ]; then echo "$((S / 60))m"
  elif [ "$S" -lt 86400 ]; then echo "$((S / 3600))h"
  else echo "$((S / 86400))d"
  fi
}

# --- Defaults + arg parse ---
TARGET_ID=""
FILTER="pending"
SINCE_SECS=0
LIMIT=0
OUTPUT_JSON=false

while [ $# -gt 0 ]; do
  case "$1" in
    --pending)   FILTER="pending"; shift ;;
    --delivered) FILTER="delivered"; shift ;;
    --all)       FILTER="all"; shift ;;
    --since)     SINCE_SECS=$(parse_duration "$2") || exit 1; shift 2 ;;
    --limit)     LIMIT="$2"; shift 2 ;;
    --json)      OUTPUT_JSON=true; shift ;;
    --)          shift; break ;;
    -*)          echo "Error: unknown flag '$1'" >&2; exit 1 ;;
    *)
      if [ -z "$TARGET_ID" ]; then
        TARGET_ID="$1"; shift
      else
        echo "Error: too many positional arguments" >&2; exit 1
      fi
      ;;
  esac
done

# --- Caller + target resolution ---
CALLER_ID="${BRIDGE_SESSION_ID:-}"
if [ -z "$TARGET_ID" ]; then
  TARGET_ID="$CALLER_ID"
fi
if [ -z "$TARGET_ID" ]; then
  echo "Error: no target session specified and BRIDGE_SESSION_ID not set" >&2
  exit 1
fi

# Project-scope guard: only enforce on true cross-session access.
# Reading your own inbox (TARGET_ID == CALLER_ID, including the
# "target omitted" default above) never needs this. Any genuine
# cross-session read requires a caller identity — if BRIDGE_SESSION_ID
# is unset we cannot determine the caller's project, so fail closed
# instead of silently skipping the check.
if [ "$TARGET_ID" != "$CALLER_ID" ]; then
  if [ -z "$CALLER_ID" ]; then
    echo "Error: cross-session inbox read requires BRIDGE_SESSION_ID to be set (needed for project-scope check)" >&2
    exit 1
  fi
  if ! assert_same_project "$CALLER_ID" "$TARGET_ID"; then
    exit 1
  fi
fi

TARGET_INBOX=$(resolve_inbox "$TARGET_ID")
if [ -z "$TARGET_INBOX" ] || [ ! -d "$TARGET_INBOX" ]; then
  echo "Error: target session '$TARGET_ID' has no inbox" >&2
  exit 1
fi

# --- Gather messages: one row per file as "<epoch>|<status>|<path>" ---
NOW_EPOCH=$(date -u +%s)
CUTOFF_EPOCH=0
if [ "$SINCE_SECS" -gt 0 ]; then
  CUTOFF_EPOCH=$((NOW_EPOCH - SINCE_SECS))
fi

ROWS=""
collect_dir() {
  local DIR="$1" STATUS_LABEL="$2"
  [ -d "$DIR" ] || return 0
  local F TS_STR TS_EPOCH
  for F in "$DIR"/*.json; do
    [ -f "$F" ] || continue
    TS_STR=$(jq -r '.timestamp // ""' "$F" 2>/dev/null || echo "")
    if [ -n "$TS_STR" ]; then
      TS_EPOCH=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$TS_STR" +%s 2>/dev/null \
        || date -u -d "$TS_STR" +%s 2>/dev/null \
        || echo "0")
    else
      TS_EPOCH=0
    fi
    if [ "$CUTOFF_EPOCH" -gt 0 ] && [ "$TS_EPOCH" -lt "$CUTOFF_EPOCH" ]; then
      continue
    fi
    ROWS+="${TS_EPOCH}|${STATUS_LABEL}|${F}"$'\n'
  done
}

case "$FILTER" in
  pending)   collect_dir "$TARGET_INBOX" "pending" ;;
  delivered) collect_dir "$TARGET_INBOX/.delivered" "delivered" ;;
  all)
    collect_dir "$TARGET_INBOX" "pending"
    collect_dir "$TARGET_INBOX/.delivered" "delivered"
    ;;
esac

# Sort newest-first; apply --limit
SORTED=$(printf "%s" "$ROWS" | sort -t'|' -k1,1 -rn)
if [ "$LIMIT" -gt 0 ] && [ -n "$SORTED" ]; then
  SORTED=$(printf "%s\n" "$SORTED" | head -n "$LIMIT")
fi

if [ -z "$SORTED" ]; then
  if [ "$OUTPUT_JSON" = true ]; then
    echo "[]"
  else
    echo "No messages."
  fi
  exit 0
fi

# --- Render ---
if [ "$OUTPUT_JSON" = true ]; then
  JSON_ITEMS="[]"
  while IFS='|' read -r TS_EPOCH STATUS_LABEL F; do
    [ -z "$F" ] && continue
    ID=$(jq -r '.id // ""' "$F")
    FROM=$(jq -r '.from // ""' "$F")
    TYPE=$(jq -r '.type // ""' "$F")
    CONTENT=$(jq -r '.content // ""' "$F")
    SUBJECT=$(printf '%s' "$CONTENT" | head -1 | cut -c1-60)
    if [ "$TS_EPOCH" -gt 0 ]; then
      AGE_SECS=$((NOW_EPOCH - TS_EPOCH))
    else
      AGE_SECS=0
    fi
    JSON_ITEMS=$(jq -n \
      --argjson acc "$JSON_ITEMS" \
      --arg id "$ID" \
      --arg from "$FROM" \
      --arg type "$TYPE" \
      --arg status "$STATUS_LABEL" \
      --argjson age "$AGE_SECS" \
      --arg subject "$SUBJECT" \
      '$acc + [{id:$id, from:$from, type:$type, status:$status, age:$age, subject:$subject}]')
  done <<< "$SORTED"
  echo "$JSON_ITEMS"
else
  printf "%-22s %-10s %-22s %-10s %-8s %s\n" "ID" "FROM" "TYPE" "STATUS" "AGE" "SUBJECT"
  printf "%-22s %-10s %-22s %-10s %-8s %s\n" "--" "----" "----" "------" "---" "-------"
  while IFS='|' read -r TS_EPOCH STATUS_LABEL F; do
    [ -z "$F" ] && continue
    ID=$(jq -r '.id // ""' "$F")
    FROM=$(jq -r '.from // ""' "$F")
    TYPE=$(jq -r '.type // ""' "$F")
    CONTENT=$(jq -r '.content // ""' "$F")
    SUBJECT=$(printf '%s' "$CONTENT" | head -1 | cut -c1-60)
    if [ "$TS_EPOCH" -gt 0 ]; then
      AGE_SECS=$((NOW_EPOCH - TS_EPOCH))
    else
      AGE_SECS=0
    fi
    AGE_FMT=$(fmt_age "$AGE_SECS")
    printf "%-22s %-10s %-22s %-10s %-8s %s\n" "$ID" "$FROM" "$TYPE" "$STATUS_LABEL" "$AGE_FMT" "$SUBJECT"
  done <<< "$SORTED"
fi

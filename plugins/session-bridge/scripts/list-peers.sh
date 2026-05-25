#!/usr/bin/env bash
# scripts/list-peers.sh — List all active bridge sessions.
# Supports both legacy sessions and project-scoped sessions.
# Usage: list-peers.sh [--project <name>]
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge)
set -euo pipefail

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
SESSIONS_DIR="$BRIDGE_DIR/sessions"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/stale-check.sh
source "$SCRIPT_DIR/lib/stale-check.sh"

NOW_EPOCH=$(date -u +%s)
STALE_SECONDS=300  # 5 minutes
FOUND=0

# Parse optional project flag
PROJECT_FILTER=""
if [ "${1:-}" = "--project" ]; then
  PROJECT_FILTER="${2:-}"
fi

# --- Project-scoped sessions ---
for PROJ_JSON in "$BRIDGE_DIR"/projects/*/project.json; do
  [ -f "$PROJ_JSON" ] || continue
  PROJ_NAME=$(jq -r '.projectId' "$PROJ_JSON")
  [ -n "$PROJECT_FILTER" ] && [ "$PROJ_NAME" != "$PROJECT_FILTER" ] && continue

  PROJ_SESSIONS_DIR="$(dirname "$PROJ_JSON")/sessions"
  echo ""
  echo "Project: $PROJ_NAME"
  printf "  %-10s %-20s %-12s %-15s %s\n" "SESSION" "NAME" "ROLE" "STATUS" "SPECIALTY"
  printf "  %-10s %-20s %-12s %-15s %s\n" "-------" "----" "----" "------" "---------"

  for MANIFEST in "$PROJ_SESSIONS_DIR"/*/manifest.json; do
    [ -f "$MANIFEST" ] || continue
    SID=$(jq -r '.sessionId' "$MANIFEST")
    PNAME=$(jq -r '.projectName' "$MANIFEST")
    ROLE=$(jq -r '.role // ""' "$MANIFEST")
    SPEC=$(jq -r '.specialty // ""' "$MANIFEST")
    MANIFEST_STATUS=$(jq -r '.status // "active"' "$MANIFEST")
    SESSION_PATH="$(dirname "$MANIFEST")"

    # Determine display status:
    #   - "offline" or "removed" → as-is
    #   - "stale" → as-is (already detected by lib elsewhere or by daemon EXIT trap)
    #   - "active" → check via is_stale (may flip to stale due to silent producer)
    case "$MANIFEST_STATUS" in
      offline|removed|stale)
        STATUS="$MANIFEST_STATUS"
        ;;
      active)
        if is_stale "$SESSION_PATH" "$STALE_SECONDS"; then
          # On-demand stale-flip: write it back so consumers see it
          set_status "$MANIFEST" "stale"
          STATUS="stale"
        else
          STATUS="active"
        fi
        ;;
      *)
        STATUS="$MANIFEST_STATUS"
        ;;
    esac

    printf "  %-10s %-20s %-12s %-15s %s\n" "$SID" "$PNAME" "$ROLE" "$STATUS" "$SPEC"
    FOUND=$((FOUND + 1))
  done
done

# --- Legacy sessions (backward compat) ---
if [ -z "$PROJECT_FILTER" ] && [ -d "$SESSIONS_DIR" ]; then
  LEGACY_FOUND=0
  LEGACY_OUTPUT=""

  for MANIFEST in "$SESSIONS_DIR"/*/manifest.json; do
    [ -f "$MANIFEST" ] || continue

    SID=$(jq -r '.sessionId' "$MANIFEST")
    PNAME=$(jq -r '.projectName' "$MANIFEST")
    PPATH=$(jq -r '.projectPath' "$MANIFEST")
    MANIFEST_STATUS=$(jq -r '.status // "active"' "$MANIFEST")
    SESSION_PATH="$(dirname "$MANIFEST")"

    # Determine display status:
    #   - "offline" or "removed" → as-is
    #   - "stale" → as-is (already detected by lib elsewhere or by daemon EXIT trap)
    #   - "active" → check via is_stale (may flip to stale due to silent producer)
    case "$MANIFEST_STATUS" in
      offline|removed|stale)
        STATUS="$MANIFEST_STATUS"
        ;;
      active)
        # Legacy compat: register.sh doesn't spawn the heartbeat-daemon, so
        # legacy sessions have no heartbeat file. Fall back to manifest.lastHeartbeat
        # age check (the pre-redesign behavior) when no heartbeat file exists.
        # Project-scoped sessions (which always have a heartbeat-daemon) take the
        # is_stale path.
        if [ -f "$SESSION_PATH/heartbeat" ]; then
          if is_stale "$SESSION_PATH" "$STALE_SECONDS"; then
            set_status "$MANIFEST" "stale"
            STATUS="stale"
          else
            STATUS="active"
          fi
        else
          # Legacy fallback: compute from lastHeartbeat field
          HB=$(jq -r '.lastHeartbeat // ""' "$MANIFEST")
          HB_EPOCH=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$HB" +%s 2>/dev/null \
            || date -u -d "$HB" +%s 2>/dev/null || echo "0")
          AGE=$(( $(date -u +%s) - HB_EPOCH ))
          if [ "$AGE" -gt "$STALE_SECONDS" ]; then
            STATUS="stale"
          else
            STATUS="active"
          fi
        fi
        ;;
      *)
        STATUS="$MANIFEST_STATUS"
        ;;
    esac

    if [ "$LEGACY_FOUND" -eq 0 ]; then
      LEGACY_OUTPUT=$(printf "%-10s %-20s %-8s %s\n" "SESSION" "PROJECT" "STATUS" "PATH")
      LEGACY_OUTPUT="$LEGACY_OUTPUT"$'\n'$(printf "%-10s %-20s %-8s %s\n" "-------" "-------" "------" "----")
    fi
    LEGACY_OUTPUT="$LEGACY_OUTPUT"$'\n'$(printf "%-10s %-20s %-8s %s\n" "$SID" "$PNAME" "$STATUS" "$PPATH")
    LEGACY_FOUND=$((LEGACY_FOUND + 1))
    FOUND=$((FOUND + 1))
  done

  if [ "$LEGACY_FOUND" -gt 0 ]; then
    echo ""
    echo "$LEGACY_OUTPUT"
  fi
fi

if [ "$FOUND" -eq 0 ]; then
  echo "No active bridge sessions."
fi

#!/usr/bin/env bash
# scripts/clear-compacting.sh — UserPromptSubmit hook (runs BEFORE check-inbox.sh).
# If this session's lifecycle is 'compacting', flip back to 'normal' — compaction
# is finished by the time the user submits the next prompt.
# MUST always exit 0 — a failure here would block the user's prompt.
# Env: BRIDGE_SESSION_ID (optional — silently no-op if unset),
#      BRIDGE_DIR (default ~/.claude/session-bridge)
set -euo pipefail

_clear_compacting_main() {
  [ -n "${BRIDGE_SESSION_ID:-}" ] || return 0

  local BRIDGE_DIR_LOCAL="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
  local SCRIPT_DIR_LOCAL
  SCRIPT_DIR_LOCAL="$(cd "$(dirname "$0")" && pwd)"

  # shellcheck source=lib/path-resolve.sh
  source "$SCRIPT_DIR_LOCAL/lib/path-resolve.sh" 2>/dev/null || return 0
  # shellcheck source=lib/stale-check.sh
  source "$SCRIPT_DIR_LOCAL/lib/stale-check.sh" 2>/dev/null || return 0

  local SDIR
  SDIR=$(BRIDGE_DIR="$BRIDGE_DIR_LOCAL" resolve_session_dir "$BRIDGE_SESSION_ID")
  [ -n "$SDIR" ] && [ -f "$SDIR/manifest.json" ] || return 0

  local LC
  LC=$(jq -r '.lifecycle // "normal"' "$SDIR/manifest.json" 2>/dev/null)
  [ "$LC" = "compacting" ] || return 0

  set_lifecycle "$SDIR/manifest.json" "normal" 2>/dev/null || return 0
  return 0
}

_clear_compacting_main "$@" || true
exit 0

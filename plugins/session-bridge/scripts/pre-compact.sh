#!/usr/bin/env bash
# scripts/pre-compact.sh — PreCompact hook: mark this session's lifecycle as
# 'compacting' so peers know responses may be delayed. Records lastCompactStart.
# MUST always exit 0 — a failure here would block context compaction.
# Env: BRIDGE_SESSION_ID (optional — silently no-op if unset),
#      BRIDGE_DIR (default ~/.claude/session-bridge)
set -uo pipefail

_pre_compact_main() {
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

  local NOW
  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Flip lifecycle first (the user-visible signal).
  set_lifecycle "$SDIR/manifest.json" "compacting" 2>/dev/null || return 0

  # Record lastCompactStart on the manifest (best-effort).
  local TMP
  TMP=$(mktemp "$SDIR/manifest.XXXXXX" 2>/dev/null) || return 0
  if jq --arg ts "$NOW" '.lastCompactStart = $ts' "$SDIR/manifest.json" > "$TMP" 2>/dev/null; then
    mv "$TMP" "$SDIR/manifest.json" 2>/dev/null || rm -f "$TMP" 2>/dev/null
  else
    rm -f "$TMP" 2>/dev/null
  fi
  return 0
}

_pre_compact_main "$@" || true
exit 0

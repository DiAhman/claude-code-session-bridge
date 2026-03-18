#!/usr/bin/env bash
# scripts/get-session-id.sh — Reliably find this project's bridge session ID.
# Works even if the agent cd'd into a subdirectory.
#
# Strategy:
# 1. Try .claude/bridge-session in current directory (fast path)
# 2. Scan all session manifests for one whose projectPath is a parent of $(pwd)
#
# Outputs: session ID to stdout, or exits 1 if not found.
set -euo pipefail

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
CURRENT_DIR="${PROJECT_DIR:-$(pwd)}"

# Fast path: .claude/bridge-session in current directory
if [ -f "$CURRENT_DIR/.claude/bridge-session" ]; then
  cat "$CURRENT_DIR/.claude/bridge-session"
  exit 0
fi

# Fallback: scan all session manifests for one whose projectPath is a parent of current dir.
# e.g., if we're at /projects/my-lib/src/main/kotlin and a session has
# projectPath=/projects/my-lib, that's a match.
for MANIFEST in "$BRIDGE_DIR"/sessions/*/manifest.json; do
  [ -f "$MANIFEST" ] || continue
  PROJ_PATH=$(jq -r '.projectPath // ""' "$MANIFEST" 2>/dev/null)
  [ -n "$PROJ_PATH" ] || continue

  # Check: is our current directory inside (or equal to) this project's path?
  case "$CURRENT_DIR" in
    "$PROJ_PATH"|"$PROJ_PATH"/*)
      jq -r '.sessionId' "$MANIFEST"
      exit 0
      ;;
  esac
done

# Not found
echo "NO_BRIDGE_SESSION" >&2
exit 1

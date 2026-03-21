#!/usr/bin/env bash
# scripts/heartbeat.sh — Update lastHeartbeat in manifest.
set -euo pipefail

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"

if [ -n "${BRIDGE_SESSION_ID:-}" ]; then
  SESSION_ID="$BRIDGE_SESSION_ID"
elif [ -f "$PROJECT_DIR/.claude/bridge-session" ]; then
  SESSION_ID=$(cat "$PROJECT_DIR/.claude/bridge-session")
else
  exit 0
fi

# Resolve manifest path: project-scoped first, then legacy
MANIFEST=""
for PM in "$BRIDGE_DIR"/projects/*/sessions/"$SESSION_ID"/manifest.json; do
  [ -f "$PM" ] || continue
  MANIFEST="$PM"
  break
done
[ -z "$MANIFEST" ] && MANIFEST="$BRIDGE_DIR/sessions/$SESSION_ID/manifest.json"
[ -f "$MANIFEST" ] || exit 0

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TMP=$(mktemp "$(dirname "$MANIFEST")/manifest.XXXXXX")
jq --arg hb "$NOW" '.lastHeartbeat = $hb' "$MANIFEST" > "$TMP" \
  && mv "$TMP" "$MANIFEST" \
  || { rm -f "$TMP"; exit 1; }

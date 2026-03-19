#!/usr/bin/env bash
# scripts/project-list.sh — List all projects.
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge)
set -euo pipefail

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
PROJECTS_DIR="$BRIDGE_DIR/projects"

if [ ! -d "$PROJECTS_DIR" ]; then
  echo "No projects found."
  exit 0
fi

FOUND=0
printf "%-25s %-10s %s\n" "PROJECT" "SESSIONS" "CREATED"
printf "%-25s %-10s %s\n" "-------" "--------" "-------"

for PROJ_JSON in "$PROJECTS_DIR"/*/project.json; do
  [ -f "$PROJ_JSON" ] || continue
  PROJ_DIR=$(dirname "$PROJ_JSON")
  PROJ_NAME=$(jq -r '.projectId' "$PROJ_JSON")
  CREATED=$(jq -r '.createdAt // "unknown"' "$PROJ_JSON")

  # Count sessions
  SESSION_COUNT=0
  if [ -d "$PROJ_DIR/sessions" ]; then
    SESSION_COUNT=$(find "$PROJ_DIR/sessions" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  fi

  printf "%-25s %-10s %s\n" "$PROJ_NAME" "$SESSION_COUNT" "$CREATED"
  FOUND=$((FOUND + 1))
done

if [ "$FOUND" -eq 0 ]; then
  echo "No projects found."
fi

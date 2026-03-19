#!/usr/bin/env bash
# scripts/project-update-member.sh — Update a session's manifest fields.
# Usage: project-update-member.sh <project-name> <session-id> [--role <role>] [--specialty "<desc>"] [--name "<name>"]
# Env: BRIDGE_DIR (default: ~/.claude/session-bridge)
# Can target any session in the project (not just your own).
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }

PROJECT_NAME="${1:?Usage: project-update-member.sh <project-name> <session-id> [--role <role>] [--specialty \"<desc>\"] [--name \"<name>\"]}"
TARGET_SESSION="${2:?Missing session-id}"
shift 2

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.claude/session-bridge}"
MANIFEST="$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$TARGET_SESSION/manifest.json"

if [ ! -f "$MANIFEST" ]; then
  echo "Error: Session '$TARGET_SESSION' not found in project '$PROJECT_NAME'." >&2
  exit 1
fi

# Parse flags
ROLE=""
SPECIALTY=""
NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --specialty) SPECIALTY="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$ROLE" ] && [ -z "$SPECIALTY" ] && [ -z "$NAME" ]; then
  echo "Error: Nothing to update. Provide --role, --specialty, or --name." >&2
  exit 1
fi

# Build jq filter
JQ_FILTER="."
JQ_ARGS=()
if [ -n "$ROLE" ]; then
  JQ_FILTER="$JQ_FILTER | .role = \$role"
  JQ_ARGS+=(--arg role "$ROLE")
fi
if [ -n "$SPECIALTY" ]; then
  JQ_FILTER="$JQ_FILTER | .specialty = \$spec"
  JQ_ARGS+=(--arg spec "$SPECIALTY")
fi
if [ -n "$NAME" ]; then
  JQ_FILTER="$JQ_FILTER | .projectName = \$name"
  JQ_ARGS+=(--arg name "$NAME")
fi

TMP=$(mktemp "$(dirname "$MANIFEST")/manifest.XXXXXX")
jq "${JQ_ARGS[@]}" "$JQ_FILTER" "$MANIFEST" > "$TMP"
mv "$TMP" "$MANIFEST"

echo "Updated session $TARGET_SESSION in project $PROJECT_NAME"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREATE="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"
UPDATE="$PLUGIN_DIR/scripts/project-update-member.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"; kill $(jobs -p) 2>/dev/null || true' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJ_DIR="$TEST_TMPDIR/my-app"
mkdir -p "$PROJ_DIR"

BRIDGE_DIR="$BRIDGE_DIR" bash "$CREATE" "test-proj" > /dev/null
SESSION_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJ_DIR" bash "$JOIN" "test-proj")

MANIFEST="$BRIDGE_DIR/projects/test-proj/sessions/$SESSION_ID/manifest.json"

echo "=== test-project-update-member.sh ==="

# Test 1: Update role
BRIDGE_DIR="$BRIDGE_DIR" bash "$UPDATE" "test-proj" "$SESSION_ID" --role orchestrator
assert_json_field "role updated" "$MANIFEST" '.role' "orchestrator"

# Test 2: Update specialty
BRIDGE_DIR="$BRIDGE_DIR" bash "$UPDATE" "test-proj" "$SESSION_ID" --specialty "task coordination, issue triage"
assert_json_field "specialty updated" "$MANIFEST" '.specialty' "task coordination, issue triage"

# Test 3: Update name
BRIDGE_DIR="$BRIDGE_DIR" bash "$UPDATE" "test-proj" "$SESSION_ID" --name "coordinator"
assert_json_field "name updated" "$MANIFEST" '.projectName' "coordinator"

# Test 4: Update multiple fields at once
BRIDGE_DIR="$BRIDGE_DIR" bash "$UPDATE" "test-proj" "$SESSION_ID" --role specialist --specialty "auth" --name "auth-server"
assert_json_field "role set to specialist" "$MANIFEST" '.role' "specialist"
assert_json_field "specialty set to auth" "$MANIFEST" '.specialty' "auth"
assert_json_field "name set to auth-server" "$MANIFEST" '.projectName' "auth-server"

# Test 5: Other fields not clobbered
assert_json_field "sessionId preserved" "$MANIFEST" '.sessionId' "$SESSION_ID"
assert_json_field "projectId preserved" "$MANIFEST" '.projectId' "test-proj"
assert_json_field "status preserved" "$MANIFEST" '.status' "active"

# Test 6: Fails on nonexistent session
if BRIDGE_DIR="$BRIDGE_DIR" bash "$UPDATE" "test-proj" "nosuch" --role orchestrator 2>/dev/null; then
  echo "  FAIL: should error on nonexistent session"; FAIL=$((FAIL + 1))
else
  echo "  PASS: errors on nonexistent session"; PASS=$((PASS + 1))
fi

# Test 7: Fails on nonexistent project
if BRIDGE_DIR="$BRIDGE_DIR" bash "$UPDATE" "no-proj" "$SESSION_ID" --role orchestrator 2>/dev/null; then
  echo "  FAIL: should error on nonexistent project"; FAIL=$((FAIL + 1))
else
  echo "  PASS: errors on nonexistent project"; PASS=$((PASS + 1))
fi

# Test 8: Fails with no flags
if BRIDGE_DIR="$BRIDGE_DIR" bash "$UPDATE" "test-proj" "$SESSION_ID" 2>/dev/null; then
  echo "  FAIL: should error with no flags"; FAIL=$((FAIL + 1))
else
  echo "  PASS: errors with no flags"; PASS=$((PASS + 1))
fi

print_results

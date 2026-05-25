#!/usr/bin/env bash
# tests/test-resume-session.sh — Tests for scripts/resume-session.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CREATE_PROJECT="$PLUGIN_DIR/scripts/project-create.sh"
JOIN="$PLUGIN_DIR/scripts/project-join.sh"
CLOSE="$PLUGIN_DIR/scripts/close-session.sh"
RESUME="$PLUGIN_DIR/scripts/resume-session.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_NAME="resume-test"
PROJECT_A="$TEST_TMPDIR/proj-a"
mkdir -p "$PROJECT_A/.claude"

BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$CREATE_PROJECT" "$PROJECT_NAME" >/dev/null
ORIGINAL_SID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$JOIN" "$PROJECT_NAME" --role specialist --name "resume-test")

echo "=== test-resume-session.sh ==="
echo "  original_sid=$ORIGINAL_SID"

# Cleanly close the session first
BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$CLOSE"
sleep 1

# --- Test 1: resume picks up existing session ID ---
echo ""
echo "Test 1: resume adopts existing session ID"
RESUMED_SID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$RESUME" 2>&1)
assert_eq "resumed SID matches original" "$ORIGINAL_SID" "$RESUMED_SID"

# --- Test 2: resume flips status back to active ---
echo ""
echo "Test 2: status flips offline → active on resume"
MANIFEST="$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$ORIGINAL_SID/manifest.json"
assert_json_field "status is active after resume" "$MANIFEST" ".status" "active"

# --- Test 3: heartbeat daemon is restarted ---
echo ""
echo "Test 3: heartbeat-daemon restarted on resume"
sleep 2
PID_FILE="$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$ORIGINAL_SID/heartbeat-daemon.pid"
assert_file_exists "heartbeat-daemon.pid exists after resume" "$PID_FILE"
HB_PID=$(cat "$PID_FILE")
if kill -0 "$HB_PID" 2>/dev/null; then
  echo "  PASS: heartbeat-daemon alive"; PASS=$((PASS + 1))
  kill "$HB_PID" 2>/dev/null || true
else
  echo "  FAIL: heartbeat-daemon not alive (PID=$HB_PID)"; FAIL=$((FAIL + 1))
fi

# --- Test 4: resume from stale → active also works ---
echo ""
echo "Test 4: resume from stale flips to active"
# Force stale by setting manifest status=stale
TMP=$(mktemp "$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$ORIGINAL_SID/manifest.XXXXXX")
jq '.status = "stale"' "$MANIFEST" > "$TMP" && mv "$TMP" "$MANIFEST"
RESUMED_SID2=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$RESUME" 2>&1)
assert_eq "stale resume yields original SID" "$ORIGINAL_SID" "$RESUMED_SID2"
assert_json_field "stale flipped to active" "$MANIFEST" ".status" "active"
# Kill the daemon spawned by this test step
sleep 2
NEW_HB_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
[ -n "$NEW_HB_PID" ] && kill "$NEW_HB_PID" 2>/dev/null || true

# --- Test 5: resume errors loudly if session dir is gone ---
echo ""
echo "Test 5: resume errors loudly when session was removed"
# Destroy the session dir to simulate /bridge remove
rm -rf "$BRIDGE_DIR/projects/$PROJECT_NAME/sessions/$ORIGINAL_SID"
# bridge-session pointer still says ORIGINAL_SID — but the dir is gone
OUT=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_A" bash "$RESUME" 2>&1 || true)
if echo "$OUT" | grep -q "no longer exists"; then
  echo "  PASS: emits loud error"; PASS=$((PASS + 1))
else
  echo "  FAIL: expected loud error about missing session"; FAIL=$((FAIL + 1))
  echo "    actual: $OUT"
fi
# AND should not silently mint a new ID
if echo "$OUT" | grep -qE '^[a-z0-9]{6}$'; then
  echo "  FAIL: silently minted new ID (forbidden)"; FAIL=$((FAIL + 1))
else
  echo "  PASS: did not silently mint new ID"; PASS=$((PASS + 1))
fi

print_results

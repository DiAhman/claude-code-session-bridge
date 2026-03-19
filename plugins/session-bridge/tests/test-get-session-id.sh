#!/usr/bin/env bash
# tests/test-get-session-id.sh — Tests for scripts/get-session-id.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$PLUGIN_DIR/scripts/register.sh"
GET_ID="$PLUGIN_DIR/scripts/get-session-id.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
PROJECT_DIR="$TEST_TMPDIR/my-project"
mkdir -p "$PROJECT_DIR"

echo "=== test-get-session-id.sh ==="

# Register a session
SESSION_ID=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_DIR" bash "$REGISTER")
echo "  registered: $SESSION_ID"

# --- Test 1: Finds session from project root ---
echo ""
echo "Test 1: Finds session from project root"
FOUND=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_DIR" bash "$GET_ID")
assert_eq "finds session from root" "$SESSION_ID" "$FOUND"

# --- Test 2: Finds session from subdirectory ---
echo ""
echo "Test 2: Finds session from a subdirectory of the project"
SUBDIR="$PROJECT_DIR/src/main/kotlin"
mkdir -p "$SUBDIR"
FOUND=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$SUBDIR" bash "$GET_ID")
assert_eq "finds session from subdirectory" "$SESSION_ID" "$FOUND"

# --- Test 3: Finds session from deep nested subdirectory ---
echo ""
echo "Test 3: Finds session from deeply nested subdirectory"
DEEP="$PROJECT_DIR/src/main/kotlin/com/example/feature/impl"
mkdir -p "$DEEP"
FOUND=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$DEEP" bash "$GET_ID")
assert_eq "finds from deep subdir" "$SESSION_ID" "$FOUND"

# --- Test 4: Does NOT find a different project's session ---
echo ""
echo "Test 4: Unrelated directory does not return a session"
UNRELATED="$TEST_TMPDIR/other-project/src"
mkdir -p "$UNRELATED"
if BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$UNRELATED" bash "$GET_ID" 2>/dev/null; then
  echo "  FAIL: found a session for unrelated directory"; FAIL=$((FAIL + 1))
else
  echo "  PASS: correctly returns nothing for unrelated directory"; PASS=$((PASS + 1))
fi

# --- Test 5: Sibling project does not leak ---
echo ""
echo "Test 5: Sibling project does not pick up neighbor's session"
SIBLING="$TEST_TMPDIR/my-project-2"
mkdir -p "$SIBLING"
if BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$SIBLING" bash "$GET_ID" 2>/dev/null; then
  echo "  FAIL: sibling project leaked session"; FAIL=$((FAIL + 1))
else
  echo "  PASS: sibling project correctly isolated"; PASS=$((PASS + 1))
fi

# --- Test 6: Two projects, each finds only their own ---
echo ""
echo "Test 6: Two registered projects find only their own sessions"
PROJECT_B="$TEST_TMPDIR/project-b"
mkdir -p "$PROJECT_B"
SESSION_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$REGISTER")

FOUND_A=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_DIR/src" bash "$GET_ID")
FOUND_B=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_B" bash "$GET_ID")

assert_eq "project A finds its own" "$SESSION_ID" "$FOUND_A"
assert_eq "project B finds its own" "$SESSION_B" "$FOUND_B"
if [ "$FOUND_A" != "$FOUND_B" ]; then
  echo "  PASS: sessions are distinct"; PASS=$((PASS + 1))
else
  echo "  FAIL: both returned same session"; FAIL=$((FAIL + 1))
fi

# --- Test 7: Prefers direct bridge-session file when in project root ---
echo ""
echo "Test 7: Fast path — uses bridge-session file directly when available"
FOUND=$(BRIDGE_DIR="$BRIDGE_DIR" PROJECT_DIR="$PROJECT_DIR" bash "$GET_ID")
assert_eq "fast path works" "$SESSION_ID" "$FOUND"

echo ""
echo "--- project-scoped get-session-id tests ---"

# Helper to kill all watcher processes in a bridge dir
kill_watchers() {
  local bridge="$1"
  for pidfile in "$bridge"/projects/*/sessions/*/watcher.pid; do
    [ -f "$pidfile" ] || continue
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
  done
}

V2_TMPDIR=$(mktemp -d)
V2_BRIDGE="$V2_TMPDIR/bridge"
V2_PROJ_DIR="$V2_TMPDIR/v2-app"
mkdir -p "$V2_PROJ_DIR"

BRIDGE_DIR="$V2_BRIDGE" bash "$PLUGIN_DIR/scripts/project-create.sh" "id-test-proj" > /dev/null
V2_SID=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_DIR" bash "$PLUGIN_DIR/scripts/project-join.sh" "id-test-proj" --role specialist)

# --- Test 8: Finds project-scoped session from project root ---
echo ""
echo "Test 8: Finds project-scoped session from project root"
FOUND=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_DIR" bash "$GET_ID")
assert_eq "finds project session from root" "$V2_SID" "$FOUND"

# --- Test 9: Finds project-scoped session from subdirectory ---
echo ""
echo "Test 9: Finds project-scoped session from subdirectory"
V2_SUBDIR="$V2_PROJ_DIR/src/lib"
mkdir -p "$V2_SUBDIR"
FOUND=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_SUBDIR" bash "$GET_ID")
assert_eq "finds project session from subdir" "$V2_SID" "$FOUND"

# --- Test 10: Unrelated directory does not find project session ---
echo ""
echo "Test 10: Unrelated directory does not find project-scoped session"
UNRELATED="$V2_TMPDIR/unrelated-dir"
mkdir -p "$UNRELATED"
if BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$UNRELATED" bash "$GET_ID" 2>/dev/null; then
  echo "  FAIL: found a session for unrelated directory"; FAIL=$((FAIL + 1))
else
  echo "  PASS: correctly returns nothing for unrelated directory"; PASS=$((PASS + 1))
fi

# --- Test 11: Fast path via bridge-session file works for project sessions ---
echo ""
echo "Test 11: Fast path works for project-scoped sessions"
# bridge-session file should have been created by project-join.sh
assert_file_exists "bridge-session exists" "$V2_PROJ_DIR/.claude/bridge-session"
FOUND=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_DIR" bash "$GET_ID")
assert_eq "fast path returns correct ID" "$V2_SID" "$FOUND"

# --- Test 12: Finds session via project scan even without bridge-session file ---
echo ""
echo "Test 12: Finds session via project-scoped scan without bridge-session file"
rm -f "$V2_PROJ_DIR/.claude/bridge-session"
FOUND=$(BRIDGE_DIR="$V2_BRIDGE" PROJECT_DIR="$V2_PROJ_DIR" bash "$GET_ID")
assert_eq "project scan finds session" "$V2_SID" "$FOUND"

kill_watchers "$V2_BRIDGE"
rm -rf "$V2_TMPDIR"

print_results

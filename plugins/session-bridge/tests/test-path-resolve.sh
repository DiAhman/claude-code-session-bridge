#!/usr/bin/env bash
# tests/test-path-resolve.sh — Tests for scripts/lib/path-resolve.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$PLUGIN_DIR/scripts/lib/path-resolve.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
export BRIDGE_DIR

echo "=== test-path-resolve.sh ==="

# shellcheck source=/dev/null
source "$LIB"

# --- Fixtures ---
setup_project_session "$BRIDGE_DIR" "alpha" "aaaaaa" "orchestrator" "lead" > /dev/null
setup_project_session "$BRIDGE_DIR" "alpha" "bbbbbb" "specialist" "worker" > /dev/null
setup_project_session "$BRIDGE_DIR" "beta"  "cccccc" "specialist" "other"  > /dev/null
# Legacy ad-hoc session (no projectId)
LEGACY_DIR="$BRIDGE_DIR/sessions/legacy"
mkdir -p "$LEGACY_DIR/inbox" "$LEGACY_DIR/outbox"
echo '{"sessionId":"legacy","status":"active"}' > "$LEGACY_DIR/manifest.json"

# --- Test 1: resolve_session_dir finds project-scoped session ---
echo ""
echo "Test 1: resolve_session_dir finds project-scoped session"
GOT=$(resolve_session_dir "aaaaaa")
EXPECT="$BRIDGE_DIR/projects/alpha/sessions/aaaaaa"
assert_eq "alpha/aaaaaa resolves" "$EXPECT" "$GOT"

# --- Test 2: resolve_session_dir finds session in second project ---
echo ""
echo "Test 2: resolve_session_dir finds session in second project"
GOT=$(resolve_session_dir "cccccc")
EXPECT="$BRIDGE_DIR/projects/beta/sessions/cccccc"
assert_eq "beta/cccccc resolves" "$EXPECT" "$GOT"

# --- Test 3: resolve_session_dir falls back to legacy ---
echo ""
echo "Test 3: resolve_session_dir falls back to legacy sessions/"
GOT=$(resolve_session_dir "legacy")
EXPECT="$BRIDGE_DIR/sessions/legacy"
assert_eq "legacy resolves" "$EXPECT" "$GOT"

# --- Test 4: resolve_session_dir empty for unknown ID ---
echo ""
echo "Test 4: resolve_session_dir empty for unknown ID"
GOT=$(resolve_session_dir "zzzzzz")
assert_eq "unknown is empty" "" "$GOT"

# --- Test 5: resolve_session_dir empty for empty arg ---
echo ""
echo "Test 5: resolve_session_dir empty for empty arg"
GOT=$(resolve_session_dir "")
assert_eq "empty arg is empty" "" "$GOT"

# --- Test 6: resolve_inbox composes from resolve_session_dir ---
echo ""
echo "Test 6: resolve_inbox returns <session-dir>/inbox"
GOT=$(resolve_inbox "bbbbbb")
EXPECT="$BRIDGE_DIR/projects/alpha/sessions/bbbbbb/inbox"
assert_eq "bbbbbb inbox" "$EXPECT" "$GOT"
GOT=$(resolve_inbox "zzzzzz")
assert_eq "unknown inbox is empty" "" "$GOT"

# --- Test 7: resolve_outbox composes from resolve_session_dir ---
echo ""
echo "Test 7: resolve_outbox returns <session-dir>/outbox"
GOT=$(resolve_outbox "bbbbbb")
EXPECT="$BRIDGE_DIR/projects/alpha/sessions/bbbbbb/outbox"
assert_eq "bbbbbb outbox" "$EXPECT" "$GOT"

# --- Test 8: resolve_project_id from manifest ---
echo ""
echo "Test 8: resolve_project_id from manifest"
GOT=$(resolve_project_id "aaaaaa")
assert_eq "aaaaaa → alpha" "alpha" "$GOT"
GOT=$(resolve_project_id "cccccc")
assert_eq "cccccc → beta" "beta" "$GOT"

# --- Test 9: resolve_project_id empty for legacy session ---
echo ""
echo "Test 9: resolve_project_id empty for legacy"
GOT=$(resolve_project_id "legacy")
assert_eq "legacy → empty" "" "$GOT"

# --- Test 10: resolve_project_id empty for unknown ---
echo ""
echo "Test 10: resolve_project_id empty for unknown"
GOT=$(resolve_project_id "zzzzzz")
assert_eq "unknown → empty" "" "$GOT"

# --- Test 11: assert_same_project succeeds for same project ---
echo ""
echo "Test 11: assert_same_project succeeds for same project"
if assert_same_project "aaaaaa" "bbbbbb" 2>/dev/null; then
  echo "  PASS: aaaaaa and bbbbbb in alpha"; PASS=$((PASS + 1))
else
  echo "  FAIL: same-project pair rejected"; FAIL=$((FAIL + 1))
fi

# --- Test 12: assert_same_project fails across projects ---
echo ""
echo "Test 12: assert_same_project fails for cross-project pair"
if assert_same_project "aaaaaa" "cccccc" 2>/dev/null; then
  echo "  FAIL: cross-project pair accepted"; FAIL=$((FAIL + 1))
else
  echo "  PASS: aaaaaa (alpha) vs cccccc (beta) rejected"; PASS=$((PASS + 1))
fi

# --- Test 13: assert_same_project fails when one side is legacy/missing ---
echo ""
echo "Test 13: assert_same_project fails when project-id is empty"
if assert_same_project "aaaaaa" "legacy" 2>/dev/null; then
  echo "  FAIL: legacy pair accepted"; FAIL=$((FAIL + 1))
else
  echo "  PASS: legacy pair rejected"; PASS=$((PASS + 1))
fi
if assert_same_project "aaaaaa" "zzzzzz" 2>/dev/null; then
  echo "  FAIL: unknown target accepted"; FAIL=$((FAIL + 1))
else
  echo "  PASS: unknown target rejected"; PASS=$((PASS + 1))
fi

print_results

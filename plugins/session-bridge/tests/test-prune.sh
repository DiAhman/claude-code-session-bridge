#!/usr/bin/env bash
# tests/test-prune.sh — Tests for scripts/prune.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PRUNE="$PLUGIN_DIR/scripts/prune.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

BRIDGE_DIR="$TEST_TMPDIR/bridge"
mkdir -p "$BRIDGE_DIR/projects/p1/sessions/s1/inbox/.delivered"
mkdir -p "$BRIDGE_DIR/projects/p1/sessions/s1/outbox"

echo "=== test-prune.sh ==="

# --- Test 1: --delivered N prunes files older than N days ---
echo ""
echo "Test 1: --delivered 7 prunes archive files older than 7 days"
OLD_FILE="$BRIDGE_DIR/projects/p1/sessions/s1/inbox/.delivered/msg-old.json"
echo '{}' > "$OLD_FILE"
touch -d "10 days ago" "$OLD_FILE" 2>/dev/null || touch -A -8640000 "$OLD_FILE" 2>/dev/null || true
FRESH_FILE="$BRIDGE_DIR/projects/p1/sessions/s1/inbox/.delivered/msg-fresh.json"
echo '{}' > "$FRESH_FILE"

BRIDGE_DIR="$BRIDGE_DIR" bash "$PRUNE" --delivered 7

if [ -f "$OLD_FILE" ]; then
  echo "  FAIL: old archive file not pruned"; FAIL=$((FAIL + 1))
else
  echo "  PASS: old archive pruned"; PASS=$((PASS + 1))
fi
assert_file_exists "fresh archive retained" "$FRESH_FILE"

# --- Test 2: --outbox N prunes outbox files older than N days ---
echo ""
echo "Test 2: --outbox 7 prunes outbox files older than 7 days"
OLD_OUT="$BRIDGE_DIR/projects/p1/sessions/s1/outbox/msg-old.json"
echo '{"timestamp":"2025-01-01T00:00:00Z"}' > "$OLD_OUT"
touch -d "10 days ago" "$OLD_OUT" 2>/dev/null || touch -A -8640000 "$OLD_OUT" 2>/dev/null || true
FRESH_OUT="$BRIDGE_DIR/projects/p1/sessions/s1/outbox/msg-fresh.json"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "{\"timestamp\":\"$NOW\"}" > "$FRESH_OUT"

BRIDGE_DIR="$BRIDGE_DIR" bash "$PRUNE" --outbox 7

if [ -f "$OLD_OUT" ]; then
  echo "  FAIL: old outbox file not pruned"; FAIL=$((FAIL + 1))
else
  echo "  PASS: old outbox pruned"; PASS=$((PASS + 1))
fi
assert_file_exists "fresh outbox retained" "$FRESH_OUT"

# --- Test 3: --dry-run prints what would be pruned, doesn't delete ---
echo ""
echo "Test 3: dry-run mode lists targets without deleting"
mkdir -p "$BRIDGE_DIR/projects/p1/sessions/s1/inbox/.delivered"
DRY_FILE="$BRIDGE_DIR/projects/p1/sessions/s1/inbox/.delivered/msg-dry.json"
echo '{}' > "$DRY_FILE"
touch -d "30 days ago" "$DRY_FILE" 2>/dev/null || touch -A -25920000 "$DRY_FILE" 2>/dev/null || true

OUT=$(BRIDGE_DIR="$BRIDGE_DIR" bash "$PRUNE" --delivered 7 --dry-run 2>&1)
assert_file_exists "dry-run did not delete" "$DRY_FILE"
assert_contains "dry-run output mentions msg-dry" "msg-dry" "$OUT"

print_results

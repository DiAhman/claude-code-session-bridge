#!/usr/bin/env bash
# tests/test-stale-check.sh — Tests for scripts/lib/stale-check.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$PLUGIN_DIR/scripts/lib/stale-check.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

echo "=== test-stale-check.sh ==="

# Source the lib for testing
# shellcheck source=/dev/null
source "$LIB"

# --- Test 1: get_heartbeat_age returns seconds since file content timestamp ---
echo ""
echo "Test 1: get_heartbeat_age returns age in seconds"
HB_FILE="$TEST_TMPDIR/heartbeat"
TS_120S_AGO=$(date -u -d "120 seconds ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-120S +"%Y-%m-%dT%H:%M:%SZ")
echo "$TS_120S_AGO" > "$HB_FILE"
AGE=$(get_heartbeat_age "$HB_FILE")
# Age should be ~120 (allow ±5s slack for test runtime)
if [ "$AGE" -ge 115 ] && [ "$AGE" -le 130 ]; then
  echo "  PASS: heartbeat age ~120s (got $AGE)"; PASS=$((PASS + 1))
else
  echo "  FAIL: heartbeat age expected ~120, got $AGE"; FAIL=$((FAIL + 1))
fi

# --- Test 2: get_heartbeat_age returns 99999999 when file missing ---
echo ""
echo "Test 2: get_heartbeat_age returns sentinel when file missing"
MISSING_AGE=$(get_heartbeat_age "$TEST_TMPDIR/does-not-exist")
assert_eq "missing file → sentinel" "99999999" "$MISSING_AGE"

# --- Test 3: is_producer_alive returns 0 for $$ (this script process) ---
echo ""
echo "Test 3: is_producer_alive returns true for live PID"
# Self-PID is alive but won't pass the cmdline check (we're a test script, not heartbeat-daemon)
# So this should return 1 (false) — defensive cmdline guard
if is_producer_alive "$$"; then
  echo "  FAIL: self-pid passed cmdline guard (should reject)"; FAIL=$((FAIL + 1))
else
  echo "  PASS: cmdline guard rejects non-daemon PID"; PASS=$((PASS + 1))
fi

# --- Test 4: is_producer_alive returns 1 for dead PID ---
echo ""
echo "Test 4: is_producer_alive returns false for dead PID"
# Spawn-and-kill a short-lived process to get a guaranteed-dead PID
sleep 0 &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
if is_producer_alive "$DEAD_PID"; then
  echo "  FAIL: dead PID reported alive"; FAIL=$((FAIL + 1))
else
  echo "  PASS: dead PID reported dead"; PASS=$((PASS + 1))
fi

# --- Test 5: is_producer_alive returns 1 for empty PID ---
echo ""
echo "Test 5: is_producer_alive returns false for empty PID"
if is_producer_alive ""; then
  echo "  FAIL: empty PID reported alive"; FAIL=$((FAIL + 1))
else
  echo "  PASS: empty PID reported dead"; PASS=$((PASS + 1))
fi

# --- Test 6: is_stale returns false when status=offline ---
echo ""
echo "Test 6: is_stale returns false when status=offline"
SESSION_DIR="$TEST_TMPDIR/session1"
mkdir -p "$SESSION_DIR"
echo '{"sessionId":"abc123","status":"offline"}' > "$SESSION_DIR/manifest.json"
TS_OLD=$(date -u -d "1 hour ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-1H +"%Y-%m-%dT%H:%M:%SZ")
echo "$TS_OLD" > "$SESSION_DIR/heartbeat"
if is_stale "$SESSION_DIR" 300; then
  echo "  FAIL: offline session reported stale"; FAIL=$((FAIL + 1))
else
  echo "  PASS: offline session not stale"; PASS=$((PASS + 1))
fi

# --- Test 7: is_stale returns true when status=active + heartbeat old + no daemon PID file ---
echo ""
echo "Test 7: is_stale returns true when status=active, heartbeat old, no daemon"
SESSION_DIR="$TEST_TMPDIR/session2"
mkdir -p "$SESSION_DIR"
echo '{"sessionId":"def456","status":"active"}' > "$SESSION_DIR/manifest.json"
echo "$TS_OLD" > "$SESSION_DIR/heartbeat"
# No watcher.pid file — daemon presumed dead
if is_stale "$SESSION_DIR" 300; then
  echo "  PASS: stale session correctly detected"; PASS=$((PASS + 1))
else
  echo "  FAIL: stale session not detected"; FAIL=$((FAIL + 1))
fi

# --- Test 8: is_stale returns false when status=active + heartbeat fresh ---
echo ""
echo "Test 8: is_stale returns false when heartbeat is fresh"
SESSION_DIR="$TEST_TMPDIR/session3"
mkdir -p "$SESSION_DIR"
echo '{"sessionId":"ghi789","status":"active"}' > "$SESSION_DIR/manifest.json"
TS_NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "$TS_NOW" > "$SESSION_DIR/heartbeat"
if is_stale "$SESSION_DIR" 300; then
  echo "  FAIL: fresh heartbeat reported stale"; FAIL=$((FAIL + 1))
else
  echo "  PASS: fresh heartbeat not stale"; PASS=$((PASS + 1))
fi

# --- Test 9: set_status writes new status field atomically ---
echo ""
echo "Test 9: set_status writes new status to manifest"
SESSION_DIR="$TEST_TMPDIR/session4"
mkdir -p "$SESSION_DIR"
echo '{"sessionId":"jkl012","status":"active","other":"keep"}' > "$SESSION_DIR/manifest.json"
set_status "$SESSION_DIR/manifest.json" "stale"
assert_json_field "status flipped to stale" "$SESSION_DIR/manifest.json" ".status" "stale"
assert_json_field "other field preserved" "$SESSION_DIR/manifest.json" ".other" "keep"

# --- Test 10: write_heartbeat writes ISO 8601 UTC timestamp atomically ---
echo ""
echo "Test 10: write_heartbeat writes current ISO 8601 timestamp"
SESSION_DIR="$TEST_TMPDIR/session-wh1"
mkdir -p "$SESSION_DIR"
write_heartbeat "$SESSION_DIR"
assert_file_exists "heartbeat file created" "$SESSION_DIR/heartbeat"
WH_CONTENT=$(cat "$SESSION_DIR/heartbeat")
assert_contains "heartbeat contains T separator" "T" "$WH_CONTENT"
assert_contains "heartbeat ends with Z" "Z" "$WH_CONTENT"
# Verify no trailing newline (canonical interface requires it)
WH_BYTES=$(wc -c < "$SESSION_DIR/heartbeat" | tr -d ' ')
assert_eq "heartbeat is exactly 20 bytes (YYYY-MM-DDTHH:MM:SSZ, no newline)" "20" "$WH_BYTES"
# Verify no stray mktemp temp files left behind
STRAY_COUNT=$(find "$SESSION_DIR" -maxdepth 1 -name 'heartbeat.*' | wc -l | tr -d ' ')
assert_eq "no leftover heartbeat.XXXXXX temp files" "0" "$STRAY_COUNT"

# --- Test 11: write_heartbeat overwrites existing heartbeat ---
echo ""
echo "Test 11: write_heartbeat overwrites prior contents"
SESSION_DIR="$TEST_TMPDIR/session-wh2"
mkdir -p "$SESSION_DIR"
echo "STALE-CONTENT" > "$SESSION_DIR/heartbeat"
write_heartbeat "$SESSION_DIR"
NEW=$(cat "$SESSION_DIR/heartbeat")
if [ "$NEW" = "STALE-CONTENT" ]; then
  echo "  FAIL: write_heartbeat did not overwrite"; FAIL=$((FAIL + 1))
else
  echo "  PASS: write_heartbeat overwrote prior contents"; PASS=$((PASS + 1))
fi

# --- Test 12: write_heartbeat is monotonic under 10 concurrent writers (C10) ---
echo ""
echo "Test 12: write_heartbeat heartbeat is valid and non-decreasing across concurrent writes"
SESSION_DIR="$TEST_TMPDIR/session-wh3"
mkdir -p "$SESSION_DIR"
# Seed with a known-old timestamp so we can prove the final value moved forward,
# never backward, even though 10 writers race to mv into place concurrently.
TS_FLOOR=$(date -u -d "1 hour ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-1H +"%Y-%m-%dT%H:%M:%SZ")
printf '%s' "$TS_FLOOR" > "$SESSION_DIR/heartbeat"
START_EPOCH=$(date -u +%s)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  ( write_heartbeat "$SESSION_DIR" ) &
done
wait
END_EPOCH=$(date -u +%s)
FINAL_CONTENT=$(cat "$SESSION_DIR/heartbeat")
# Valid: matches exact ISO 8601 UTC format, no partial/corrupted write from the race
if echo "$FINAL_CONTENT" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
  echo "  PASS: heartbeat is well-formed after concurrent writes ($FINAL_CONTENT)"; PASS=$((PASS + 1))
else
  echo "  FAIL: heartbeat is malformed after concurrent writes (got '$FINAL_CONTENT')"; FAIL=$((FAIL + 1))
fi
FINAL_EPOCH=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$FINAL_CONTENT" +%s 2>/dev/null \
  || date -u -d "$FINAL_CONTENT" +%s 2>/dev/null || echo 0)
# Non-decreasing: whichever writer's mv wins the race, the result must land
# at-or-after the moment we started (never regress to the seeded floor or earlier)
# and at-or-before the moment the last writer finished (never a bogus future value).
if [ "$FINAL_EPOCH" -ge "$START_EPOCH" ] && [ "$FINAL_EPOCH" -le "$END_EPOCH" ]; then
  echo "  PASS: winning timestamp is bounded within [$START_EPOCH, $END_EPOCH] (never decreasing)"; PASS=$((PASS + 1))
else
  echo "  FAIL: winning timestamp $FINAL_EPOCH out of bounds [$START_EPOCH, $END_EPOCH]"; FAIL=$((FAIL + 1))
fi
STRAY_COUNT=$(find "$SESSION_DIR" -maxdepth 1 -name 'heartbeat.*' | wc -l | tr -d ' ')
assert_eq "no leftover heartbeat.XXXXXX temp files after concurrent writes" "0" "$STRAY_COUNT"
HB_FILE_COUNT=$(find "$SESSION_DIR" -maxdepth 1 -name 'heartbeat' | wc -l | tr -d ' ')
assert_eq "exactly one heartbeat file after concurrent writes" "1" "$HB_FILE_COUNT"

# --- Test 13: set_lifecycle flips field, preserves others ---
echo ""
echo "Test 13: set_lifecycle flips .lifecycle, preserves other fields"
SESSION_DIR="$TEST_TMPDIR/session-sl1"
mkdir -p "$SESSION_DIR"
cat > "$SESSION_DIR/manifest.json" <<'JSON'
{"sessionId":"slc001","status":"active","lifecycle":"normal","role":"specialist","projectName":"proj"}
JSON
set_lifecycle "$SESSION_DIR/manifest.json" "compacting"
assert_json_field "lifecycle flipped to compacting" "$SESSION_DIR/manifest.json" ".lifecycle" "compacting"
assert_json_field "status preserved" "$SESSION_DIR/manifest.json" ".status" "active"
assert_json_field "sessionId preserved" "$SESSION_DIR/manifest.json" ".sessionId" "slc001"
assert_json_field "role preserved" "$SESSION_DIR/manifest.json" ".role" "specialist"
assert_json_field "projectName preserved" "$SESSION_DIR/manifest.json" ".projectName" "proj"

# --- Test 14: set_lifecycle flips back to normal ---
echo ""
echo "Test 14: set_lifecycle flips compacting → normal"
set_lifecycle "$SESSION_DIR/manifest.json" "normal"
assert_json_field "lifecycle flipped back to normal" "$SESSION_DIR/manifest.json" ".lifecycle" "normal"

# --- Test 15: set_lifecycle returns nonzero when manifest missing ---
echo ""
echo "Test 15: set_lifecycle returns nonzero for missing manifest"
if set_lifecycle "$TEST_TMPDIR/does-not-exist.json" "compacting" 2>/dev/null; then
  echo "  FAIL: set_lifecycle returned 0 for missing manifest"; FAIL=$((FAIL + 1))
else
  echo "  PASS: set_lifecycle returned nonzero for missing manifest"; PASS=$((PASS + 1))
fi

print_results

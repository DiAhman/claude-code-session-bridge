#!/usr/bin/env bash
# tests/test-helpers.sh — Shared test assertion functions
PASS=0; FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"; echo "    expected: $expected"; echo "    actual:   $actual"; FAIL=$((FAIL + 1))
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  if [ -f "$path" ]; then
    echo "  PASS: $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (file not found: $path)"; FAIL=$((FAIL + 1))
  fi
}

assert_dir_exists() {
  local desc="$1" path="$2"
  if [ -d "$path" ]; then
    echo "  PASS: $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (dir not found: $path)"; FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q -- "$needle"; then
    echo "  PASS: $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (looking for '$needle')"; FAIL=$((FAIL + 1))
  fi
}

assert_json_field() {
  local desc="$1" file="$2" field="$3" expected="$4"
  if [ ! -f "$file" ]; then
    echo "  FAIL: $desc (file not found: $file)"; FAIL=$((FAIL + 1)); return
  fi
  local actual
  actual=$(jq -r "$field" "$file" 2>/dev/null)
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"; echo "    expected: $expected"; echo "    actual:   $actual"; FAIL=$((FAIL + 1))
  fi
}

assert_not_empty() {
  local desc="$1" value="$2"
  if [ -n "$value" ]; then
    echo "  PASS: $desc"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (value is empty)"; FAIL=$((FAIL + 1))
  fi
}

print_results() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ] || exit 1
}

# setup_project_session — fabricate a project-scoped session for tests.
# Usage: setup_project_session <bridge-dir> <project-name> <session-id> [role] [name]
# Echoes absolute session-dir on stdout. Returns nonzero on failure.
setup_project_session() {
  local BD="$1" PROJ="$2" SID="$3"
  local ROLE="${4:-specialist}" NAME="${5:-$3}"
  local SDIR="$BD/projects/$PROJ/sessions/$SID"
  mkdir -p "$SDIR/inbox" "$SDIR/outbox" "$BD/projects/$PROJ/conversations" || return 1
  local NOW
  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local TMP
  TMP=$(mktemp "$SDIR/manifest.XXXXXX") || return 1
  jq -n \
    --arg sid "$SID" \
    --arg pid "$PROJ" \
    --arg pname "$PROJ" \
    --arg name "$NAME" \
    --arg role "$ROLE" \
    --arg now "$NOW" \
    '{
      sessionId: $sid,
      projectId: $pid,
      projectName: $pname,
      role: $role,
      name: $name,
      status: "active",
      lifecycle: "normal",
      startedAt: $now,
      lastHeartbeat: $now
    }' > "$TMP" \
    && mv "$TMP" "$SDIR/manifest.json" \
    || { rm -f "$TMP"; return 1; }
  printf '%s' "$NOW" > "$SDIR/heartbeat" || return 1
  printf '%s' "0" > "$SDIR/heartbeat-daemon.pid" || return 1
  echo "$SDIR"
}

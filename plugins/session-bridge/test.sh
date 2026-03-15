#!/usr/bin/env bash
# test.sh — Run the full claude-bridge test suite
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PASS_TOTAL=0
FAIL_TOTAL=0
FAILED_TESTS=()

for t in tests/test-*.sh; do
  [ "$(basename "$t")" = "test-helpers.sh" ] && continue

  OUTPUT=$(bash "$t" 2>&1)
  PASS=$(echo "$OUTPUT" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' || echo 0)
  FAIL=$(echo "$OUTPUT" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' || echo 0)
  PASS_TOTAL=$((PASS_TOTAL + PASS))
  FAIL_TOTAL=$((FAIL_TOTAL + FAIL))

  if [ "$FAIL" -gt 0 ]; then
    echo "✘ $(basename "$t") — $PASS passed, $FAIL failed"
    echo "$OUTPUT" | grep "  FAIL:" | sed 's/^/    /'
    FAILED_TESTS+=("$(basename "$t")")
  else
    echo "✔ $(basename "$t") — $PASS passed"
  fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Total: $PASS_TOTAL passed, $FAIL_TOTAL failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$FAIL_TOTAL" -gt 0 ]; then
  echo ""
  echo "Failed tests: ${FAILED_TESTS[*]}"
  exit 1
fi

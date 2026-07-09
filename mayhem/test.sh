#!/usr/bin/env bash
#
# yoga/mayhem/test.sh — RUN yoga's own GTest unit-test suite (built by mayhem/build.sh at
# tests/build/yogatests) and report CTRF counts. The suite asserts computed layout values
# (golden expected sizes/positions per flexbox case), so a neutered/no-op yogacore fails it.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

RUNNER="$SRC/tests/build/yogatests"
if [ ! -x "$RUNNER" ]; then
  echo "FATAL: $RUNNER missing — mayhem/build.sh should have built it (do not rebuild here)" >&2
  emit_ctrf "gtest" 0 1
  exit 1
fi

LOG="$(mktemp)"
"$RUNNER" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# gtest summary: "[==========] N tests from M test suites ran." / "[  PASSED  ] P tests."
# "[  FAILED  ] F tests, listed below:" / "[  SKIPPED ] S tests, listed below:"
total="$(grep -oE '^\[==========\] [0-9]+ tests? from' "$LOG" | grep -oE '[0-9]+' | head -1 || true)"
passed="$(grep -oE '^\[  PASSED  \] [0-9]+' "$LOG" | grep -oE '[0-9]+' | tail -1 || true)"
failedn="$(grep -oE '^\[  FAILED  \] [0-9]+ tests?,' "$LOG" | grep -oE '^\[  FAILED  \] [0-9]+' | grep -oE '[0-9]+' | tail -1 || true)"
skipped="$(grep -oE '^\[  SKIPPED \] [0-9]+ tests?' "$LOG" | grep -oE '[0-9]+' | head -1 || true)"
rm -f "$LOG"
passed="${passed:-0}"; failedn="${failedn:-0}"; skipped="${skipped:-0}"; total="${total:-0}"

# Honest oracle: a runner that produced no parseable summary, ran zero tests, or exited
# non-zero without reporting failures counts as FAILED.
if [ "$total" -eq 0 ] || { [ "$rc" -ne 0 ] && [ "$failedn" -eq 0 ]; }; then
  echo "FATAL: yogatests produced no valid GTest summary (rc=$rc, total=$total)" >&2
  emit_ctrf "gtest" "$passed" 1 "$skipped"
  exit 1
fi

emit_ctrf "gtest" "$passed" "$failedn" "$skipped"

#!/usr/bin/env bash
#
# yoga/mayhem/build.sh — build yoga's OSS-Fuzz harness (fuzz_layout) as a sanitized libFuzzer
# target (+ a standalone reproducer), AND yoga's own CMake/GTest unit-test suite for mayhem/test.sh.
#
# yoga is Meta's flexbox layout engine. The single OSS-Fuzz harness (fuzz/FuzzLayout.cpp) drives
# YGNodeCalculateLayout over an FDP-generated node tree. We build libyogacore.a with
# $SANITIZER_FLAGS (ASan+UBSan, halting) so the layout engine itself is instrumented, then link
# the harness against it manually (instead of the cmake fuzz_layout target) so we can also bake in
# a STRONG __asan_default_options (detect_leaks=0 — a weak symbol loses to the ASan runtime default
# and LSan then aborts under Mayhem's tracer).
#
# NOTE (mirrors upstream OSS-Fuzz projects/yoga/build.sh): do NOT pass CMAKE_BUILD_TYPE=Release —
# yoga's cmake/project-defaults.cmake enables -ffunction-sections/-fdata-sections + --gc-sections
# only for Release, which strips fuzzer init sections.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# Ensure the compiled TUs (library AND harness) carry SanitizerCoverage call sites so Mayhem can
# observe edges; skip when SANITIZER_FLAGS is empty (the "no sanitizers" override).
if [ -n "${SANITIZER_FLAGS}" ] && ! echo "${SANITIZER_FLAGS}" | grep -q 'fuzzer'; then
  SANITIZER_FLAGS="${SANITIZER_FLAGS} -fsanitize=fuzzer-no-link"
fi
# DWARF must be < 4 (Mayhem triage can't read >=4); clang-19's plain -g emits DWARF-5.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${OUT:=/mayhem}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE OUT MAYHEM_JOBS

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SRC"
export SRC

# Selectively relax UBSan's float-cast-overflow ONLY: yoga's StyleValuePool.h intentionally does
# static_cast<int32_t>(float) on arbitrary style values (isIntegerPackable/packInlineInteger), so
# ANY fuzzed float halts on the very first input — the check floods on a benign upstream pattern.
# ASan and every other UBSan check remain enabled and halting.
if [ -n "${SANITIZER_FLAGS}" ] && echo "${SANITIZER_FLAGS}" | grep -q 'undefined'; then
  SANITIZER_FLAGS="${SANITIZER_FLAGS} -fno-sanitize=float-cast-overflow"
fi

FUZZ_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"

# ── 1) Build libyogacore.a with sanitizers (the fuzzed code itself is instrumented) ──────────────
cmake -B build-fuzz -S . -G Ninja \
      -D CMAKE_C_COMPILER="$CC" -D CMAKE_CXX_COMPILER="$CXX" \
      -D CMAKE_C_FLAGS="$FUZZ_FLAGS" -D CMAKE_CXX_FLAGS="$FUZZ_FLAGS"
cmake --build build-fuzz --target yogacore -j"$MAYHEM_JOBS"
YOGACORE="$SRC/build-fuzz/yoga/libyogacore.a"

# ── 2) Link the harness twice: libFuzzer target + standalone (run-once) reproducer ───────────────
# Strong __asan_default_options (detect_leaks=0) baked into both binaries.
$CC  $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/asan_options.c -o build-fuzz/asan_options.o
$CC  $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build-fuzz/standalone_main.o

$CXX $FUZZ_FLAGS $LIB_FUZZING_ENGINE -std=c++20 -fexceptions -I"$SRC" \
     fuzz/FuzzLayout.cpp build-fuzz/asan_options.o "$YOGACORE" -o "$OUT/fuzz_layout"
$CXX $FUZZ_FLAGS -std=c++20 -fexceptions -I"$SRC" \
     fuzz/FuzzLayout.cpp build-fuzz/standalone_main.o build-fuzz/asan_options.o "$YOGACORE" \
     -o "$OUT/fuzz_layout-standalone"
echo "built fuzz_layout (+ standalone)"

# ── 3) Build yoga's OWN GTest unit-test suite with NORMAL flags (clean, independent build) so ────
#      mayhem/test.sh only RUNS it (mirrors upstream unit_tests: cmake on tests/, target yogatests).
#      GTest comes via FetchContent (downloaded at image-build time; the populated _deps cache makes
#      the offline build.sh re-run work without network).
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake -B tests/build -S tests -D CMAKE_BUILD_TYPE=Debug -G Ninja \
        -D CMAKE_C_FLAGS="$COVERAGE_FLAGS" -D CMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake --build tests/build -j"$MAYHEM_JOBS"
echo "built yoga GTest suite: tests/build/yogatests"

echo "build.sh complete:"
ls -la "$OUT/fuzz_layout" "$OUT/fuzz_layout-standalone" "$SRC/tests/build/yogatests"

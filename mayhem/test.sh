#!/usr/bin/env bash
#
# mayhem/test.sh — RUN MRPT's own GoogleTest-based unit test suite for the module closure built
# by mayhem/build.sh's TEST pass (normal flags, BUILD_TESTING=ON): mrpt_common, mrpt_core,
# mrpt_typemeta, mrpt_containers, mrpt_system, mrpt_expr, mrpt_config. Does NOT compile anything.
#
# BEHAVIORAL, not exit-code-only: each module's compiled test binary (mrpt_add_test's
# `test_<module>`, e.g. tests/CConfigFile_unittest.cpp, string_utils_unittest.cpp,
# config_parser_unittest.cpp, ...) runs real GoogleTest assertions (parsed config values, YAML
# round-trips, CRC/base64/md5 known-answer checks, ...). We deliberately do NOT use ctest's own
# pass/fail verdict here and instead run each test binary directly and parse GoogleTest's OWN
# "[==========] N tests ... ran" / "[  PASSED  ] P tests." / "[  FAILED  ] F tests" summary text:
# ctest's pass criterion is just "did the subprocess exit 0", so a binary that's neutered to
# _exit(0) before main() runs (the sabotage check's LD_PRELOAD constructor) would look like a
# 100%-passing ctest run despite executing ZERO real assertions -- exactly the exit-code-only
# reward hack this oracle must not be. Requiring GoogleTest's own summary text closes that hole:
# a neutered binary prints none of it, which this script treats as a failure, not a silent pass.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]  (see mayhem-repo-integration template)
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

TEST_BUILD="$SRC/mayhem/_build/build-test"
# mrpt_common is an INTERFACE-only meta-package (no LIB_SOURCES/UNIT_TEST_SOURCES, no
# mrpt_add_test() call) -- it never produces a test_mrpt_common binary, by design.
MRPT_MODULES=(mrpt_core mrpt_typemeta mrpt_containers mrpt_system mrpt_expr mrpt_config)

if [ ! -d "$TEST_BUILD" ]; then
  echo "test.sh: $TEST_BUILD is missing -- mayhem/build.sh has not built the TEST pass" >&2
  emit_ctrf "gtest" 0 1
  exit 1
fi

total_passed=0
total_failed=0
saw_real_output=0

for mod in "${MRPT_MODULES[@]}"; do
  bin="$(find "$TEST_BUILD/$mod" -maxdepth 4 -type f -name "test_${mod}" 2>/dev/null | head -n1)"
  if [ -z "$bin" ]; then
    echo "test.sh: no test_${mod} binary under $TEST_BUILD/$mod -- build.sh should have produced one" >&2
    total_failed=$((total_failed + 1))
    continue
  fi
  out="$("$bin" 2>&1)" || true
  if printf '%s\n' "$out" | grep -qE '^\[==========\] [0-9]+ tests? from [0-9]+ test suites? ran\.'; then
    saw_real_output=1
    p="$(printf '%s\n' "$out" | grep -oE '^\[  PASSED  \] [0-9]+ tests?' | grep -oE '[0-9]+' | head -n1)"
    f="$(printf '%s\n' "$out" | grep -oE '^\[  FAILED  \] [0-9]+ tests?,?' | grep -oE '[0-9]+' | head -n1)"
    total_passed=$((total_passed + ${p:-0}))
    total_failed=$((total_failed + ${f:-0}))
  else
    echo "test.sh: $bin produced no GoogleTest summary -- treating as failed (neutered/crashed before running?)" >&2
    total_failed=$((total_failed + 1))
  fi
done

if [ "$saw_real_output" -ne 1 ]; then
  echo "test.sh: NO module test binary ever produced real GoogleTest output" >&2
fi

emit_ctrf "gtest" "$total_passed" "$total_failed"

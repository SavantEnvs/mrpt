#!/usr/bin/env bash
#
# mayhem/build.sh — build the Mayhem fuzz harnesses for MRPT 3.x (mrpt-ini2yaml, trim).
#
# MRPT 3.x is a colcon-style modular project: every mrpt_* library under modules/ is its own
# standalone CMake project (find_package(mrpt_<dep> REQUIRED) + mrpt_add_library()). Rather than
# configuring the whole (huge, GUI/OpenCV/wx-heavy) tree, we build only the closure the two
# harnesses actually touch:
#
#   mrpt_common -> mrpt_core -> mrpt_typemeta -> mrpt_containers -> mrpt_system -> mrpt_expr -> mrpt_config
#
# each installed into a shared prefix so downstream modules' find_package() resolves the ones
# already built. Two independent passes:
#   SAN pass  (this file, step 2): $SANITIZER_FLAGS + $DEBUG_FLAGS, static libs -> the harnesses.
#   TEST pass (step 3): normal flags + BUILD_TESTING=ON + the project's own GoogleTest-based unit
#                        tests -> what mayhem/test.sh runs via ctest.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into the harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF must stay < 4)
#   STANDALONE_FUZZ_MAIN path to the non-fuzzer run-once driver
#   SRC                 /mayhem (the repo source)
#
# Air-gapped/re-runnable: the three git submodules needed by the closure above (googletest, for
# the unit tests; simpleini and libfyaml, MRPT's two bundled 3rd-party deps for mrpt_config /
# mrpt_containers) are fetched by mayhem/Dockerfile with network access BEFORE this script runs
# (baked into the image), so this script itself never touches the network and can be re-run
# offline. All build/install trees below live under $SRC/mayhem/_build so a re-run is idempotent
# (existing CMake caches are reused/reconfigured, not recreated from scratch).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# Ordered per mrpt_common's find_package() chain (see header comment).
MRPT_MODULES=(mrpt_common mrpt_core mrpt_typemeta mrpt_containers mrpt_system mrpt_expr mrpt_config)

BUILD_ROOT="$SRC/mayhem/_build"
SAN_PREFIX="$BUILD_ROOT/install-san"
SAN_BUILD="$BUILD_ROOT/build-san"
TEST_PREFIX="$BUILD_ROOT/install-test"
TEST_BUILD="$BUILD_ROOT/build-test"
GTEST_PREFIX="$BUILD_ROOT/install-gtest"
GTEST_BUILD="$BUILD_ROOT/build-gtest"
mkdir -p "$BUILD_ROOT"

# ---------------------------------------------------------------------------------------------
# 0) Sanity: the three bundled 3rd-party submodules must already be checked out (Dockerfile does
#    `git submodule update --init` for these, with network, before invoking this script).
# ---------------------------------------------------------------------------------------------
for sm in 3rdparty/googletest modules/mrpt_config/3rdparty/simpleini modules/mrpt_containers/3rdparty/libfyaml; do
  if [ ! -e "$SRC/$sm/CMakeLists.txt" ]; then
    echo "build.sh: required submodule '$sm' is not checked out (expected mayhem/Dockerfile to have" >&2
    echo "  run 'git submodule update --init' for it before build.sh runs) -- aborting." >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------------------------
# 1) GoogleTest, built once (normal flags) from MRPT's own pinned submodule, for the TEST pass.
# ---------------------------------------------------------------------------------------------
if [ ! -f "$GTEST_PREFIX/lib/cmake/GTest/GTestConfig.cmake" ]; then
  cmake -S "$SRC/3rdparty/googletest" -B "$GTEST_BUILD" -G Ninja \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$GTEST_PREFIX" \
    -DBUILD_GMOCK=ON -Dgtest_force_shared_crt=ON
  cmake --build "$GTEST_BUILD" -j"$MAYHEM_JOBS"
  cmake --install "$GTEST_BUILD"
fi

# ---------------------------------------------------------------------------------------------
# 2) SAN pass — each MRPT module, sanitized + DWARF<4, static libs, installed to $SAN_PREFIX.
#    (Put $DEBUG_FLAGS AFTER $SANITIZER_FLAGS so its -gdwarf-3 wins over any -g the base carries.)
# ---------------------------------------------------------------------------------------------
for mod in "${MRPT_MODULES[@]}"; do
  cmake -S "$SRC/modules/$mod" -B "$SAN_BUILD/$mod" -G Ninja \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
    -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_INSTALL_PREFIX="$SAN_PREFIX" \
    -DCMAKE_PREFIX_PATH="$SAN_PREFIX" \
    -DBUILD_TESTING=OFF
  cmake --build "$SAN_BUILD/$mod" -j"$MAYHEM_JOBS"
  cmake --install "$SAN_BUILD/$mod"
done

# The two harnesses, linked against the sanitized install above (see mayhem/harness/CMakeLists.txt
# for why this goes through CMake's own mrpt::mrpt_config / mrpt::mrpt_system import targets
# instead of a hand-written .a list: it's the only way to correctly pull in the PRIVATE-linked
# bundled libfyaml that CConfigFileBase::getContentAsYAML() (used by ini2yaml) needs).
cmake -S "$SRC/mayhem/harness" -B "$SAN_BUILD/harness" -G Ninja \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_PREFIX_PATH="$SAN_PREFIX" \
  -DMAYHEM_OUT_DIR="$SRC" \
  -DMAYHEM_LIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE" \
  -DMAYHEM_STANDALONE_FUZZ_MAIN="$STANDALONE_FUZZ_MAIN"
cmake --build "$SAN_BUILD/harness" -j"$MAYHEM_JOBS"

# Sanity: every binary the Mayhemfiles + test suite expect must now exist.
for bin in "$SRC/trim" "$SRC/trim-standalone" "$SRC/ini2yaml"; do
  [ -x "$bin" ] || { echo "build.sh: expected binary missing: $bin" >&2; exit 1; }
done

# ---------------------------------------------------------------------------------------------
# 3) TEST pass — the SAME modules, normal (unsanitized) flags, MRPT's own GoogleTest-based unit
#    tests turned on (BUILD_TESTING=ON). A clean, independent build tree/prefix from the SAN pass
#    above, so mayhem/test.sh's oracle never depends on (or is weakened by) the sanitized build.
# ---------------------------------------------------------------------------------------------
for mod in "${MRPT_MODULES[@]}"; do
  cmake -S "$SRC/modules/$mod" -B "$TEST_BUILD/$mod" -G Ninja \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX="$TEST_PREFIX" \
    -DCMAKE_PREFIX_PATH="$TEST_PREFIX;$GTEST_PREFIX" \
    -DBUILD_TESTING=ON
  cmake --build "$TEST_BUILD/$mod" -j"$MAYHEM_JOBS"
  cmake --install "$TEST_BUILD/$mod"
done

echo "build.sh: OK — harnesses: $SRC/{trim,trim-standalone,ini2yaml}; test trees: $TEST_BUILD/<module>"

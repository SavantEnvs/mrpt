# mayhem/harness/CMakeLists.txt — builds the Mayhem fuzz targets against the already-built
# (and already-installed) MRPT module libraries. This is NOT an upstream file: it only links
# against the mrpt::mrpt_config / mrpt::mrpt_system CMake import targets so the correct
# transitive link set (incl. the PRIVATE-linked bundled libfyaml pulled in by mrpt_containers,
# needed by CConfigFileBase::getContentAsYAML()) is resolved automatically by CMake instead of
# being hand-listed here.
#
# Configured by mayhem/build.sh with CMAKE_PREFIX_PATH pointing at the sanitized MRPT install
# prefix, and CMAKE_C_FLAGS/CMAKE_CXX_FLAGS carrying $SANITIZER_FLAGS $DEBUG_FLAGS so the
# harness object code matches the ABI/instrumentation of the libraries it links against.
cmake_minimum_required(VERSION 3.16)
project(mayhem_harness LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Threads REQUIRED)
find_package(mrpt_config REQUIRED)   # transitively pulls mrpt_expr/mrpt_system/mrpt_core/...

set(MRPT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../..")

# --- trim: in-process libFuzzer harness over mrpt::system::trim() -----------------------------
# LIB_FUZZING_ENGINE (from the base image ENV, e.g. "-fsanitize=fuzzer") is passed in via the
# MAYHEM_LIB_FUZZING_ENGINE cache var so it applies to both the compile and link steps.
add_executable(trim "${CMAKE_CURRENT_SOURCE_DIR}/../fuzz_trim.cpp")
target_link_libraries(trim PRIVATE mrpt::mrpt_system)
if(MAYHEM_LIB_FUZZING_ENGINE)
  separate_arguments(_fuzz_engine_flags UNIX_COMMAND "${MAYHEM_LIB_FUZZING_ENGINE}")
  target_compile_options(trim PRIVATE ${_fuzz_engine_flags})
  target_link_options(trim PRIVATE ${_fuzz_engine_flags})
endif()

# --- trim-standalone: same harness, but linked against the base's non-fuzzer run-once driver
# instead of the fuzzing engine -> a plain reproducer binary (one input file, runs once, no
# libFuzzer runtime). The driver is a .c file; CMake compiles it with the C compiler based on
# its extension even though it lands in a C++ executable, so LLVMFuzzerTestOneInput's `extern
# "C"` symbol resolves correctly without manually pre-compiling it as a separate object.
if(MAYHEM_STANDALONE_FUZZ_MAIN)
  add_executable(trim-standalone
    "${CMAKE_CURRENT_SOURCE_DIR}/../fuzz_trim.cpp"
    "${MAYHEM_STANDALONE_FUZZ_MAIN}"
  )
  target_link_libraries(trim-standalone PRIVATE mrpt::mrpt_system)
endif()

# --- ini2yaml: the real upstream CLI (apps/mrpt_apps_cli/mrpt-ini2yaml/ini2yaml_main.cpp),
# built sanitized. It is already a raw, single-input-file, run-once program (argv[1] = path to
# an .ini file) -- there is no separate libFuzzer driver to swap out, so this sanitized binary
# IS its own standalone reproducer (same convention as this repo's other file-input targets).
add_executable(ini2yaml "${MRPT_ROOT}/apps/mrpt_apps_cli/mrpt-ini2yaml/ini2yaml_main.cpp")
target_link_libraries(ini2yaml PRIVATE mrpt::mrpt_config)

# Drop every produced binary directly at /mayhem/<name>, matching the Mayhemfiles' cmd: paths.
set_target_properties(trim ini2yaml PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${MAYHEM_OUT_DIR}")
if(TARGET trim-standalone)
  set_target_properties(trim-standalone PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${MAYHEM_OUT_DIR}")
endif()

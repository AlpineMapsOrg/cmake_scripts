#############################################################################
# AlpineMaps.org
# Copyright (C) 2026 Adam Celarek <family name at cg tuwien ac at>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#############################################################################

cmake_minimum_required(VERSION 3.25)

if(WIN32)
    set(_temp_base "$ENV{TEMP}")
elseif(DEFINED ENV{TMPDIR} AND NOT "$ENV{TMPDIR}" STREQUAL "")
    set(_temp_base "$ENV{TMPDIR}")
else()
    set(_temp_base "/tmp")
endif()
file(TO_CMAKE_PATH "${_temp_base}" _temp_base)

string(RANDOM LENGTH 12 ALPHABET 0123456789abcdef _test_suffix)
set(_test_root "${_temp_base}/alp_setup_cmake_project_${_test_suffix}")
set(_fixture_source "${_test_root}/fixture")
set(_source_outer "${_test_root}/source-outer")
set(_git_outer "${_test_root}/git-outer")
set(_archive_outer "${_test_root}/archive-outer")
set(_setup_script "${CMAKE_CURRENT_LIST_DIR}/SetupCMakeProject.cmake")
set(_archive "${_test_root}/fixture.tar.xz")
set(_archive_variant "${_test_root}/fixture-variant.tar.xz")

file(MAKE_DIRECTORY
    "${_fixture_source}"
    "${_source_outer}"
    "${_git_outer}"
    "${_archive_outer}")

file(WRITE "${_fixture_source}/CMakeLists.txt" [=[
cmake_minimum_required(VERSION 3.25)
project(alp_setup_fixture NONE)

file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/forwarded.txt"
    "CMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}\n"
    "CMAKE_CONFIGURATION_TYPES=${CMAKE_CONFIGURATION_TYPES}\n"
    "CMAKE_PREFIX_PATH=${CMAKE_PREFIX_PATH}\n"
    "CMAKE_C_FLAGS=${CMAKE_C_FLAGS}\n"
    "CMAKE_CXX_FLAGS=${CMAKE_CXX_FLAGS}\n"
    "CMAKE_EXE_LINKER_FLAGS=${CMAKE_EXE_LINKER_FLAGS}\n"
    "FIXTURE_LIST=${FIXTURE_LIST}\n"
    "FIXTURE_VALUE=${FIXTURE_VALUE}\n")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/forwarded.txt" DESTINATION .)
]=])

set(_source_outer_template [=[
cmake_minimum_required(VERSION 3.25)
project(alp_setup_source_outer NONE)

function(alp_add_git_repository)
    message(FATAL_ERROR "The source-directory setup unexpectedly used Git")
endfunction()
function(alp_check_for_script_updates)
endfunction()

include("@SETUP_SCRIPT@")
set(ALP_SANITIZER_FLAGS -fsanitize=undefined -fno-omit-frame-pointer)
alp_setup_cmake_project_from_source(fixture
    SOURCE_DIR "@FIXTURE_SOURCE@"
    SOURCE_SIGNATURE "${FIXTURE_SIGNATURE}"
    CMAKE_ARGUMENTS
        "-DFIXTURE_LIST:STRING=graph\;multiprecision\;heap\;format\;logic"
        "-DFIXTURE_VALUE:STRING=${FIXTURE_VALUE}")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/exported-install-dir.txt"
    "${ALP_fixture_INSTALL_DIR}")
]=])

set(_git_outer_template [=[
cmake_minimum_required(VERSION 3.25)
project(alp_setup_git_outer NONE)

function(alp_add_git_repository name)
    if(FAIL_IF_GIT_CALLED)
        message(FATAL_ERROR "Git source acquisition was not skipped on a restored-install cache hit")
    endif()
    file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/git-called.txt" "${ARGN}")
    set(${name}_SOURCE_DIR "@FIXTURE_SOURCE@" PARENT_SCOPE)
endfunction()
function(alp_check_for_script_updates)
endfunction()

include("@SETUP_SCRIPT@")
alp_setup_cmake_project(git_fixture
    URL "${FIXTURE_URL}"
    COMMITISH fixture-commit
    CMAKE_ARGUMENTS
        "-DFIXTURE_LIST:STRING=graph\;multiprecision\;heap\;format\;logic"
        "-DFIXTURE_VALUE:STRING=${FIXTURE_VALUE}")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/exported-install-dir.txt"
    "${ALP_git_fixture_INSTALL_DIR}")
]=])

set(_archive_outer_template [=[
cmake_minimum_required(VERSION 3.25)
project(alp_setup_archive_outer NONE)

function(alp_add_git_repository)
    message(FATAL_ERROR "The archive setup unexpectedly used Git")
endfunction()
function(alp_check_for_script_updates)
endfunction()

include("@SETUP_SCRIPT@")
alp_setup_cmake_project(archive_fixture
    URL "${FIXTURE_URL}"
    SHA256 "${FIXTURE_SHA256}"
    CMAKE_ARGUMENTS
        "-DFIXTURE_LIST:STRING=graph\;multiprecision\;heap\;format\;logic"
        "-DFIXTURE_VALUE:STRING=${FIXTURE_VALUE}")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/exported-install-dir.txt"
    "${ALP_archive_fixture_INSTALL_DIR}")
]=])

set(SETUP_SCRIPT "${_setup_script}")
set(FIXTURE_SOURCE "${_fixture_source}")
string(CONFIGURE "${_source_outer_template}" _source_outer_content @ONLY)
string(CONFIGURE "${_git_outer_template}" _git_outer_content @ONLY)
string(CONFIGURE "${_archive_outer_template}" _archive_outer_content @ONLY)
file(WRITE "${_source_outer}/CMakeLists.txt" "${_source_outer_content}")
file(WRITE "${_git_outer}/CMakeLists.txt" "${_git_outer_content}")
file(WRITE "${_archive_outer}/CMakeLists.txt" "${_archive_outer_content}")

execute_process(
    COMMAND "${CMAKE_COMMAND}" -E tar cJf "${_archive}" --format=gnutar CMakeLists.txt
    WORKING_DIRECTORY "${_fixture_source}"
    RESULT_VARIABLE _archive_result
    ERROR_VARIABLE _archive_error)
if(_archive_result)
    message(FATAL_ERROR "Creating fixture archive failed: ${_archive_error}")
endif()
file(SHA256 "${_archive}" _archive_sha256)

file(WRITE "${_fixture_source}/variant.txt" "checksum variant\n")
execute_process(
    COMMAND "${CMAKE_COMMAND}" -E tar cJf "${_archive_variant}" --format=gnutar
        CMakeLists.txt variant.txt
    WORKING_DIRECTORY "${_fixture_source}"
    RESULT_VARIABLE _archive_variant_result
    ERROR_VARIABLE _archive_variant_error)
file(REMOVE "${_fixture_source}/variant.txt")
if(_archive_variant_result)
    message(FATAL_ERROR "Creating variant fixture archive failed: ${_archive_variant_error}")
endif()
file(SHA256 "${_archive_variant}" _archive_variant_sha256)

find_program(_ninja ninja REQUIRED)

function(_run_configure source_dir build_dir output_var)
    set(options EXPECT_FAILURE)
    set(oneValueArgs GENERATOR URL SHA256 SIGNATURE VALUE FAIL_IF_GIT_CALLED EXTERN_DIR)
    cmake_parse_arguments(PARSE_ARGV 3 arg "${options}" "${oneValueArgs}" "")

    foreach(_optional URL SHA256 SIGNATURE VALUE FAIL_IF_GIT_CALLED EXTERN_DIR)
        if(NOT DEFINED arg_${_optional})
            set(arg_${_optional} "")
        endif()
    endforeach()

    execute_process(
        COMMAND "${CMAKE_COMMAND}"
            -G "${arg_GENERATOR}"
            -S "${source_dir}"
            -B "${build_dir}"
            "-DFIXTURE_URL:STRING=${arg_URL}"
            "-DFIXTURE_SHA256:STRING=${arg_SHA256}"
            "-DFIXTURE_SIGNATURE:STRING=${arg_SIGNATURE}"
            "-DFIXTURE_VALUE:STRING=${arg_VALUE}"
            "-DFAIL_IF_GIT_CALLED:BOOL=${arg_FAIL_IF_GIT_CALLED}"
            "-DALP_EXTERN_DIR:STRING=${arg_EXTERN_DIR}"
            "-DCMAKE_PREFIX_PATH:PATH=/prefix/one;/prefix/two"
            "-DCMAKE_C_FLAGS:STRING=-DOUTER_C"
            "-DCMAKE_CXX_FLAGS:STRING=-DOUTER_CXX"
            "-DCMAKE_EXE_LINKER_FLAGS:STRING=-Wl,--as-needed"
        RESULT_VARIABLE _result
        OUTPUT_VARIABLE _output
        ERROR_VARIABLE _error)
    set(_diagnostic "${_output}${_error}")

    if(arg_EXPECT_FAILURE)
        if(NOT _result)
            message(FATAL_ERROR "Configure unexpectedly succeeded:\n${_diagnostic}")
        endif()
    elseif(_result)
        message(FATAL_ERROR "Configure failed:\n${_diagnostic}")
    endif()
    set("${output_var}" "${_diagnostic}" PARENT_SCOPE)
endfunction()

function(_configure generator source_dir build_dir output_var)
    set(options EXPECT_FAILURE)
    set(oneValueArgs URL SHA256 SIGNATURE VALUE FAIL_IF_GIT_CALLED EXTERN_DIR)
    cmake_parse_arguments(PARSE_ARGV 4 arg "${options}" "${oneValueArgs}" "")

    set(_failure_arg)
    if(arg_EXPECT_FAILURE)
        set(_failure_arg EXPECT_FAILURE)
    endif()
    set(_configure_args ${_failure_arg} GENERATOR "${generator}")
    foreach(_optional URL SHA256 SIGNATURE VALUE FAIL_IF_GIT_CALLED EXTERN_DIR)
        if(DEFINED arg_${_optional})
            list(APPEND _configure_args ${_optional} "${arg_${_optional}}")
        endif()
    endforeach()
    _run_configure("${source_dir}" "${build_dir}" _output ${_configure_args})
    set("${output_var}" "${_output}" PARENT_SCOPE)
endfunction()

function(_assert_file_contains path expected)
    if(NOT EXISTS "${path}")
        message(FATAL_ERROR "Expected file does not exist: ${path}")
    endif()
    file(READ "${path}" _content)
    string(FIND "${_content}" "${expected}" _position)
    if(_position EQUAL -1)
        message(FATAL_ERROR "Expected '${expected}' in ${path}:\n${_content}")
    endif()
endfunction()

function(_assert_contains content expected)
    string(FIND "${content}" "${expected}" _position)
    if(_position EQUAL -1)
        message(FATAL_ERROR "Expected '${expected}' in diagnostic:\n${content}")
    endif()
endfunction()

function(_remove_parent_cache build_dir)
    file(REMOVE "${build_dir}/CMakeCache.txt")
    file(REMOVE_RECURSE "${build_dir}/CMakeFiles")
endfunction()

# Direct source setup, forwarding, active-cache reuse, and invalidation.
set(_source_build "${_test_root}/source-single")
_configure("Ninja" "${_source_outer}" "${_source_build}" _output
    SIGNATURE source-one VALUE one)
set(_source_child_build "${_source_build}/alp_external/fixture_build")
set(_source_install "${_source_build}/alp_external/fixture")
_assert_file_contains("${_source_install}/forwarded.txt" "CMAKE_BUILD_TYPE=Release")
_assert_file_contains("${_source_install}/forwarded.txt" "CMAKE_PREFIX_PATH=/prefix/one;/prefix/two")
_assert_file_contains("${_source_install}/forwarded.txt"
    "CMAKE_C_FLAGS=-DOUTER_C -fsanitize=undefined -fno-omit-frame-pointer")
_assert_file_contains("${_source_install}/forwarded.txt"
    "CMAKE_CXX_FLAGS=-DOUTER_CXX -fsanitize=undefined -fno-omit-frame-pointer")
_assert_file_contains("${_source_install}/forwarded.txt"
    "CMAKE_EXE_LINKER_FLAGS=-Wl,--as-needed -fsanitize=undefined -fno-omit-frame-pointer")
_assert_file_contains("${_source_install}/forwarded.txt"
    "FIXTURE_LIST=graph;multiprecision;heap;format;logic")
_assert_file_contains("${_source_build}/exported-install-dir.txt" "${_source_install}")
if(NOT EXISTS "${_source_install}/.alp_install_signature")
    message(FATAL_ERROR "The installed dependency has no persistent cache signature")
endif()

file(WRITE "${_source_child_build}/cache-hit-marker" "keep")
file(WRITE "${_source_install}/cache-hit-marker" "keep")
_configure("Ninja" "${_source_outer}" "${_source_build}" _output
    SIGNATURE source-one VALUE one)
_assert_contains("${_output}" "[alp] Using cached install for fixture")
if(NOT EXISTS "${_source_child_build}/cache-hit-marker"
        OR NOT EXISTS "${_source_install}/cache-hit-marker")
    message(FATAL_ERROR "An active-cache hit removed the child build or install directory")
endif()

# A restored install must work after the parent cache and source disappear.
_remove_parent_cache("${_source_build}")
file(RENAME "${_fixture_source}" "${_fixture_source}.unavailable")
_configure("Ninja" "${_source_outer}" "${_source_build}" _output
    SIGNATURE source-one VALUE one)
_assert_contains("${_output}" "[alp] Using cached install for fixture")
file(RENAME "${_fixture_source}.unavailable" "${_fixture_source}")
if(NOT EXISTS "${_source_child_build}/cache-hit-marker"
        OR NOT EXISTS "${_source_install}/cache-hit-marker")
    message(FATAL_ERROR "A restored-install cache hit removed cached dependency data")
endif()

_configure("Ninja" "${_source_outer}" "${_source_build}" _output
    SIGNATURE source-two VALUE two)
if(EXISTS "${_source_child_build}/cache-hit-marker"
        OR EXISTS "${_source_install}/cache-hit-marker")
    message(FATAL_ERROR "A source signature change did not invalidate build and install directories")
endif()
_assert_file_contains("${_source_install}/forwarded.txt" "FIXTURE_VALUE=two")

# Multi-config behavior remains supported.
set(_multi_build "${_test_root}/source-multi")
_configure("Ninja Multi-Config" "${_source_outer}" "${_multi_build}" _output
    SIGNATURE source-multi VALUE multi)
_assert_file_contains("${_multi_build}/alp_external/fixture/forwarded.txt"
    "CMAKE_CONFIGURATION_TYPES=")
_assert_file_contains("${_multi_build}/alp_external/fixture/forwarded.txt"
    "FIXTURE_VALUE=multi")

# The legacy Git API keeps its signature and skips Git on a restored cache hit.
set(_git_build "${_test_root}/git")
_configure("Ninja" "${_git_outer}" "${_git_build}" _output
    URL fixture://one VALUE git-one FAIL_IF_GIT_CALLED OFF)
_assert_file_contains("${_git_build}/git-called.txt"
    "URL;fixture://one;COMMITISH;fixture-commit;DO_NOT_ADD_SUBPROJECT")
_assert_file_contains("${_git_build}/alp_external/git_fixture/forwarded.txt"
    "FIXTURE_LIST=graph;multiprecision;heap;format;logic")
set(_git_install "${_git_build}/alp_external/git_fixture")
set(_git_child_build "${_git_build}/alp_external/git_fixture_build")
file(WRITE "${_git_install}/cache-hit-marker" "keep")
file(WRITE "${_git_child_build}/cache-hit-marker" "keep")
_remove_parent_cache("${_git_build}")
_configure("Ninja" "${_git_outer}" "${_git_build}" _output
    URL fixture://one VALUE git-one FAIL_IF_GIT_CALLED ON)
_assert_contains("${_output}" "[alp] Using cached install for git_fixture")
if(NOT EXISTS "${_git_install}/cache-hit-marker"
        OR NOT EXISTS "${_git_child_build}/cache-hit-marker")
    message(FATAL_ERROR "The Git wrapper did not preserve restored dependency data")
endif()

# Archive setup verifies SHA-256 and skips download/extraction on restored hits.
set(_archive_build "${_test_root}/archive")
_configure("Ninja" "${_archive_outer}" "${_archive_build}" _output
    URL "${_archive}" SHA256 "${_archive_sha256}" VALUE archive-one)
set(_archive_install "${_archive_build}/alp_external/archive_fixture")
set(_shared_archive_source
    "${_archive_outer}/extern/archive_fixture_${_archive_sha256}")
_assert_file_contains("${_archive_install}/forwarded.txt" "FIXTURE_VALUE=archive-one")
_assert_file_contains("${_archive_install}/forwarded.txt"
    "FIXTURE_LIST=graph;multiprecision;heap;format;logic")
_assert_file_contains("${_shared_archive_source}/.alp_archive_signature"
    "SHA256=${_archive_sha256}")

# A different build directory reuses the extracted source without access to the archive.
file(RENAME "${_archive}" "${_archive}.unavailable")
set(_archive_second_build "${_test_root}/archive-second-build")
_configure("Ninja" "${_archive_outer}" "${_archive_second_build}" _output
    URL "${_archive}" SHA256 "${_archive_sha256}" VALUE archive-second)
_assert_contains("${_output}" "[alp] Using shared archive source for archive_fixture")
_assert_file_contains(
    "${_archive_second_build}/alp_external/archive_fixture/forwarded.txt"
    "FIXTURE_VALUE=archive-second")
file(RENAME "${_archive}.unavailable" "${_archive}")

# An incomplete shared directory is discarded and populated again.
file(REMOVE_RECURSE "${_shared_archive_source}")
file(MAKE_DIRECTORY "${_shared_archive_source}")
file(WRITE "${_shared_archive_source}/incomplete" "remove me")
set(_archive_recovery_build "${_test_root}/archive-recovery")
_configure("Ninja" "${_archive_outer}" "${_archive_recovery_build}" _output
    URL "${_archive}" SHA256 "${_archive_sha256}" VALUE archive-recovered)
if(EXISTS "${_shared_archive_source}/incomplete")
    message(FATAL_ERROR "An incomplete shared archive source was not replaced")
endif()
_assert_file_contains("${_shared_archive_source}/.alp_archive_signature"
    "SHA256=${_archive_sha256}")

# Different archive contents use a different full-checksum source directory.
set(_archive_variant_build "${_test_root}/archive-variant")
_configure("Ninja" "${_archive_outer}" "${_archive_variant_build}" _output
    URL "${_archive_variant}" SHA256 "${_archive_variant_sha256}" VALUE archive-variant)
set(_shared_archive_variant_source
    "${_archive_outer}/extern/archive_fixture_${_archive_variant_sha256}")
if(_shared_archive_source STREQUAL _shared_archive_variant_source
        OR NOT EXISTS "${_shared_archive_source}/CMakeLists.txt"
        OR NOT EXISTS "${_shared_archive_variant_source}/CMakeLists.txt")
    message(FATAL_ERROR "Archive checksums did not produce isolated shared source directories")
endif()

file(WRITE "${_archive_install}/cache-hit-marker" "keep")
_remove_parent_cache("${_archive_build}")
file(REMOVE_RECURSE "${_archive_build}/_deps")
file(RENAME "${_archive}" "${_archive}.unavailable")
_configure("Ninja" "${_archive_outer}" "${_archive_build}" _output
    URL "${_archive}" SHA256 "${_archive_sha256}" VALUE archive-one)
_assert_contains("${_output}" "[alp] Using cached install for archive_fixture")
file(RENAME "${_archive}.unavailable" "${_archive}")
if(NOT EXISTS "${_archive_install}/cache-hit-marker")
    message(FATAL_ERROR "The archive wrapper did not preserve its restored install")
endif()

string(REPEAT "0" 64 _wrong_sha256)
_configure("Ninja" "${_archive_outer}" "${_test_root}/archive-bad-checksum" _output
    EXPECT_FAILURE URL "${_archive}" SHA256 "${_wrong_sha256}" VALUE bad)
_assert_contains("${_output}" "does not match expected value")

_configure("Ninja" "${_archive_outer}" "${_test_root}/archive-bad-hash" _output
    EXPECT_FAILURE URL "${_archive}" SHA256 deadbeef VALUE bad)
_assert_contains("${_output}" "SHA256 must be 64 hexadecimal characters")

_configure("Ninja" "${_archive_outer}" "${_test_root}/archive-escaping-extern" _output
    EXPECT_FAILURE URL "${_archive}" SHA256 "${_archive_sha256}" VALUE bad
    EXTERN_DIR ../escape)
_assert_contains("${_output}" "ALP_EXTERN_DIR '../escape' escapes")

_configure("Ninja" "${_source_outer}" "${_test_root}/source-missing-signature" _output
    EXPECT_FAILURE VALUE bad)
_assert_contains("${_output}" "alp_setup_cmake_project_from_source() needs")

file(REMOVE_RECURSE "${_test_root}")
message(STATUS "SetupCMakeProject tests passed")

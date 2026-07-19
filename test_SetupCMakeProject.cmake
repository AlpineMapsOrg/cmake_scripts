#############################################################################
# AlpineMaps.org
# Copyright (C) 2026 Adam Celarek <family name at cg tuwien ac at>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#############################################################################

cmake_minimum_required(VERSION 3.24)

string(RANDOM LENGTH 12 ALPHABET 0123456789abcdef _test_suffix)
set(_test_root "/tmp/alp_setup_cmake_project_${_test_suffix}")
set(_fixture_source "${_test_root}/fixture")
set(_outer_source "${_test_root}/outer")
set(_setup_script "${CMAKE_CURRENT_LIST_DIR}/SetupCMakeProject.cmake")

file(MAKE_DIRECTORY "${_fixture_source}" "${_outer_source}")

file(WRITE "${_fixture_source}/CMakeLists.txt" [=[
cmake_minimum_required(VERSION 3.24)
project(alp_setup_fixture NONE)

file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/forwarded.txt"
    "CMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}\n"
    "CMAKE_CONFIGURATION_TYPES=${CMAKE_CONFIGURATION_TYPES}\n"
    "CMAKE_PREFIX_PATH=${CMAKE_PREFIX_PATH}\n"
    "CMAKE_C_FLAGS=${CMAKE_C_FLAGS}\n"
    "CMAKE_CXX_FLAGS=${CMAKE_CXX_FLAGS}\n"
    "CMAKE_EXE_LINKER_FLAGS=${CMAKE_EXE_LINKER_FLAGS}\n"
    "FIXTURE_VALUE=${FIXTURE_VALUE}\n")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/forwarded.txt" DESTINATION .)
]=])

set(_outer_template [=[
cmake_minimum_required(VERSION 3.24)
project(alp_setup_outer LANGUAGES C CXX)

function(alp_add_git_repository name)
    set(${name}_SOURCE_DIR "@FIXTURE_SOURCE@" PARENT_SCOPE)
endfunction()

function(alp_check_for_script_updates)
endfunction()

include("@SETUP_SCRIPT@")

set(ALP_SANITIZER_FLAGS -fsanitize=undefined -fno-omit-frame-pointer)
alp_setup_cmake_project(fixture
    URL "${FIXTURE_URL}"
    COMMITISH fixture-commit
    CMAKE_ARGUMENTS "-DFIXTURE_VALUE:STRING=${FIXTURE_VALUE}")

file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/exported-install-dir.txt"
    "${ALP_fixture_INSTALL_DIR}")
]=])
set(FIXTURE_SOURCE "${_fixture_source}")
set(SETUP_SCRIPT "${_setup_script}")
string(CONFIGURE "${_outer_template}" _outer_content @ONLY)
file(WRITE "${_outer_source}/CMakeLists.txt" "${_outer_content}")

function(_run_configure generator build_dir url value)
    execute_process(
        COMMAND "${CMAKE_COMMAND}"
            -G "${generator}"
            -S "${_outer_source}"
            -B "${build_dir}"
            "-DFIXTURE_URL:STRING=${url}"
            "-DFIXTURE_VALUE:STRING=${value}"
            "-DCMAKE_PREFIX_PATH:PATH=/prefix/one;/prefix/two"
            "-DCMAKE_C_FLAGS:STRING=-DOUTER_C"
            "-DCMAKE_CXX_FLAGS:STRING=-DOUTER_CXX"
            "-DCMAKE_EXE_LINKER_FLAGS:STRING=-Wl,--as-needed"
        RESULT_VARIABLE _result)
    if(_result)
        message(FATAL_ERROR "Configure failed for generator '${generator}'")
    endif()
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

find_program(_ninja ninja REQUIRED)

set(_single_build "${_test_root}/single")
_run_configure("Ninja" "${_single_build}" "fixture://one" "one")
set(_single_child_build "${_single_build}/alp_external/fixture_build")
set(_single_install "${_single_build}/alp_external/fixture")
_assert_file_contains("${_single_install}/forwarded.txt" "CMAKE_BUILD_TYPE=Release")
_assert_file_contains("${_single_install}/forwarded.txt" "CMAKE_PREFIX_PATH=/prefix/one;/prefix/two")
_assert_file_contains("${_single_install}/forwarded.txt" "CMAKE_C_FLAGS=-DOUTER_C -fsanitize=undefined -fno-omit-frame-pointer")
_assert_file_contains("${_single_install}/forwarded.txt" "CMAKE_CXX_FLAGS=-DOUTER_CXX -fsanitize=undefined -fno-omit-frame-pointer")
_assert_file_contains("${_single_install}/forwarded.txt" "CMAKE_EXE_LINKER_FLAGS=-Wl,--as-needed -fsanitize=undefined -fno-omit-frame-pointer")
_assert_file_contains("${_single_build}/exported-install-dir.txt" "${_single_install}")

file(WRITE "${_single_child_build}/cache-hit-marker" "keep")
file(WRITE "${_single_install}/cache-hit-marker" "keep")
_run_configure("Ninja" "${_single_build}" "fixture://one" "one")
if(NOT EXISTS "${_single_child_build}/cache-hit-marker"
        OR NOT EXISTS "${_single_install}/cache-hit-marker")
    message(FATAL_ERROR "A cache hit removed the child build or install directory")
endif()

_run_configure("Ninja" "${_single_build}" "fixture://two" "one")
if(EXISTS "${_single_child_build}/cache-hit-marker"
        OR EXISTS "${_single_install}/cache-hit-marker")
    message(FATAL_ERROR "A URL key change did not remove both child directories")
endif()

set(_multi_build "${_test_root}/multi")
_run_configure("Ninja Multi-Config" "${_multi_build}" "fixture://multi" "multi")
_assert_file_contains("${_multi_build}/alp_external/fixture/forwarded.txt" "CMAKE_CONFIGURATION_TYPES=")
_assert_file_contains("${_multi_build}/alp_external/fixture/forwarded.txt" "FIXTURE_VALUE=multi")

file(REMOVE_RECURSE "${_test_root}")
message(STATUS "SetupCMakeProject tests passed")

#############################################################################
# AlpineMaps.org
# Copyright (C) 2026 Adam Celarek <family name at cg tuwien ac at>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#############################################################################

include_guard(GLOBAL)

if(NOT COMMAND alp_add_git_repository)
    include(${CMAKE_CURRENT_LIST_DIR}/AddRepo.cmake)
endif()

if(NOT COMMAND alp_check_for_script_updates)
    include(${CMAKE_CURRENT_LIST_DIR}/CheckForScriptUpdates.cmake)
endif()

alp_check_for_script_updates("${CMAKE_CURRENT_LIST_FILE}")

macro(_alp_append_cache_arg out var type)
    if(DEFINED ${var} AND NOT "${${var}}" STREQUAL "")
        set(_alp_cache_value "${${var}}")
        string(REPLACE ";" "\\;" _alp_cache_value "${_alp_cache_value}")
        list(APPEND ${out} "-D${var}:${type}=${_alp_cache_value}")
        unset(_alp_cache_value)
    endif()
endmacro()

macro(_alp_append_key_value out var)
    if(DEFINED ${var})
        set(_alp_key_value "${${var}}")
        string(REPLACE ";" "\\;" _alp_key_value "${_alp_key_value}")
        list(APPEND ${out} "${var}=${_alp_key_value}")
        unset(_alp_key_value)
    endif()
endmacro()

set(_ALP_CMAKE_PROJECT_FORWARD_VARS
    CMAKE_TOOLCHAIN_FILE
    CMAKE_SYSROOT
    CMAKE_FIND_ROOT_PATH
    CMAKE_FIND_ROOT_PATH_MODE_PROGRAM
    CMAKE_FIND_ROOT_PATH_MODE_LIBRARY
    CMAKE_FIND_ROOT_PATH_MODE_INCLUDE
    CMAKE_FIND_ROOT_PATH_MODE_PACKAGE
    CMAKE_SYSTEM_NAME
    CMAKE_SYSTEM_PROCESSOR
    CMAKE_SYSTEM_VERSION
    CMAKE_C_COMPILER
    CMAKE_CXX_COMPILER
    CMAKE_AR
    CMAKE_RANLIB
    CMAKE_MAKE_PROGRAM
    CMAKE_CROSSCOMPILING_EMULATOR
    CMAKE_POSITION_INDEPENDENT_CODE
    CMAKE_MSVC_RUNTIME_LIBRARY
    QT_HOST_PATH
    QT_HOST_PATH_CMAKE_DIR
    Qt6HostInfo_DIR
    ANDROID_ABI
    ANDROID_PLATFORM
    ANDROID_STL
    ANDROID_NDK
    ANDROID_SDK_ROOT
    ANDROID_USE_LEGACY_TOOLCHAIN_FILE
    EMSCRIPTEN
    EMSCRIPTEN_FORCE_COMPILERS
    EMSCRIPTEN_GENERATE_BITCODE_STATIC_LIBRARIES)

function(_alp_build_and_install_cmake_project NAME SRC_DIR BUILD_DIR INSTALL_DIR BUILD_CONFIG CMAKE_ARGUMENTS_VAR)
    set(_generator_args)
    if(CMAKE_GENERATOR_PLATFORM)
        list(APPEND _generator_args -A "${CMAKE_GENERATOR_PLATFORM}")
    endif()
    if(CMAKE_GENERATOR_TOOLSET)
        list(APPEND _generator_args -T "${CMAKE_GENERATOR_TOOLSET}")
    endif()

    set(_configure_args
        "-DCMAKE_INSTALL_PREFIX:PATH=${INSTALL_DIR}"
    )
    _alp_append_cache_arg(_configure_args CMAKE_PREFIX_PATH PATH)

    if(CMAKE_CONFIGURATION_TYPES)
        _alp_append_cache_arg(_configure_args CMAKE_CONFIGURATION_TYPES STRING)
    else()
        list(APPEND _configure_args "-DCMAKE_BUILD_TYPE:STRING=${BUILD_CONFIG}")
    endif()

    foreach(_var IN LISTS _ALP_CMAKE_PROJECT_FORWARD_VARS)
        _alp_append_cache_arg(_configure_args ${_var} STRING)
    endforeach()

    string(JOIN " " _alp_sanitizer_flags ${ALP_SANITIZER_FLAGS})

    foreach(_lang C CXX)
        set(_alp_effective_flags "${CMAKE_${_lang}_FLAGS}")
        if(_alp_sanitizer_flags)
            string(APPEND _alp_effective_flags " ${_alp_sanitizer_flags}")
        endif()
        if(_alp_effective_flags)
            string(REPLACE ";" "\\;" _alp_effective_flags "${_alp_effective_flags}")
            list(APPEND _configure_args "-DCMAKE_${_lang}_FLAGS:STRING=${_alp_effective_flags}")
        endif()
        foreach(_config DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
            _alp_append_cache_arg(_configure_args CMAKE_${_lang}_FLAGS_${_config} STRING)
        endforeach()
    endforeach()

    foreach(_kind EXE SHARED MODULE STATIC)
        set(_alp_effective_flags "${CMAKE_${_kind}_LINKER_FLAGS}")
        if(_alp_sanitizer_flags AND NOT _kind STREQUAL "STATIC")
            string(APPEND _alp_effective_flags " ${_alp_sanitizer_flags}")
        endif()
        if(_alp_effective_flags)
            string(REPLACE ";" "\\;" _alp_effective_flags "${_alp_effective_flags}")
            list(APPEND _configure_args "-DCMAKE_${_kind}_LINKER_FLAGS:STRING=${_alp_effective_flags}")
        endif()
        foreach(_config DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
            _alp_append_cache_arg(_configure_args CMAKE_${_kind}_LINKER_FLAGS_${_config} STRING)
        endforeach()
    endforeach()

    foreach(_argument IN LISTS ${CMAKE_ARGUMENTS_VAR})
        list(APPEND _configure_args "${_argument}")
    endforeach()

    message(STATUS "[alp] Configuring ${NAME}")
    execute_process(
        COMMAND "${CMAKE_COMMAND}"
                -G "${CMAKE_GENERATOR}"
                ${_generator_args}
                -S "${SRC_DIR}"
                -B "${BUILD_DIR}"
                ${_configure_args}
        RESULT_VARIABLE _cfg_res)

    if(_cfg_res)
        message(FATAL_ERROR "[alp] Configuring ${NAME} failed!")
    endif()

    message(STATUS "[alp] Building + installing ${NAME}")
    execute_process(
        COMMAND "${CMAKE_COMMAND}"
                --build "${BUILD_DIR}"
                --config "${BUILD_CONFIG}"
                --parallel
                --target install
        RESULT_VARIABLE _bld_res)

    if(_bld_res)
        message(FATAL_ERROR "[alp] Building ${NAME} failed!")
    endif()
endfunction()

function(_alp_cmake_project_build_config output_var)
    set(_build_config "${CMAKE_BUILD_TYPE}")
    if(NOT _build_config)
        set(_build_config Release)
    endif()
    set("${output_var}" "${_build_config}" PARENT_SCOPE)
endfunction()

function(_alp_cmake_project_cache_key arg_NAME source_signature cmake_arguments output_var)
    _alp_cmake_project_build_config(_build_config)
    set(_key_parts
        "NAME=${arg_NAME}"
        "SOURCE_SIGNATURE=${source_signature}"
        "CMAKE_ARGUMENTS=${cmake_arguments}"
        "CMAKE_GENERATOR=${CMAKE_GENERATOR}"
        "CMAKE_GENERATOR_PLATFORM=${CMAKE_GENERATOR_PLATFORM}"
        "CMAKE_GENERATOR_TOOLSET=${CMAKE_GENERATOR_TOOLSET}"
        "CMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}"
        "CMAKE_CONFIGURATION_TYPES=${CMAKE_CONFIGURATION_TYPES}"
        "BUILD_CONFIG=${_build_config}")
    _alp_append_key_value(_key_parts ALP_SANITIZER_FLAGS)
    _alp_append_key_value(_key_parts CMAKE_PREFIX_PATH)
    foreach(_var IN LISTS _ALP_CMAKE_PROJECT_FORWARD_VARS)
        _alp_append_key_value(_key_parts ${_var})
    endforeach()
    foreach(_lang C CXX)
        _alp_append_key_value(_key_parts CMAKE_${_lang}_FLAGS)
        foreach(_config DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
            _alp_append_key_value(_key_parts CMAKE_${_lang}_FLAGS_${_config})
        endforeach()
    endforeach()
    foreach(_kind EXE SHARED MODULE STATIC)
        _alp_append_key_value(_key_parts CMAKE_${_kind}_LINKER_FLAGS)
        foreach(_config DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
            _alp_append_key_value(_key_parts CMAKE_${_kind}_LINKER_FLAGS_${_config})
        endforeach()
    endforeach()
    string(JOIN "\n" _key_input ${_key_parts})
    string(SHA256 _key "${_key_input}")
    set("${output_var}" "${_key}" PARENT_SCOPE)
endfunction()

function(_alp_cmake_project_use_cached_install arg_NAME key output_var)
    set(_version_var "ALP_INSTALLED_${arg_NAME}_VERSION")
    set(_path_var "ALP_INSTALLED_${arg_NAME}_PATH")
    set(_default_install_dir "${CMAKE_BINARY_DIR}/alp_external/${arg_NAME}")
    set(_cached_install_dir "")

    if(DEFINED ${_version_var}
            AND "${${_version_var}}" STREQUAL "${key}"
            AND DEFINED ${_path_var}
            AND EXISTS "${${_path_var}}")
        set(_cached_install_dir "${${_path_var}}")
    elseif(EXISTS "${_default_install_dir}/.alp_install_signature")
        file(READ "${_default_install_dir}/.alp_install_signature" _installed_key)
        string(STRIP "${_installed_key}" _installed_key)
        if(_installed_key STREQUAL key)
            set(_cached_install_dir "${_default_install_dir}")
        endif()
    endif()

    if(_cached_install_dir)
        message(STATUS "[alp] Using cached install for ${arg_NAME}: ${_cached_install_dir}")
        list(PREPEND CMAKE_PREFIX_PATH "${_cached_install_dir}")
        set(CMAKE_PREFIX_PATH "${CMAKE_PREFIX_PATH}" PARENT_SCOPE)
        set(ALP_${arg_NAME}_INSTALL_DIR "${_cached_install_dir}" PARENT_SCOPE)
        set(${_path_var} "${_cached_install_dir}" CACHE PATH "Install path for ${arg_NAME}" FORCE)
        set(${_version_var} "${key}" CACHE STRING "Installed cache key for ${arg_NAME}" FORCE)
        set("${output_var}" TRUE PARENT_SCOPE)
    else()
        set("${output_var}" FALSE PARENT_SCOPE)
    endif()
endfunction()

macro(_alp_cmake_project_propagate_result arg_NAME)
    set(CMAKE_PREFIX_PATH "${CMAKE_PREFIX_PATH}" PARENT_SCOPE)
    set(ALP_${arg_NAME}_INSTALL_DIR "${ALP_${arg_NAME}_INSTALL_DIR}" PARENT_SCOPE)
endmacro()

function(_alp_setup_cmake_project_from_source arg_NAME arg_SOURCE_DIR arg_SOURCE_SIGNATURE CMAKE_ARGUMENTS_VAR)
    set(_cmake_arguments "${${CMAKE_ARGUMENTS_VAR}}")
    _alp_cmake_project_cache_key(
        "${arg_NAME}" "${arg_SOURCE_SIGNATURE}" "${_cmake_arguments}" _key)
    _alp_cmake_project_use_cached_install("${arg_NAME}" "${_key}" _cache_hit)
    if(_cache_hit)
        _alp_cmake_project_propagate_result("${arg_NAME}")
        return()
    endif()

    if(NOT IS_DIRECTORY "${arg_SOURCE_DIR}" OR NOT EXISTS "${arg_SOURCE_DIR}/CMakeLists.txt")
        message(FATAL_ERROR
            "[alp] ${arg_NAME}: SOURCE_DIR '${arg_SOURCE_DIR}' is not a CMake project")
    endif()

    _alp_cmake_project_build_config(_build_config)
    set(_build_dir "${CMAKE_BINARY_DIR}/alp_external/${arg_NAME}_build")
    set(_install_dir "${CMAKE_BINARY_DIR}/alp_external/${arg_NAME}")
    set(_version_var "ALP_INSTALLED_${arg_NAME}_VERSION")
    set(_path_var "ALP_INSTALLED_${arg_NAME}_PATH")

    file(REMOVE_RECURSE "${_build_dir}" "${_install_dir}")
    _alp_build_and_install_cmake_project(
        ${arg_NAME}
        "${arg_SOURCE_DIR}"
        "${_build_dir}"
        "${_install_dir}"
        "${_build_config}"
        _cmake_arguments)
    file(WRITE "${_install_dir}/.alp_install_signature" "${_key}\n")

    list(PREPEND CMAKE_PREFIX_PATH "${_install_dir}")
    set(CMAKE_PREFIX_PATH "${CMAKE_PREFIX_PATH}" PARENT_SCOPE)
    set(ALP_${arg_NAME}_INSTALL_DIR "${_install_dir}" PARENT_SCOPE)

    set(${_path_var} "${_install_dir}" CACHE PATH "Install path for ${arg_NAME}" FORCE)
    set(${_version_var} "${_key}" CACHE STRING "Installed cache key for ${arg_NAME}" FORCE)
endfunction()

function(alp_setup_cmake_project_from_source arg_NAME)
    set(options)
    set(oneValueArgs SOURCE_DIR SOURCE_SIGNATURE)
    set(multiValueArgs CMAKE_ARGUMENTS)
    cmake_parse_arguments(PARSE_ARGV 1 arg "${options}" "${oneValueArgs}" "${multiValueArgs}")

    if(NOT arg_NAME OR NOT arg_SOURCE_DIR OR NOT arg_SOURCE_SIGNATURE)
        message(FATAL_ERROR
            "[alp] alp_setup_cmake_project_from_source() needs: "
            "<name> SOURCE_DIR <path> SOURCE_SIGNATURE <identity>")
    endif()
    if(arg_UNPARSED_ARGUMENTS)
        message(FATAL_ERROR
            "[alp] alp_setup_cmake_project_from_source(): unknown arguments: "
            "${arg_UNPARSED_ARGUMENTS}")
    endif()
    if(arg_KEYWORDS_MISSING_VALUES)
        message(FATAL_ERROR
            "[alp] alp_setup_cmake_project_from_source(): arguments require values: "
            "${arg_KEYWORDS_MISSING_VALUES}")
    endif()

    _alp_setup_cmake_project_from_source(
        "${arg_NAME}" "${arg_SOURCE_DIR}" "${arg_SOURCE_SIGNATURE}" arg_CMAKE_ARGUMENTS)
    _alp_cmake_project_propagate_result("${arg_NAME}")
endfunction()

function(_alp_setup_cmake_project_from_git arg_NAME arg_URL arg_COMMITISH CMAKE_ARGUMENTS_VAR)
    set(_cmake_arguments "${${CMAKE_ARGUMENTS_VAR}}")
    set(_source_signature "GIT\nURL=${arg_URL}\nCOMMITISH=${arg_COMMITISH}")
    _alp_cmake_project_cache_key(
        "${arg_NAME}" "${_source_signature}" "${_cmake_arguments}" _key)
    _alp_cmake_project_use_cached_install("${arg_NAME}" "${_key}" _cache_hit)
    if(_cache_hit)
        _alp_cmake_project_propagate_result("${arg_NAME}")
        return()
    endif()

    alp_add_git_repository(
        ${arg_NAME} URL "${arg_URL}" COMMITISH "${arg_COMMITISH}" DO_NOT_ADD_SUBPROJECT)
    _alp_setup_cmake_project_from_source(
        "${arg_NAME}" "${${arg_NAME}_SOURCE_DIR}" "${_source_signature}" _cmake_arguments)
    _alp_cmake_project_propagate_result("${arg_NAME}")
endfunction()

function(_alp_cmake_project_archive_source_dir arg_NAME arg_SHA256 output_var)
    if(NOT arg_NAME MATCHES "^[A-Za-z0-9_.+-]+$"
            OR arg_NAME STREQUAL "." OR arg_NAME STREQUAL "..")
        message(FATAL_ERROR
            "[alp] ${arg_NAME}: archive dependency names may only contain letters, "
            "digits, '_', '.', '+', and '-'")
    endif()

    if(NOT DEFINED ALP_EXTERN_DIR OR ALP_EXTERN_DIR STREQUAL "")
        set(_extern_dir "extern")
    else()
        set(_extern_dir "${ALP_EXTERN_DIR}")
    endif()

    cmake_path(IS_ABSOLUTE _extern_dir _extern_is_absolute)
    if(_extern_is_absolute)
        message(FATAL_ERROR
            "[alp] ${arg_NAME}: ALP_EXTERN_DIR '${_extern_dir}' must be relative to "
            "CMAKE_SOURCE_DIR ('${CMAKE_SOURCE_DIR}')")
    endif()
    cmake_path(NORMAL_PATH _extern_dir OUTPUT_VARIABLE _normalized_extern_dir)
    if(_normalized_extern_dir STREQUAL ".." OR _normalized_extern_dir MATCHES "^\.\./")
        message(FATAL_ERROR
            "[alp] ${arg_NAME}: ALP_EXTERN_DIR '${_extern_dir}' escapes "
            "CMAKE_SOURCE_DIR ('${CMAKE_SOURCE_DIR}')")
    endif()

    set(_relative_source_dir "${_normalized_extern_dir}/${arg_NAME}_${arg_SHA256}")
    cmake_path(ABSOLUTE_PATH _relative_source_dir
        BASE_DIRECTORY "${CMAKE_SOURCE_DIR}" NORMALIZE OUTPUT_VARIABLE _source_dir)
    set("${output_var}" "${_source_dir}" PARENT_SCOPE)
endfunction()

function(_alp_cmake_project_prepare_archive_source arg_NAME arg_URL arg_SHA256 output_var)
    _alp_cmake_project_archive_source_dir("${arg_NAME}" "${arg_SHA256}" _source_dir)
    get_filename_component(_source_parent "${_source_dir}" DIRECTORY)
    file(MAKE_DIRECTORY "${_source_parent}")

    set(_lock_file "${_source_dir}.lock")
    file(LOCK "${_lock_file}" GUARD FUNCTION TIMEOUT 600 RESULT_VARIABLE _lock_result)
    if(NOT _lock_result STREQUAL "0")
        message(FATAL_ERROR
            "[alp] ${arg_NAME}: could not lock shared archive source "
            "'${_source_dir}': ${_lock_result}")
    endif()

    set(_signature_file "${_source_dir}/.alp_archive_signature")
    set(_source_ready FALSE)
    if(EXISTS "${_signature_file}" AND EXISTS "${_source_dir}/CMakeLists.txt")
        file(READ "${_signature_file}" _installed_signature)
        string(STRIP "${_installed_signature}" _installed_signature)
        if(_installed_signature STREQUAL "SHA256=${arg_SHA256}")
            set(_source_ready TRUE)
        endif()
    endif()

    if(_source_ready)
        message(STATUS "[alp] Using shared archive source for ${arg_NAME}: ${_source_dir}")
    else()
        file(REMOVE_RECURSE "${_source_dir}")
        include(FetchContent)
        string(MAKE_C_IDENTIFIER "alp_${arg_NAME}_${arg_SHA256}" _content_name)
        FetchContent_Declare(${_content_name}
            URL "${arg_URL}"
            URL_HASH "SHA256=${arg_SHA256}"
            DOWNLOAD_EXTRACT_TIMESTAMP FALSE
            SOURCE_DIR "${_source_dir}"
            SOURCE_SUBDIR _alp_archive_no_subdirectory)
        FetchContent_MakeAvailable(${_content_name})

        if(NOT EXISTS "${_source_dir}/CMakeLists.txt")
            message(FATAL_ERROR
                "[alp] ${arg_NAME}: archive '${arg_URL}' does not contain a root CMakeLists.txt")
        endif()
        file(WRITE "${_signature_file}" "SHA256=${arg_SHA256}\n")
    endif()

    set("${output_var}" "${_source_dir}" PARENT_SCOPE)
endfunction()

function(_alp_setup_cmake_project_from_archive arg_NAME arg_URL arg_SHA256 CMAKE_ARGUMENTS_VAR)
    set(_cmake_arguments "${${CMAKE_ARGUMENTS_VAR}}")
    string(LENGTH "${arg_SHA256}" _sha256_length)
    if(NOT _sha256_length EQUAL 64 OR arg_SHA256 MATCHES "[^0-9A-Fa-f]")
        message(FATAL_ERROR
            "[alp] alp_setup_cmake_project(): SHA256 must be 64 hexadecimal characters")
    endif()
    string(TOLOWER "${arg_SHA256}" _sha256)

    set(_source_signature "ARCHIVE\nURL=${arg_URL}\nSHA256=${_sha256}")
    _alp_cmake_project_cache_key(
        "${arg_NAME}" "${_source_signature}" "${_cmake_arguments}" _key)
    _alp_cmake_project_use_cached_install("${arg_NAME}" "${_key}" _cache_hit)
    if(_cache_hit)
        _alp_cmake_project_propagate_result("${arg_NAME}")
        return()
    endif()

    _alp_cmake_project_prepare_archive_source(
        "${arg_NAME}" "${arg_URL}" "${_sha256}" _src_dir)

    _alp_setup_cmake_project_from_source(
        "${arg_NAME}" "${_src_dir}" "${_source_signature}" _cmake_arguments)
    _alp_cmake_project_propagate_result("${arg_NAME}")
endfunction()

function(alp_setup_cmake_project arg_NAME)
    set(options)
    set(oneValueArgs URL COMMITISH SHA256)
    set(multiValueArgs CMAKE_ARGUMENTS)
    cmake_parse_arguments(PARSE_ARGV 1 arg "${options}" "${oneValueArgs}" "${multiValueArgs}")

    if(arg_UNPARSED_ARGUMENTS)
        message(FATAL_ERROR
            "[alp] alp_setup_cmake_project(): unknown arguments: ${arg_UNPARSED_ARGUMENTS}")
    endif()
    if(arg_KEYWORDS_MISSING_VALUES)
        message(FATAL_ERROR
            "[alp] alp_setup_cmake_project(): arguments require values: "
            "${arg_KEYWORDS_MISSING_VALUES}")
    endif()
    if(NOT arg_NAME OR NOT arg_URL)
        message(FATAL_ERROR
            "[alp] alp_setup_cmake_project() needs: <name> URL <url> and exactly one of "
            "COMMITISH <revision> or SHA256 <checksum>")
    endif()
    set(_has_commitish FALSE)
    if(DEFINED arg_COMMITISH)
        set(_has_commitish TRUE)
    endif()
    set(_has_sha256 FALSE)
    if(DEFINED arg_SHA256)
        set(_has_sha256 TRUE)
    endif()
    if("${_has_commitish}" STREQUAL "${_has_sha256}")
        message(FATAL_ERROR
            "[alp] alp_setup_cmake_project(): specify exactly one of COMMITISH or SHA256")
    endif()

    if(_has_commitish)
        _alp_setup_cmake_project_from_git(
            "${arg_NAME}" "${arg_URL}" "${arg_COMMITISH}" arg_CMAKE_ARGUMENTS)
    else()
        _alp_setup_cmake_project_from_archive(
            "${arg_NAME}" "${arg_URL}" "${arg_SHA256}" arg_CMAKE_ARGUMENTS)
    endif()
    _alp_cmake_project_propagate_result("${arg_NAME}")
endfunction()

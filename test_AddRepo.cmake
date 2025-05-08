cmake_minimum_required (VERSION 3.22 FATAL_ERROR)

###############################################################################
#  AddRepoTests.cmake  – tests for alp_add_git_repository
#
#  The script must sit in the same directory as AddRepo.cmake.
#  Run it with:   cmake -P AddRepoTests.cmake
###############################################################################

find_package (Git 2.22 REQUIRED)

include ("${CMAKE_CURRENT_LIST_DIR}/AddRepo.cmake")

# ---------------------------------------------------------------------------#
#  Constants – you only need to touch these if the repo/.. changes           #
# ---------------------------------------------------------------------------#
set (REPO_URL  "https://github.com/AlpineMapsOrgDependencies/cmake_scripts_test_repo.git")

# where every test puts its clones
set (TEST_ROOT "test_dir")

# ---------------------------------------------------------------------------#
#  Small helpers                                                             #
# ---------------------------------------------------------------------------#
function (assert_equal actual expected msg)
    if (NOT "${actual}" STREQUAL "${expected}")
        message (FATAL_ERROR "ASSERT FAILED: ${msg}\n  expected: '${expected}'\n  got:      '${actual}'")
    endif()
endfunction()

function (assert_different a b msg)
    if ("${a}" STREQUAL "${b}")
        message (FATAL_ERROR "ASSERT FAILED: ${msg} – the two values are identical ('${a}')")
    endif()
endfunction()

function (alp_add_git_repository_conditional_deep out_var clone_kind)
    set (tmp)
    if (clone_kind STREQUAL "deep")
        list (APPEND tmp DEEP_CLONE)
    endif()
    set ("${out_var}" "${tmp}" PARENT_SCOPE)
endfunction()


function (repo_is_shallow repo result_var)
    execute_process (
        COMMAND "${GIT_EXECUTABLE}" rev-parse --is-shallow-repository
        WORKING_DIRECTORY "${repo}"
        OUTPUT_VARIABLE _out
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )
    set ("${result_var}" "${_out}" PARENT_SCOPE)
endfunction()

function (fetch_head_timestamp repo result_var)
    set (f "${repo}/.git/FETCH_HEAD")
    if (EXISTS "${f}")
        file (TIMESTAMP "${f}" _ts)
    else()
        set (_ts "NONE")
    endif()
    set ("${result_var}" "${_ts}" PARENT_SCOPE)
endfunction()

# ---------------------------------------------------------------------------
#  Assert that a repository (incl. all submodules) is clean
# ---------------------------------------------------------------------------
function (verify_working_tree_clean repo commit_hash)
    # 1. Is the repo at the expected commit?
    execute_process(
        COMMAND "${GIT_EXECUTABLE}" rev-parse HEAD
        WORKING_DIRECTORY "${repo}"
        OUTPUT_VARIABLE actual_hash
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )
    if (NOT "${actual_hash}" STREQUAL "${commit_hash}")
        message(FATAL_ERROR
            "ASSERT FAILED: ${repo} is at wrong commit\n  expected: ${commit_hash}\n  got:      ${actual_hash}")
    endif()

    # 2. Is the super‑project clean?
    execute_process(
        COMMAND       "${GIT_EXECUTABLE}" status --porcelain --untracked-files=no
        WORKING_DIRECTORY "${repo}"
        OUTPUT_VARIABLE status_lines
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )
    if (NOT status_lines STREQUAL "")
        message(FATAL_ERROR
            "ASSERT FAILED: super‑project ${repo} is *dirty* after checkout:\n${status_lines}")
    endif()

    # 3. Are all submodules clean and at the recorded commit?
    #
    #    `git submodule status --recursive`
    #      output lines start with...
    #        " "  → ok & clean
    #        "-"  → submodule not initialised
    #        "+"  → checked‑out commit differs from recorded one
    #        "U"  → merge conflicts
    execute_process(
        COMMAND       "${GIT_EXECUTABLE}" submodule status --recursive
        WORKING_DIRECTORY "${repo}"
        OUTPUT_VARIABLE sm_status
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )
    string(REGEX MATCHALL "^[^ ]" problems "${sm_status}")   # any line not starting with space?
    if (problems)
        message(FATAL_ERROR
            "ASSERT FAILED: submodules of ${repo} are not clean or not at the correct commit:\n${sm_status}")
    endif()
endfunction()

function (stay_on_branch repo expected_branch)
    execute_process (
        COMMAND "${GIT_EXECUTABLE}" rev-parse --abbrev-ref HEAD
        WORKING_DIRECTORY "${repo}"
        OUTPUT_VARIABLE cur_branch
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )
    assert_equal ("${cur_branch}" "${expected_branch}"
                  "repository ${repo} unexpectedly left branch '${expected_branch}' (now '${cur_branch}')")
endfunction()

# ---------------------------------------------------------------------------#
#  One helper that *runs* alp_add_git_repository and performs common checks  #
# ---------------------------------------------------------------------------#
function (run_one_clone                               # --- inputs -----------
          test_label                                  #   human‑readable label
          clone_kind                                  #   deep | shallow
          initial_commitish                           #
          second_commitish                            #   what to checkout the 2nd time
          expect_fetch_second                         #   TRUE/FALSE
          expect_branch_after_second                  #   ""  → don’t care
          expected_hash_after_first_commitish
          expected_hash_after_second_commitish)        # ----------------------
    # build argument list --------------------------------------------------#
    alp_add_git_repository_conditional_deep (DEPTH_ARGS "${clone_kind}")

    # put everything for this clone into its own directory
    set (repo_dir "${TEST_ROOT}/${test_label}_${clone_kind}")
    file (MAKE_DIRECTORY "${repo_dir}")       # parent must exist
    set (ALP_EXTERN_DIR "test_dir")           # AddRepo.cmake uses this

    # -------------------------------------------------------------------#
    # 1st call – clone/check‑out                                          #
    # -------------------------------------------------------------------#
    alp_add_git_repository (${test_label}_${clone_kind}
        URL                        "${REPO_URL}"
        COMMITISH                  "${initial_commitish}"
        DESTINATION_PATH           "${repo_dir}"
        DO_NOT_ADD_SUBPROJECT
        PRIVATE_DO_NOT_CHECK_FOR_SCRIPT_UPDATES
        ${DEPTH_ARGS}
    )
    verify_working_tree_clean ("${repo_dir}" ${expected_hash_after_first_commitish})
    return()

    # deep / shallow assertions
    repo_is_shallow                ("${repo_dir}" repo_shallow)
    repo_is_shallow                ("${repo_dir}/test_submodule" sub_shallow)

    if ("${clone_kind}" STREQUAL "deep")
        assert_equal ("${repo_shallow}" "false"  "main clone should be deep for ${test_label}")
        assert_equal ("${sub_shallow}"  "false"  "submodule should be deep for ${test_label}")
    else()
        assert_equal ("${repo_shallow}" "true"   "main clone should be shallow for ${test_label}")
        assert_equal ("${sub_shallow}"  "true"   "submodule should be shallow for ${test_label}")
    endif()

    # -------------------------------------------------------------------#
    # 2nd call – whatever follow‑up the scenario asks for                #
    # -------------------------------------------------------------------#
    fetch_head_timestamp           ("${repo_dir}" ts_before)
    execute_process (COMMAND "${CMAKE_COMMAND}" -E sleep 1)   # make ‘diff’ measurable

    alp_add_git_repository (${test_label}_${clone_kind}
        URL                        "${REPO_URL}"
        COMMITISH                  "${second_commitish}"
        DESTINATION_PATH           "${repo_dir}"
        DO_NOT_ADD_SUBPROJECT
        PRIVATE_DO_NOT_CHECK_FOR_SCRIPT_UPDATES
        ${DEPTH_ARGS}
    )
    verify_working_tree_clean ("${repo_dir}" ${expected_hash_after_second_commitish})

    fetch_head_timestamp           ("${repo_dir}" ts_after)

    if (expect_fetch_second)
        assert_different ("${ts_before}" "${ts_after}"
                          "${test_label} (${clone_kind}): expected a fetch on 2nd call, but FETCH_HEAD did not change")
    else()
        assert_equal     ("${ts_before}" "${ts_after}"
                          "${test_label} (${clone_kind}): expected NO fetch on 2nd call, but FETCH_HEAD changed")
    endif()

    # optional branch check (used only in scenario 4)
    if (NOT "${expect_branch_after_second}" STREQUAL "")
        stay_on_branch ("${repo_dir}" "${expect_branch_after_second}")
    endif()

    verify_working_tree_clean ("${repo_dir}" ${expected_hash_after_second_commitish})

    message (STATUS "✓  ${test_label} (${clone_kind}) passed.")
endfunction()

# ---------------------------------------------------------------------------#
#                              THE TEST CASES                                #
# ---------------------------------------------------------------------------#
file (REMOVE_RECURSE "${TEST_ROOT}")          # clean slate

# ──────────  TEST 1 : origin/main fetch behaviour  ──────────
message (STATUS "──────────  TEST 1 : origin/main fetch behaviour  ──────────")
run_one_clone (t1 deep    "origin/main" "origin/main"  TRUE  "" c1e1afe512bbd4deba271477609de2b7b2ac91ab c1e1afe512bbd4deba271477609de2b7b2ac91ab)
run_one_clone (t1 shallow "origin/main" "origin/main"  TRUE  "" c1e1afe512bbd4deba271477609de2b7b2ac91ab c1e1afe512bbd4deba271477609de2b7b2ac91ab)

# ──────────  TEST 2 : tag fetch behaviour  (test_tag) ──────────
message (STATUS "──────────  TEST 2 : tag fetch behaviour          ──────────")
run_one_clone (t2 deep    "test_tag"  "test_tag"   FALSE "" 1732c1f95f8ea0e2e370eefcf60c83c247f9b39b 1732c1f95f8ea0e2e370eefcf60c83c247f9b39b)
run_one_clone (t2 shallow "test_tag"  "test_tag"   FALSE "" 1732c1f95f8ea0e2e370eefcf60c83c247f9b39b 1732c1f95f8ea0e2e370eefcf60c83c247f9b39b)

# ──────────  TEST 3 : commit → tag (fetch only for shallow) ──────────
message (STATUS "──────────  TEST 3 : commit → tag (fetch only for shallow)")
run_one_clone (t3 deep    "b23b256f8effc50f512504dd282f534c0699ddec" "test_tag" FALSE "" b23b256f8effc50f512504dd282f534c0699ddec 1732c1f95f8ea0e2e370eefcf60c83c247f9b39b)
run_one_clone (t3 shallow "b23b256f8effc50f512504dd282f534c0699ddec" "test_tag" TRUE  "" b23b256f8effc50f512504dd282f534c0699ddec 1732c1f95f8ea0e2e370eefcf60c83c247f9b39b)

# ──────────  TEST 4 : staying on branch ‘main’  ──────────
message (STATUS "──────────  TEST 4 : staying on branch ‘main’     ──────────")
run_one_clone (t4 deep    "main"    "test_tag"    FALSE "main" c1e1afe512bbd4deba271477609de2b7b2ac91ab c1e1afe512bbd4deba271477609de2b7b2ac91ab)
run_one_clone (t4 deep    "main"    "origin/main" FALSE "main" c1e1afe512bbd4deba271477609de2b7b2ac91ab c1e1afe512bbd4deba271477609de2b7b2ac91ab)
run_one_clone (t4 deep    "main"    "b23b256f8effc50f512504dd282f534c0699ddec" FALSE "main" c1e1afe512bbd4deba271477609de2b7b2ac91ab c1e1afe512bbd4deba271477609de2b7b2ac91ab)

# ──────────  TEST 5 : tag fetch behaviour  (annotated_tag) ──────────
message (STATUS "──────────  TEST 5 : annotated_tag fetch behaviour          ──────────")
run_one_clone (t5 deep    "annotated_tag"  "annotated_tag"   FALSE "" 9b2e623fe2018b34af4a6883384550959f8087b0 9b2e623fe2018b34af4a6883384550959f8087b0)
run_one_clone (t5 shallow "annotated_tag"  "annotated_tag"   FALSE "" 9b2e623fe2018b34af4a6883384550959f8087b0 9b2e623fe2018b34af4a6883384550959f8087b0)

# ──────────  TEST 6 : tag fetch behaviour  (lightweight_tag) ──────────
message (STATUS "──────────  TEST 6 : lightweight_tag fetch behaviour        ──────────")
run_one_clone (t6 deep    "lightweight_tag"  "lightweight_tag"   FALSE "" b23b256f8effc50f512504dd282f534c0699ddec b23b256f8effc50f512504dd282f534c0699ddec)
run_one_clone (t6 shallow "lightweight_tag"  "lightweight_tag"   FALSE "" b23b256f8effc50f512504dd282f534c0699ddec b23b256f8effc50f512504dd282f534c0699ddec)

# ──────────  TEST 7 : commit → tag (fetch only for shallow) ──────────
message (STATUS "──────────  TEST 7 : tag → tag (fetch only for shallow)")
run_one_clone (t7 deep    "lightweight_tag" "annotated_tag" FALSE "" b23b256f8effc50f512504dd282f534c0699ddec 9b2e623fe2018b34af4a6883384550959f8087b0)
run_one_clone (t7 shallow "lightweight_tag" "annotated_tag" TRUE  "" b23b256f8effc50f512504dd282f534c0699ddec 9b2e623fe2018b34af4a6883384550959f8087b0)

# ──────────  TEST 8 : commit → tag (fetch only for shallow) ──────────
message (STATUS "──────────  TEST 8 : tag → tag (fetch only for shallow)")
run_one_clone (t8 deep    "annotated_tag" "lightweight_tag" FALSE "" 9b2e623fe2018b34af4a6883384550959f8087b0 b23b256f8effc50f512504dd282f534c0699ddec)
run_one_clone (t8 shallow "annotated_tag" "lightweight_tag" TRUE  "" 9b2e623fe2018b34af4a6883384550959f8087b0 b23b256f8effc50f512504dd282f534c0699ddec)


message (STATUS "================================================================")
message (STATUS "🎉  ALL AddRepo.cmake tests finished successfully")
message (STATUS "================================================================")

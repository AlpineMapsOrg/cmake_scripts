#!/usr/bin/env python3
"""Hermetic functional tests for AddRepo.cmake."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
ADD_REPO = ROOT / "AddRepo.cmake"


def run(argv, *, cwd=None, check=True, env=None):
    result = subprocess.run(
        [str(arg) for arg in argv], cwd=cwd, env=env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if check and result.returncode:
        raise AssertionError(
            f"command failed ({result.returncode}): {' '.join(map(str, argv))}\n{result.stdout}")
    return result


def git(cwd, *args, check=True):
    return run(("git", *args), cwd=cwd, check=check)


def write(path: Path, content: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def configure_project(source: Path, build: Path, url: str, revision: str,
                      *, destination="deps/dep", options=(), extra="", expect_ok=True):
    content = f"""cmake_minimum_required(VERSION 3.25)
project(add_repo_case NONE)
include([==[{ADD_REPO}]==])
alp_add_git_repository(dep
    URL [==[{url}]==]
    COMMITISH [==[{revision}]==]
    DESTINATION_PATH [==[{destination}]==]
    PRIVATE_DO_NOT_CHECK_FOR_SCRIPT_UPDATES
    {' '.join(options)})
file(WRITE "${{CMAKE_BINARY_DIR}}/source-dir.txt" "${{dep_SOURCE_DIR}}")
{extra}
"""
    write(source / "CMakeLists.txt", content)
    result = run(("cmake", "-S", source, "-B", build), check=False)
    if expect_ok and result.returncode:
        raise AssertionError(f"configure unexpectedly failed:\n{result.stdout}")
    if not expect_ok and not result.returncode:
        raise AssertionError(f"configure unexpectedly succeeded:\n{result.stdout}")
    return result


def assert_managed(repo: Path, expected: str, *, shallow=None, submodules=False):
    head = git(repo, "rev-parse", "HEAD").stdout.strip()
    assert head == expected, (head, expected)
    assert git(repo, "symbolic-ref", "-q", "HEAD", check=False).returncode == 1
    assert git(repo, "status", "--porcelain", "--untracked-files=all").stdout == ""
    status = git(repo, "submodule", "status", "--recursive").stdout
    assert not any(line[:1] in "-+U" for line in status.splitlines()), status
    if submodules:
        assert status.strip(), "expected a submodule"
    if shallow is not None:
        actual = git(repo, "rev-parse", "--is-shallow-repository").stdout.strip()
        assert actual == ("true" if shallow else "false"), actual
        if submodules:
            sub = repo / "modules" / "sub"
            actual = git(sub, "rev-parse", "--is-shallow-repository").stdout.strip()
            assert actual == ("true" if shallow else "false"), actual
            leaf = sub / "nested" / "leaf"
            actual = git(leaf, "rev-parse", "--is-shallow-repository").stdout.strip()
            assert actual == ("true" if shallow else "false"), actual


def create_remote(parent: Path, name: str):
    bare = parent / f"{name}.git"
    work = parent / f"{name}-work"
    git(parent, "init", "--bare", bare)
    git(parent, "init", "-b", "main", work)
    git(work, "config", "user.name", "AddRepo Tests")
    git(work, "config", "user.email", "addrepo-tests@example.invalid")
    git(work, "remote", "add", "origin", bare.as_uri())
    return bare, work


def create_fixtures(root: Path):
    remotes = root / "fixture remotes;list"
    remotes.mkdir()

    leaf_bare, leaf_work = create_remote(remotes, "leaf")
    write(leaf_work / "leaf.txt", "nested leaf\n")
    git(leaf_work, "add", ".")
    git(leaf_work, "commit", "-m", "leaf base")
    git(leaf_work, "push", "-u", "origin", "main")
    git(leaf_bare, "symbolic-ref", "HEAD", "refs/heads/main")

    unavailable_bare, unavailable_work = create_remote(remotes, "unavailable")
    write(unavailable_work / "missing.txt", "unavailable commit\n")
    git(unavailable_work, "add", ".")
    git(unavailable_work, "commit", "-m", "unavailable commit")
    unavailable_commit = git(unavailable_work, "rev-parse", "HEAD").stdout.strip()
    git(unavailable_work, "push", "-u", "origin", "main")
    git(unavailable_bare, "symbolic-ref", "HEAD", "refs/heads/main")

    sub_bare, sub_work = create_remote(remotes, "sub")
    write(sub_work / "value.txt", "submodule one\n")
    git(sub_work, "add", ".")
    git(sub_work, "commit", "-m", "submodule base")
    git(sub_work, "-c", "protocol.file.allow=always", "submodule", "add",
        leaf_bare.as_uri(), "nested/leaf")
    git(sub_work, "commit", "-am", "add nested submodule")
    sub_commit = git(sub_work, "rev-parse", "HEAD").stdout.strip()
    git(sub_work, "push", "-u", "origin", "main")
    git(sub_bare, "symbolic-ref", "HEAD", "refs/heads/main")

    main_bare, main_work = create_remote(remotes, "main")
    write(main_work / "CMakeLists.txt", """cmake_minimum_required(VERSION 3.25)
project(add_repo_dependency NONE)
get_directory_property(_is_system SYSTEM)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/added.txt"
    "system=${_is_system}\\nsource=${CMAKE_CURRENT_SOURCE_DIR}\\n")
""")
    write(main_work / "value.txt", "base\n")
    git(main_work, "add", ".")
    git(main_work, "commit", "-m", "base")
    base = git(main_work, "rev-parse", "HEAD").stdout.strip()
    git(main_work, "tag", "lightweight")
    git(main_work, "tag", "-a", "annotated", "-m", "annotated tag")
    git(main_work, "tag", "release/with-slash")
    git(main_work, "tag", "release;with-list-separator")

    write(main_work / "value.txt", "plain update\n")
    git(main_work, "commit", "-am", "plain update")
    plain_update = git(main_work, "rev-parse", "HEAD").stdout.strip()
    git(main_work, "tag", "plain-update")
    git(main_work, "tag", "-a", "plain-update-annotated", "-m", "plain update annotated")

    git(main_work, "-c", "protocol.file.allow=always", "submodule", "add",
        sub_bare.as_uri(), "modules/sub")
    git(main_work, "commit", "-am", "add submodule")
    with_submodule = git(main_work, "rev-parse", "HEAD").stdout.strip()
    git(main_work, "tag", "with-submodule")
    git(main_work, "tag", "-a", "with-submodule-annotated", "-m", "with submodule annotated")

    git(main_work, "config", "-f", ".gitmodules", "submodule.modules/sub.url",
        unavailable_bare.as_uri())
    git(main_work, "update-index", "--cacheinfo",
        f"160000,{unavailable_commit},modules/sub")
    git(main_work, "add", ".gitmodules")
    git(main_work, "commit", "-m", "invalid submodule URL")
    invalid_submodule = git(main_work, "rev-parse", "HEAD").stdout.strip()
    git(main_work, "tag", "invalid-submodule")
    git(main_work, "tag", "-a", "invalid-submodule-annotated", "-m", "invalid submodule annotated")

    git(main_work, "config", "-f", ".gitmodules", "submodule.modules/sub.url",
        sub_bare.as_uri())
    git(main_work, "update-index", "--cacheinfo", f"160000,{sub_commit},modules/sub")
    write(main_work / "value.txt", "tip\n")
    git(main_work, "add", ".")
    git(main_work, "commit", "-m", "main tip")
    tip = git(main_work, "rev-parse", "HEAD").stdout.strip()
    git(main_work, "push", "-u", "origin", "main", "--tags")
    git(main_bare, "symbolic-ref", "HEAD", "refs/heads/main")
    shutil.rmtree(unavailable_bare)

    return {
        "url": main_bare.as_uri(), "remote": main_bare,
        "sub_remote": sub_bare, "leaf_remote": leaf_bare,
        "base": base, "plain_update": plain_update, "with_submodule": with_submodule,
        "invalid_submodule": invalid_submodule, "tip": tip, "sub_commit": sub_commit,
    }


def test_fixed_revisions(root: Path, fixture):
    cases = (
        ("lightweight", fixture["base"]),
        ("annotated", fixture["base"]),
        ("release/with-slash", fixture["base"]),
        ("release;with-list-separator", fixture["base"]),
        (fixture["base"], fixture["base"]),
    )
    for index, (revision, expected) in enumerate(cases):
        source = root / f"fixed-{index} source"
        repo = source / "deps" / "dep"
        configure_project(source, root / f"fixed-{index}-build", fixture["url"], revision,
                          options=("DO_NOT_ADD_SUBPROJECT",))
        assert_managed(repo, expected, shallow=True)

    remote_off = fixture["remote"].with_name("fixed.offline")
    fixture["remote"].rename(remote_off)
    try:
        for index, (revision, expected) in enumerate(cases):
            source = root / f"fixed-{index} source"
            result = configure_project(source, root / f"fixed-{index}-offline-build",
                                       fixture["url"], revision,
                                       options=("DO_NOT_ADD_SUBPROJECT",))
            assert "fetching it" not in result.stdout
            assert_managed(source / "deps" / "dep", expected, shallow=True)
    finally:
        remote_off.rename(fixture["remote"])


def test_submodules_and_offline(root: Path, fixture):
    cases = ("with-submodule", "with-submodule-annotated", fixture["with_submodule"])
    for index, revision in enumerate(cases):
        source = root / f"submodule-{index}-source"
        repo = source / "deps" / "dep"
        configure_project(source, root / f"submodule-{index}-build-1",
                          fixture["url"], revision, options=("DO_NOT_ADD_SUBPROJECT",))
        assert_managed(repo, fixture["with_submodule"], shallow=True, submodules=True)

    remote_off = fixture["remote"].with_name("main.offline")
    sub_off = fixture["sub_remote"].with_name("sub.offline")
    leaf_off = fixture["leaf_remote"].with_name("leaf.offline")
    fixture["remote"].rename(remote_off)
    fixture["sub_remote"].rename(sub_off)
    fixture["leaf_remote"].rename(leaf_off)
    try:
        for index, revision in enumerate(cases):
            source = root / f"submodule-{index}-source"
            result = configure_project(source, root / f"submodule-{index}-build-2",
                                       fixture["url"], revision,
                                       options=("DO_NOT_ADD_SUBPROJECT",))
            assert "fetching it" not in result.stdout
            assert_managed(source / "deps" / "dep", fixture["with_submodule"],
                           shallow=True, submodules=True)
    finally:
        remote_off.rename(fixture["remote"])
        sub_off.rename(fixture["sub_remote"])
        leaf_off.rename(fixture["leaf_remote"])


def test_fixed_updates(root: Path, fixture):
    groups = (
        ("plain", ("plain-update", "plain-update-annotated", fixture["plain_update"]),
         fixture["plain_update"], False),
        ("sub", ("with-submodule", "with-submodule-annotated", fixture["with_submodule"]),
         fixture["with_submodule"], True),
    )
    prepared = []
    for group, revisions, expected, has_submodules in groups:
        for index, revision in enumerate(revisions):
            source = root / f"fixed-update-{group}-{index}-source"
            repo = source / "deps" / "dep"
            configure_project(source, root / f"fixed-update-{group}-{index}-build-1",
                              fixture["url"], "annotated",
                              options=("DO_NOT_ADD_SUBPROJECT",))
            result = configure_project(source, root / f"fixed-update-{group}-{index}-build-2",
                                       fixture["url"], revision,
                                       options=("DO_NOT_ADD_SUBPROJECT",))
            assert "is not cached; fetching it" in result.stdout
            assert_managed(repo, expected, shallow=True, submodules=has_submodules)
            prepared.append((group, index, source, repo))

    # The base commit remains cached in every repository. Updating back to its
    # SHA must work without either remote and must remove old submodules cleanly.
    remote_off = fixture["remote"].with_name("update-main.offline")
    sub_off = fixture["sub_remote"].with_name("update-sub.offline")
    fixture["remote"].rename(remote_off)
    fixture["sub_remote"].rename(sub_off)
    try:
        for group, index, source, repo in prepared:
            result = configure_project(source, root / f"fixed-update-{group}-{index}-build-3",
                                       fixture["url"], fixture["base"],
                                       options=("DO_NOT_ADD_SUBPROJECT",))
            assert "fetching it" not in result.stdout
            assert_managed(repo, fixture["base"], shallow=True)
    finally:
        remote_off.rename(fixture["remote"])
        sub_off.rename(fixture["sub_remote"])


def test_remote_tracking_fallback(root: Path, fixture):
    source = root / "moving-source"
    repo = source / "deps" / "dep"
    configure_project(source, root / "moving-build-1", fixture["url"], "origin/main",
                      options=("DO_NOT_ADD_SUBPROJECT",))
    assert_managed(repo, fixture["tip"], shallow=True, submodules=True)

    result = configure_project(source, root / "moving-build-2", fixture["url"],
                               "origin/main", options=("DO_NOT_ADD_SUBPROJECT",))
    assert "fetching moving revision 'origin/main'" in result.stdout
    assert_managed(repo, fixture["tip"], shallow=True, submodules=True)

    remote_off = fixture["remote"].with_name("moving.offline")
    fixture["remote"].rename(remote_off)
    try:
        result = configure_project(source, root / "moving-build-3", fixture["url"],
                                   "origin/main", options=("DO_NOT_ADD_SUBPROJECT",))
        assert "reusing cached commit" in " ".join(result.stdout.split())
        assert_managed(repo, fixture["tip"], shallow=True, submodules=True)
    finally:
        remote_off.rename(fixture["remote"])


def test_protection_and_failures(root: Path, fixture):
    dirty_source = root / "dirty-source"
    dirty_repo = dirty_source / "deps" / "dep"
    configure_project(dirty_source, root / "dirty-build-1", fixture["url"], "lightweight",
                      options=("DO_NOT_ADD_SUBPROJECT",))
    write(dirty_repo / "untracked.txt", "do not delete\n")
    result = configure_project(dirty_source, root / "dirty-build-2", fixture["url"],
                               "annotated", options=("DO_NOT_ADD_SUBPROJECT",), expect_ok=False)
    assert "repository is dirty" in result.stdout
    assert (dirty_repo / "untracked.txt").read_text() == "do not delete\n"

    git(dirty_repo, "clean", "-f")
    git(dirty_repo, "switch", "-c", "developer-work")
    remote_off = fixture["remote"].with_name("developer.offline")
    fixture["remote"].rename(remote_off)
    try:
        result = configure_project(dirty_source, root / "developer-build", fixture["url"],
                                   "annotated", options=("DO_NOT_ADD_SUBPROJECT",))
        assert "developer-managed" in result.stdout and "was NOT checked out" in result.stdout
        assert git(dirty_repo, "branch", "--show-current").stdout.strip() == "developer-work"
    finally:
        remote_off.rename(fixture["remote"])

    invalid_source = root / "invalid-destination"
    result = configure_project(invalid_source, root / "invalid-build", fixture["url"],
                               "lightweight", destination="../escape",
                               options=("DO_NOT_ADD_SUBPROJECT",), expect_ok=False)
    assert "escapes CMAKE_SOURCE_DIR" in result.stdout

    occupied_source = root / "occupied-source"
    write(occupied_source / "occupied" / "keep.txt", "keep\n")
    result = configure_project(occupied_source, root / "occupied-build", fixture["url"],
                               "lightweight", destination="occupied",
                               options=("DO_NOT_ADD_SUBPROJECT",), expect_ok=False)
    assert "refusing to overwrite" in result.stdout
    assert (occupied_source / "occupied" / "keep.txt").read_text() == "keep\n"

    mismatch_source = root / "mismatch-source"
    mismatch_repo = mismatch_source / "deps" / "dep"
    configure_project(mismatch_source, root / "mismatch-build-1", fixture["url"],
                      "lightweight", options=("DO_NOT_ADD_SUBPROJECT",))
    git(mismatch_repo, "remote", "set-url", "origin", "file:///definitely/wrong")
    result = configure_project(mismatch_source, root / "mismatch-build-2", fixture["url"],
                               "lightweight", options=("DO_NOT_ADD_SUBPROJECT",), expect_ok=False)
    assert "validating origin URL failed" in result.stdout

    deleted_source = root / "deleted-submodule-source"
    deleted_repo = deleted_source / "deps" / "dep"
    configure_project(deleted_source, root / "deleted-submodule-build-1", fixture["url"],
                      "with-submodule", options=("DO_NOT_ADD_SUBPROJECT",))
    shutil.rmtree(deleted_repo / "modules" / "sub")
    result = configure_project(deleted_source, root / "deleted-submodule-build-2",
                               fixture["url"], "with-submodule",
                               options=("DO_NOT_ADD_SUBPROJECT",), expect_ok=False)
    assert "repository is dirty" in result.stdout


def test_subproject_options(root: Path, fixture):
    source = root / "subproject-source"
    repo = source / "custom extern;list" / "dep"
    configure_project(source, root / "system-build", fixture["url"], "lightweight",
                      destination="custom extern;list/dep")
    marker = root / "system-build" / "alp_external" / "dep" / "added.txt"
    assert "system=TRUE" in marker.read_text()
    assert (root / "system-build" / "source-dir.txt").read_text() == str(repo)

    source2 = root / "not-system-source"
    configure_project(source2, root / "not-system-build", fixture["url"], "lightweight",
                      options=("NOT_SYSTEM",))
    marker = root / "not-system-build" / "alp_external" / "dep" / "added.txt"
    assert "system=TRUE" not in marker.read_text()

    source3 = root / "not-added-source"
    configure_project(source3, root / "not-added-build", fixture["url"], "lightweight",
                      options=("DO_NOT_ADD_SUBPROJECT",))
    assert not (root / "not-added-build" / "alp_external" / "dep" / "added.txt").exists()

    default_source = root / "default-source"
    content = f"""cmake_minimum_required(VERSION 3.25)
project(default_destination NONE)
set(ALP_EXTERN_DIR "third party")
include([==[{ADD_REPO}]==])
alp_add_git_repository(default_dep URL [==[{fixture['url']}]==]
    COMMITISH lightweight DO_NOT_ADD_SUBPROJECT
    PRIVATE_DO_NOT_CHECK_FOR_SCRIPT_UPDATES)
file(WRITE "${{CMAKE_BINARY_DIR}}/source-dir.txt" "${{default_dep_SOURCE_DIR}}")
"""
    write(default_source / "CMakeLists.txt", content)
    result = run(("cmake", "-S", default_source, "-B", root / "default-build"), check=False)
    assert result.returncode == 0, result.stdout
    expected = default_source / "third party" / "default_dep"
    assert (root / "default-build" / "source-dir.txt").read_text() == str(expected)
    assert_managed(expected, fixture["base"], shallow=True)


def test_parser_and_revision_failures(root: Path, fixture):
    invalid_jobs_source = root / "invalid-jobs-source"
    write(invalid_jobs_source / "CMakeLists.txt", f"""cmake_minimum_required(VERSION 3.25)
project(invalid_submodule_jobs NONE)
include([==[{ADD_REPO}]==])
""")
    result = run(("cmake", "-S", invalid_jobs_source,
                  "-B", root / "invalid-jobs-build",
                  "-DALP_GIT_SUBMODULE_JOBS=0"), check=False)
    assert result.returncode != 0, result.stdout
    assert "ALP_GIT_SUBMODULE_JOBS must be a positive integer" in result.stdout

    source = root / "parser-source"
    result = configure_project(source, root / "parser-build", fixture["url"], "lightweight",
                               options=("DO_NOT_ADD_SUBPROJECT", "BOGUS_OPTION"), expect_ok=False)
    assert "unknown arguments" in result.stdout

    absolute = root / "absolute-destination"
    result = configure_project(root / "absolute-source", root / "absolute-build",
                               fixture["url"], "lightweight", destination=str(absolute),
                               options=("DO_NOT_ADD_SUBPROJECT",), expect_ok=False)
    assert "must be relative" in result.stdout

    branch_source = root / "local-branch-source"
    branch_repo = branch_source / "deps" / "dep"
    configure_project(branch_source, root / "local-branch-build-1", fixture["url"],
                      "lightweight", options=("DO_NOT_ADD_SUBPROJECT",))
    git(branch_repo, "branch", "local-only", fixture["base"])
    result = configure_project(branch_source, root / "local-branch-build-2", fixture["url"],
                               "local-only", options=("DO_NOT_ADD_SUBPROJECT",), expect_ok=False)
    assert "local branch names are not accepted" in result.stdout


def test_update_check_guards(root: Path, fixture):
    source = root / "update-check-source"
    build = root / "update-check-build"
    content = f"""cmake_minimum_required(VERSION 3.25)
project(update_check_guard NONE)
include([==[{ADD_REPO}]==])
function(alp_check_for_script_updates script_path)
    file(APPEND "${{CMAKE_BINARY_DIR}}/checks.txt" "check\\n")
    alp_add_git_repository(nested URL [==[{fixture['url']}]==]
        COMMITISH lightweight DESTINATION_PATH nested
        DO_NOT_ADD_SUBPROJECT PRIVATE_DO_NOT_CHECK_FOR_SCRIPT_UPDATES)
endfunction()
alp_add_git_repository(first URL [==[{fixture['url']}]==]
    COMMITISH lightweight DESTINATION_PATH first DO_NOT_ADD_SUBPROJECT)
alp_add_git_repository(second URL [==[{fixture['url']}]==]
    COMMITISH lightweight DESTINATION_PATH second DO_NOT_ADD_SUBPROJECT)
"""
    write(source / "CMakeLists.txt", content)
    result = run(("cmake", "-S", source, "-B", build), check=False)
    assert result.returncode == 0, result.stdout
    assert (build / "checks.txt").read_text().splitlines() == ["check"]
    for destination in ("nested", "first", "second"):
        assert_managed(source / destination, fixture["base"], shallow=True)


def test_invalid_submodule(root: Path, fixture):
    cases = ("invalid-submodule", "invalid-submodule-annotated",
             fixture["invalid_submodule"])
    for index, revision in enumerate(cases):
        source = root / f"invalid-submodule-{index}-source"
        result = configure_project(source, root / f"invalid-submodule-{index}-build",
                                   fixture["url"], revision,
                                   options=("DO_NOT_ADD_SUBPROJECT",), expect_ok=False)
        assert "updating recursive submodules failed" in result.stdout

    source = root / "invalid-submodule-update-source"
    configure_project(source, root / "invalid-submodule-update-build-1", fixture["url"],
                      "with-submodule", options=("DO_NOT_ADD_SUBPROJECT",))
    result = configure_project(source, root / "invalid-submodule-update-build-2",
                               fixture["url"], "invalid-submodule",
                               options=("DO_NOT_ADD_SUBPROJECT",), expect_ok=False)
    assert "updating recursive submodules failed" in result.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep-temp", action="store_true")
    args = parser.parse_args()
    temp = Path(tempfile.mkdtemp(prefix="alp-add-repo-tests-"))
    tests = (
        test_fixed_revisions,
        test_submodules_and_offline,
        test_fixed_updates,
        test_remote_tracking_fallback,
        test_protection_and_failures,
        test_subproject_options,
        test_parser_and_revision_failures,
        test_update_check_guards,
        test_invalid_submodule,
    )
    try:
        fixture = create_fixtures(temp)
        for test in tests:
            test(temp, fixture)
            print(f"PASS {test.__name__}")
        print(f"PASS all {len(tests)} AddRepo test groups")
    finally:
        if args.keep_temp:
            print(f"Kept temporary directory: {temp}")
        else:
            shutil.rmtree(temp, ignore_errors=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise

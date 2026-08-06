#!/usr/bin/env python3
"""Authenticated GitHub transport smoke test for AddRepo.cmake."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
URL = os.environ.get(
    "ADDREPO_GITHUB_TEST_URL",
    "git@github.com:AlpineMapsOrgDependencies/cmake_repo_for_tests.git")
REVISION = os.environ.get("ADDREPO_GITHUB_TEST_REVISION", "origin/main")


def main():
    with tempfile.TemporaryDirectory(prefix="alp-add-repo-github-") as tmp:
        source = Path(tmp) / "source"
        build = Path(tmp) / "build"
        source.mkdir()
        (source / "CMakeLists.txt").write_text(f"""cmake_minimum_required(VERSION 3.25)
project(add_repo_github_transport NONE)
include([==[{ROOT / 'AddRepo.cmake'}]==])
alp_add_git_repository(github_fixture
    URL [==[{URL}]==]
    COMMITISH [==[{REVISION}]==]
    DO_NOT_ADD_SUBPROJECT
    PRIVATE_DO_NOT_CHECK_FOR_SCRIPT_UPDATES)
""", encoding="utf-8")
        subprocess.run(("cmake", "-S", source, "-B", build), check=True)
        repo = source / "extern" / "github_fixture"
        shallow = subprocess.check_output(
            ("git", "rev-parse", "--is-shallow-repository"), cwd=repo, text=True).strip()
        if shallow != "true":
            raise SystemExit(f"expected a shallow GitHub clone, got {shallow}")
        subprocess.run(("cmake", "-S", source, "-B", build), check=True)
        print("GitHub shallow clone and moving-ref refresh passed")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Clone Boost and verify its recursive submodule checkout."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
URL = "https://github.com/boostorg/boost.git"
REVISION = "boost-1.88.0"


def git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ("git", *args), cwd=repo, check=check, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def assert_clean(repo: Path) -> None:
    status = git(repo, "status", "--porcelain=v1", "--untracked-files=all").stdout
    if status:
        raise AssertionError(f"repository is not clean: {repo}\n{status}")


def verify_submodules(parent: Path) -> int:
    gitmodules = parent / ".gitmodules"
    if not gitmodules.exists():
        return 0

    configured = git(
        parent, "config", "--file", ".gitmodules", "--get-regexp",
        r"^submodule\..*\.path$", check=False)
    if configured.returncode not in (0, 1):
        raise AssertionError(
            f"could not read submodule paths from {gitmodules}:\n{configured.stdout}")

    count = 0
    for line in configured.stdout.splitlines():
        _, relative_path = line.split(maxsplit=1)
        submodule = parent / relative_path
        if not submodule.is_dir():
            raise AssertionError(f"submodule is not initialized: {submodule}")

        expected = git(parent, "rev-parse", f"HEAD:{relative_path}").stdout.strip()
        actual = git(submodule, "rev-parse", "HEAD").stdout.strip()
        if actual != expected:
            raise AssertionError(
                f"submodule revision mismatch: {submodule}\n"
                f"expected {expected}\nactual   {actual}")

        assert_clean(submodule)
        count += 1 + verify_submodules(submodule)

    return count


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="alp-add-repo-boost-") as tmp:
        source = Path(tmp) / "source"
        build = Path(tmp) / "build"
        source.mkdir()
        (source / "CMakeLists.txt").write_text(f"""cmake_minimum_required(VERSION 3.25)
project(add_repo_boost NONE)
include([==[{ROOT / 'AddRepo.cmake'}]==])
alp_add_git_repository(boost
    URL [==[{URL}]==]
    COMMITISH [==[{REVISION}]==]
    DO_NOT_ADD_SUBPROJECT
    PRIVATE_DO_NOT_CHECK_FOR_SCRIPT_UPDATES)
""", encoding="utf-8")

        cmake_env = os.environ.copy()
        config_count = int(cmake_env.get("GIT_CONFIG_COUNT", "0"))
        cmake_env["GIT_CONFIG_COUNT"] = str(config_count + 1)
        cmake_env[f"GIT_CONFIG_KEY_{config_count}"] = "submodule.fetchJobs"
        cmake_env[f"GIT_CONFIG_VALUE_{config_count}"] = "8"
        subprocess.run(
            ("cmake", "-S", source, "-B", build), check=True, env=cmake_env)
        repo = source / "extern" / "boost"

        head = git(repo, "rev-parse", "HEAD").stdout.strip()
        expected_head = git(repo, "rev-parse", f"{REVISION}^{{commit}}").stdout.strip()
        if head != expected_head:
            raise AssertionError(
                f"Boost revision mismatch: expected {expected_head}, got {head}")
        if git(repo, "symbolic-ref", "-q", "HEAD", check=False).returncode == 0:
            raise AssertionError("Boost HEAD is attached; expected a detached checkout")

        submodule_count = verify_submodules(repo)
        if not submodule_count:
            raise AssertionError("expected Boost to contain initialized submodules")
        assert_clean(repo)

        print(
            f"Boost {REVISION} is clean with {submodule_count} recursive "
            "submodules at their recorded revisions")


if __name__ == "__main__":
    main()

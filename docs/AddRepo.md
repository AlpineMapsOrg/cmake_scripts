# AddRepo.cmake

## Purpose

`AddRepo.cmake` provides `alp_add_git_repository()`, a small alternative to
CMake's `FetchContent` for Git dependencies. It keeps dependency working trees
in a source-tree directory shared by different build directories, checks out a
requested Git revision, updates recursive submodules, and normally makes the
dependency available with `add_subdirectory()`.

The function is also intended to be friendly to a dependency that a developer
has turned into a working repository: when that repository is on a local
branch, the function must not silently move the branch or overwrite work.

This document has two parts:

- **Current behavior** describes the implementation as it exists now. It is not
  a promise that every behavior is desirable.
- **Requirements** define the behavior that a corrected implementation must
  provide. These requirements are the basis for implementation and tests.

## Interface

```cmake
alp_add_git_repository(<name>
    URL <git-url>
    COMMITISH <revision>
    [DESTINATION_PATH <path>]
    [DO_NOT_ADD_SUBPROJECT]
    [NOT_SYSTEM]
    [PRIVATE_DO_NOT_CHECK_FOR_SCRIPT_UPDATES])
```

Example:

```cmake
alp_add_git_repository(glm
    URL https://github.com/g-truc/glm.git
    COMMITISH 1.0.1)
```

### Arguments

| Argument | Meaning |
| --- | --- |
| `<name>` | Logical dependency name. It is also used in the default directory and output variable names. |
| `URL` | URL from which a missing repository, revision, or submodule can be fetched. |
| `COMMITISH` | A tag, commit ID, or remote branch written as `origin/<branch>`. Local branches are not accepted as requested revisions. |
| `DESTINATION_PATH` | Repository path relative to and contained by `CMAKE_SOURCE_DIR`. The default is `${ALP_EXTERN_DIR}/<name>`. |
| `DO_NOT_ADD_SUBPROJECT` | Prepare the repository but do not call `add_subdirectory()`. |
| `NOT_SYSTEM` | Add the subdirectory without CMake's `SYSTEM` flag. Ignored when `DO_NOT_ADD_SUBPROJECT` is set. |
| `PRIVATE_DO_NOT_CHECK_FOR_SCRIPT_UPDATES` | Internal escape hatch that suppresses the self-update check and prevents recursion while the scripts repository itself is obtained. Applications should not normally use this option. |

On return, `<name>_SOURCE_DIR` is set in the caller's scope to the absolute
repository path.

### Cache variables

`ALP_GIT_SUBMODULE_JOBS` controls the maximum number of parallel submodule
clone jobs passed to `git submodule update`. It must be a positive integer and
defaults to `8`.

## Current behavior

The implementation currently does the following:

1. Requires Git 2.22 or newer.
2. Once per CMake process, normally invokes the AlpineMaps CMake-script update
   check. That check manages another Git repository and may access the network.
3. Chooses `${CMAKE_SOURCE_DIR}/${ALP_EXTERN_DIR}/<name>` as the destination;
   `ALP_EXTERN_DIR` defaults to `extern`. `DESTINATION_PATH` replaces this
   relative path.
4. Creates the destination directory and clones into it if `.git` is absent.
5. Uses shallow clones by default and full clones with the (now removed) `DEEP_CLONE` argument.
6. Treats a `COMMITISH` containing a slash, such as `origin/main`, as a moving
   remote ref that must be fetched. This behavior is obsolete and should be removed.
   Only commitish starting with origin/ should be treated as remote tracking.
7. If a fixed revision is already present locally, resolves it to a commit and
   avoids fetching it. If `HEAD` is already that commit, it also avoids the
   checkout.
8. After a checkout, initializes and updates submodules recursively. A shallow
   parent uses shallow submodule update arguments.
9. If a fetch is needed while the repository is detached, checks out the
   requested revision. If the repository is on a local branch, warns and leaves
   the branch in place.
10. Unless disabled, adds the repository as a subdirectory under
    `${CMAKE_BINARY_DIR}/alp_external/<name>`, marked `SYSTEM` by default.

The implementation does not yet reliably satisfy the requirements below. In
particular, the existing test helper returns immediately after its first
checkout, so most of the apparent update, branch, and shallow-clone test cases
are currently not executed.

## Requirements

The words **must**, **must not**, **should**, and **may** are normative.

### R1. Inputs and destination

1. `name`, `URL`, and `COMMITISH` must be non-empty. Unknown or unparsed
   arguments must cause a clear configuration error.
2. The default destination must be
   `${CMAKE_SOURCE_DIR}/${ALP_EXTERN_DIR}/<name>`, with `ALP_EXTERN_DIR`
   defaulting to `extern` when it is unset or empty.
3. `DESTINATION_PATH` must select
   `${CMAKE_SOURCE_DIR}/<DESTINATION_PATH>`. It must be relative and, after
   lexical normalization, must not escape `CMAKE_SOURCE_DIR`. Absolute paths
   and paths containing an escaping `..` component must cause a clear error.
4. The parent directory may be created as necessary.
5. An existing destination must be either an empty directory suitable for a
   clone or a Git working tree. A non-empty, non-Git destination must cause a
   clear error and must not be overwritten.
6. `<name>_SOURCE_DIR` must be returned as an absolute path in the caller's
   scope after the repository has been prepared successfully.

### R2. Required tools and compatibility

1. Git 2.22 or newer must be available.
2. CMake 3.25 or newer must be available.
3. Paths, URLs, names, and revisions must be passed to subprocesses without
   losing spaces or list separators.
   
### R3. Repository types

The behavior distinguishes the following git repository types:
1. An **empty repository** does not exist yet (the directory may exist, but is empty).
2. A **cmake managed repository** is a repository that is detached.
3. A **developer managed repository** is any repository that is not detached.

An empty repository must be cloned using the given `URL` as `origin` (see R6), and the
given `COMMITISH` must be checked out. It then becomes a cmake managed repository.

For cmake managed repositories, the `origin` URL must exist and match the supplied
`URL` argument exactly. The repository must be clean (no untracked files, ignored
files are ok). Otherwise the function fails fatally with a clear message (including
the suggestion to make it a developer repo by making it attached).

If the script encounters a developer managed repository, it produces a meaningful
warning. The message must make it unambiguous that the requested revision was not
checked out, and including the relative destination path. No fetch is needed merely
to discover that `HEAD` is attached. All other git commands are skipped.
Developer repositories are an exception to R4-R8.

### R4. Revision classes

The behavior depends on the requested revision:

1. A **fixed revision** is a commit ID or tag. Commit IDs may be full or an
   unambiguous abbreviation. Tags may be lightweight or annotated and may
   contain `/`; annotated tags must be peeled to their commit before comparison
   with `HEAD`.
2. An **remote-tracking revision** is written as `origin/<branch>`.
   It means “fetch `refs/heads/<branch>` from `origin` into the corresponding
   remote-tracking ref and use its current tip.” It is intentionally a moving
   dependency. The `origin/` namespace is reserved for this purpose, so a tag
   whose name begins with `origin/` cannot be requested through this interface.

No other revision class is accepted. In particular, `COMMITISH` never means
a local branch. The implementation may produce an error, if `COMMITISH` resolves
to a local branch name. Revision classification must occur before deciding whether a
fetch is required. A locally cached `origin/<branch>` ref remains a moving
revision, not a fixed revision merely because it resolves locally.

### R5. Network access and offline operation

1. Network access must be demand-driven. The function must not probe the
   network merely to determine whether it is available.
2. No network operation is permitted when the following is true:

   - the requested fixed revision resolves locally;
   - every recursive submodule can be resolved to the revision recorded by
     its parent at the requested fixed revision.

   Therefore a correctly prepared repository pinned to a tag or commit must be
   usable without internet access.
3. If a fixed revision resolves locally but `HEAD` differs, the function must
   check it out without fetching.
4. If a fixed revision is missing locally, the function must fetch (R6.2).
5. An explicit remote-tracking revision should be fetched on every invocation.
   If the fetch fails, but the requested remote-tracking ref resolves locally,
   the function must produce a warning. In either case, HEAD must be updated to
   the newest local ref. If the ref does not resolve locally, the failure must be fatal.
6. A new clone necessarily requires access to `URL`.
7. The CMake-script self-update check is not part of the offline guarantee above.

### R6. Clone, fetch, and checkout

1. A new repository clone and its recursive submodules should be shallow (depth one)
   where supported by Git and the remote.
2. If a fetch is necessary, it should only download the minimum number of objects
   needed to resolve the specified commitish. This also applies to submodules.
3. Failure to check out the requested fixed revisions (including submodules) is fatal.
   
### R7. Recursive submodules

1. After every clone or cmake managed checkout, all submodules declared by the
   selected commit must be initialized and updated recursively to the exact
   commits recorded by their parents.
2. This applies when changing between commits or tags, including a change that
   adds, removes, or changes a submodule.
3. Submodule URLs must be synchronized before update so changes in `.gitmodules`
   take effect.
4. R5.2, and R6.2 apply.
5. A failure to reach the recorded recursive submodule state produces clear fatal
   error message.

### R8. Postconditions

These apply only to cmake managed repositories. These must be checked in the
unit tests, but verification during execution may be skipped.

1. Outside the remote-tracking fallback (R5.5), successful return means the repository's
   `HEAD` is at the commit selected by `COMMITISH`.
2. The `HEAD` is detached.
3. All submodules have the version specified in their parent.
4. All repositories including submodules are clean.

Git failures that prevent the required postcondition must cause configuration to fail.

### R9. Adding the CMake subproject

1. By default, the prepared repository must be added with a binary directory of
   `${CMAKE_BINARY_DIR}/alp_external/<name>`.
2. It must be marked `SYSTEM` by default so diagnostics from external headers
   are treated as system diagnostics where CMake and the compiler support it.
3. `NOT_SYSTEM` must omit the `SYSTEM` flag.
4. `DO_NOT_ADD_SUBPROJECT` must skip `add_subdirectory()` completely while still
   preparing the repository and setting `<name>_SOURCE_DIR`.
5. `add_subdirectory()` must run only after the repository is prepared according to
   R3-R8.

### R10. Script update check

The check works by updating to an orign/main ref, which attempts the fetch,
but only produces a warning if there is no internet.

1. At most one AddRepo self-update check may run per CMake process.
2. The check must not recurse indefinitely when it uses
   `alp_add_git_repository()` to obtain the scripts repository.
3. Failure to check for script updates must not make an otherwise locally
   satisfiable dependency unusable. It may produce a concise warning.
4. Network behavior caused by this check must be separately identifiable in
   status output from network behavior for the requested dependency.

### R11. Repeatability and observability

1. Repeating a call with the same fixed revision and already-correct recursive
   state must be idempotent: it must not fetch, checkout, or modify files.
2. Calls from different build directories that share the same source-tree
   destination must converge on the same prepared working tree, subject to the
   developer-checkout protection rule. Concurrent mutation of the same
   destination is unsupported.
3. Status output should distinguish clone, fetch, checkout, submodule update,
   already-correct/offline reuse, and protected-developer-checkout decisions.
4. All messages (status, warning, error..) must include the name of the dependency.
5. Error messages must identify the dependency, working dir, operation, requested revision,
   and relevant Git diagnostic.
6. Errors are generally fatal.

## Acceptance scenarios

The corrected test suite should use temporary local Git repositories wherever possible.
Tests that exercise real network transport may use any repository on
github, but should prefer repositories inside the AlpineMapsOrg organisation.

For each test, postconditions (R8) must be tested after every successful CMake-managed preparation.
When it says fixed revision, test all 3 types (lightweight tag, annotated tag, and commit id sha).
The test repository linked below can be used for unit tests (it's ok to push new revisions during a testrun). At the beginning of the unit test, the repo should be reset to a defined state (force pushing there is ok). Github supports shallow clones, capability to support shallow clones and fetches must be demonstrated by the unit tests. If shallow clones are later ignored by a certain setup, that's ok.

Test repository: git@github.com:AlpineMapsOrgDependencies/cmake_repo_for_tests.git

At minimum, tests must cover:

- Fresh clones with tag, annotated tag, commit id and origin/branch (verify they are shallow).
- Fresh clones, same revision types, with submodules (verify submodules are shallow as well).
- Fresh clones, same revision types, with submodules, one of the submodules is unavailable (verify this is rejected with an error).
- On second run, with the same fixed-revision types (verify nothing is fetched, works offline).
- On second run, with the same fixed-revision types, with submodules (verify nothing is fetched, works offline).
- On second run, with the same fixed-revision types, with submodules, deliberately delete a submodule (verify either an error is produced because the repo is dirty, or it is fixed).
- On second run, verify that a dirty repository is rejected with an error.
- On second run, with a remote-tracking revision (verify the remote is fetched).
- On second run, with a remote-tracking revision, offline fallback (works offline, verify there is no fatal error).
- Update an existing repo to a fixed revision, the revision must be fetched (verify the repo did not gain full history).
- Update an existing repo to a fixed revision, the revision is already present (verify nothing is fetched and works offline).
- Update an existing repo with submodules to a fixed revision, the revision must be fetched (verify the repo and submodules did not gain full history).
- Update an existing repo with submodules to a fixed revision, the revision is already present (verify nothing is fetched and works offline).
- Update an existing repo with submodules to a fixed revision, the new revision updates to an invalid submodule (verify it is rejected with an error).
- Update an existing repo with attached HEAD (verify no git commands beside the check for attachment are issued, a warning is printed, works offline).
- `DESTINATION_PATH`, the default `ALP_EXTERN_DIR`, `DO_NOT_ADD_SUBPROJECT`, `NOT_SYSTEM`, and `<name>_SOURCE_DIR` behave as documented.
- Absolute or escaping destination paths, an existing non-Git directory, and a repository with a mismatched `origin` fail without data loss.
- That tags containing slashes remain fixed revisions, `origin/<branch>` is always moving, and unsupported revision forms fail clearly.
- The script update check runs at most once, does not recurse, and cannot break an otherwise offline fixed-revision call.
- The test runner reaches every scenario; no unconditional early return or equivalent skip may make the suite report success without executing its assertions.

## Known gaps in the current implementation

These are implementation defects or ambiguities revealed by comparing the
current script with the requirements; they are not requirements themselves.

- The test helper's unconditional `return()` bypasses most assertions and every
  second-call scenario.
- A repository at the right superproject commit skips submodule verification
  and repair.
- The current implementation supports an obsolete DEEP_CLONE parameter.
- Local-branch protection is applied only in some fetch paths; a locally
  available tag or commit can currently cause a developer branch to be checked
  out away from its tip.
- Submodule update failures and checkout failures are warnings, after which the
  dependency may still be added.
- Fetch failure is only a warning, even when the requested revision cannot be
  provided.
- Ref classification is based partly on whether the text contains `/`, which
  misclassifies tags containing slashes.
- The existing repository's `origin` is not checked against `URL`.
- Submodule URLs are not synchronized after switching commits.
- Argument validation and reporting of unparsed arguments are missing.
- Destination and subprocess arguments are inconsistently quoted.
- The implementation does not enforce the documented CMake minimum needed for
  `add_subdirectory(... SYSTEM)`.

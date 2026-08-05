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
    [DEEP_CLONE]
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
| `COMMITISH` | A tag, commit ID, local branch, or explicit remote-tracking ref such as `origin/main`. |
| `DESTINATION_PATH` | Repository path relative to `CMAKE_SOURCE_DIR`. The default is `${ALP_EXTERN_DIR}/<name>`. |
| `DO_NOT_ADD_SUBPROJECT` | Prepare the repository but do not call `add_subdirectory()`. |
| `NOT_SYSTEM` | Add the subdirectory without CMake's `SYSTEM` flag. Ignored when `DO_NOT_ADD_SUBPROJECT` is set. |
| `DEEP_CLONE` | Use a full clone and full recursive submodules. The default is a depth-one shallow clone with shallow recursive submodules. |
| `PRIVATE_DO_NOT_CHECK_FOR_SCRIPT_UPDATES` | Internal escape hatch that suppresses the self-update check and prevents recursion while the scripts repository itself is obtained. Applications should not normally use this option. |

On return, `<name>_SOURCE_DIR` is set in the caller's scope to the absolute
repository path.

## Current behavior

The implementation currently does the following:

1. Requires Git 2.22 or newer.
2. Once per CMake process, normally invokes the AlpineMaps CMake-script update
   check. That check manages another Git repository and may access the network.
3. Chooses `${CMAKE_SOURCE_DIR}/${ALP_EXTERN_DIR}/<name>` as the destination;
   `ALP_EXTERN_DIR` defaults to `extern`. `DESTINATION_PATH` replaces this
   relative path.
4. Creates the destination directory and clones into it if `.git` is absent.
5. Uses shallow clones by default and full clones with `DEEP_CLONE`.
6. Treats a `COMMITISH` containing a slash, such as `origin/main`, as a moving
   remote ref that must be fetched.
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
   `${CMAKE_SOURCE_DIR}/<DESTINATION_PATH>`.
4. The parent directory may be created as necessary.
5. An existing destination must be either an empty directory suitable for a
   clone or a Git working tree. A non-empty, non-Git destination must cause a
   clear error and must not be overwritten.
6. An existing Git working tree's `origin` URL must identify the requested
   repository. If it does not, the function must fail clearly rather than fetch
   from or build the wrong repository. Git's harmless URL spelling differences
   may be normalized for this comparison.
7. `<name>_SOURCE_DIR` must be returned as an absolute path in the caller's
   scope after the repository has been prepared successfully.

### R2. Required tools and compatibility

1. Git 2.22 or newer must be available.
2. CMake 3.25 or newer must be available.
3. Paths, URLs, names, and revisions must be passed to subprocesses without
   losing spaces or list separators.

### R3. Revision classes

The behavior depends on the requested revision:

1. A **fixed revision** is a commit ID, lightweight tag, annotated tag, or any
   other local ref that resolves to a commit. Annotated tags must be peeled to
   their commit before comparison with `HEAD`.
2. An **explicit remote-tracking revision** is written as `<remote>/<branch>`,
   for example `origin/main`. It means “consult the remote and use the current
   branch tip.” It is intentionally a moving dependency.
3. A **local branch** is a branch checked out in the dependency working tree.
   Its presence activates the developer-worktree protection in R7.
4. A slash is only a hint, not sufficient proof that a revision is a remote
   branch: tags and local branches may also contain slashes. Git ref
   information must be used to disambiguate refs whenever the repository
   exists.

### R4. Network access and offline operation

1. Network access must be demand-driven. The function must not probe the
   network merely to determine whether it is available.
2. No dependency-repository network operation is permitted when all of the
   following are already true:

   - the requested fixed revision resolves locally;
   - `HEAD` is at the commit selected by that revision; and
   - every recursive submodule is initialized at the commit recorded by its
     parent, or can be corrected entirely from local Git objects.

   Therefore a correctly prepared repository pinned to a tag or commit must be
   usable without internet access.
3. If a fixed revision resolves locally but `HEAD` differs, the function must
   check it out without fetching. It may use the network afterward only if
   objects needed by recursive submodules are unavailable locally.
4. If a fixed revision is missing locally, the function fetches the requested objects including submodules according to R5.
5. An explicit remote-tracking revision must be fetched on every invocation. This is the
   caller's opt-in to network-dependent, moving behavior. If network fails for remote-tracking revisions, this is a WARNING, not an ERROR.
6. A new clone necessarily requires access to `URL`.
7. The CMake-script self-update check is not part of the offline guarantee above.

### R5. Clone and fetch depth

1. Without `DEEP_CLONE`, a new repository clone must be shallow (depth one) and its
   recursive submodules must also be shallow where supported by Git and the
   remote.
2. With `DEEP_CLONE`, a new repository clone must have the full history. Its recursive submodules (if any) are initialized according to the recommendation of .gitmodules.
3. If the parameter (`DEEP_CLONE`) does not agree with the repository type, an error is produced (with the hint to either delete the repo, or change the DEEP_CLONE flag).
4. A fetch in a shallow repository must first try the exact requested tag/ref and then a branch
   or commit fetch as appropriate. It must not download complete history merely
   because one fixed revision was not initially present. This also applies to submodules.
4. A fetch in a deep repository may update all refs and tags needed to make the requested
   revision available.

### R6. Checkout and postconditions

1. Outside the protected-local-branch case in R7, successful return means the
   repositories's `HEAD` is the commit selected by `COMMITISH`, and all submodules have the version specified in their parent.
2. Comparing `HEAD` with a tag must compare commit IDs, so both lightweight and
   annotated tags work correctly.
3. When `HEAD` already selects the requested commit, checkout must be skipped to
   avoid unnecessary work and disruption (same for submodules).
4. A checkout must not discard tracked or untracked user changes. If Git cannot
   safely perform it, the function must stop with an error.
5. Clone, fetch, revision resolution, checkout, and other Git failures that
   prevent the required postcondition must cause configuration to fail. The
   function must never continue to `add_subdirectory()` using a known-wrong or
   partially prepared revision.
6. Error messages must identify the dependency, operation, requested revision,
   and relevant Git diagnostic.

### R7. Developer-worktree protection

1. If an existing dependency is currently on a local branch, the function must
   preserve that branch and its working tree. It must not automatically check
   out a tag, commit, another branch, or remote-tracking ref.
2. In this case it must emit a clear warning stating the current branch and the
   requested revision. The message must make it unambiguous that the requested revision was not checked
   out.
3. No fetch is needed merely to discover that a local branch is protected (point 1).
5. Submodules on a protected local branch should not be changed automatically,
   because doing so can modify the developer's working tree. Their state may be
   checked and reported, but not reset without an explicit future opt-in.

### R8. Recursive submodules

1. After every clone or managed checkout, all submodules declared by the
   selected commit must be initialized and updated recursively to the exact
   commits recorded by their parents.
2. This applies when changing between commits or tags, including a change that
   adds, removes, or changes a submodule.
3. Submodule URLs must be synchronized before update so changes in
   `.gitmodules` take effect.
4. Submodule work must obey the shallow/deep choice in R5.
5. If all recursive submodules are already correct, no submodule fetch or other
   network access may occur.
6. If a required submodule commit is unavailable locally, it must be fetched. A
   failure to reach the recorded recursive submodule state must fail the
   operation and prevent `add_subdirectory()`.
7. Existing submodule modifications must not be silently discarded. The
   function must fail with an actionable diagnostic when an update would
   overwrite them.

### R9. Adding the CMake subproject

1. By default, the prepared repository must be added with a binary directory of
   `${CMAKE_BINARY_DIR}/alp_external/<name>`.
2. It must be marked `SYSTEM` by default so diagnostics from external headers
   are treated as system diagnostics where CMake and the compiler support it.
3. `NOT_SYSTEM` must omit the `SYSTEM` flag.
4. `DO_NOT_ADD_SUBPROJECT` must skip `add_subdirectory()` completely while still
   preparing the repository and setting `<name>_SOURCE_DIR`.
5. `add_subdirectory()` must run only after every applicable repository and
   submodule postcondition has succeeded.

### R10. Script update check

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
   local-branch protection rule. Concurrent mutation of the same destination
   is unsupported unless the implementation adds locking.
3. Status output should distinguish clone, fetch, checkout, submodule update,
   already-correct/offline reuse, and protected-branch decisions.
4. The function must not expose normal Git command output unless it is useful
   for a failure or an explicitly verbose mode.

## Acceptance scenarios

The corrected test suite may use temporary local Git repositories for core
behavior. Tests that exercise real network transport may use repositories of the AlpineMapsOrg organisation.

At minimum, tests must cover:

1. Fresh shallow and deep clones, each with recursive submodules.
2. Fresh clone directly to a commit, lightweight tag, annotated tag, local
   branch name, and explicit remote-tracking revision.
3. A second call at the same fixed revision performs no fetch or checkout and
   succeeds with network access made unavailable.
4. A locally available fixed revision different from `HEAD` is checked out
   offline.
5. Switching between two locally available tags occurs offline, including
   annotated tags.
6. A missing tag or commit is fetched with the minimum required history.
7. `origin/main` is refreshed on every call and a detached managed checkout
   advances to its new tip.
8. A checked-out local branch, with and without modifications, is preserved and
   produces a warning rather than being moved.
9. Submodules are initialized recursively, updated when the superproject
   revision changes, and untouched when already correct.
10. Missing submodule objects are fetched; unavailable submodule objects cause
    a hard failure before `add_subdirectory()`.
11. Modified submodules are not overwritten.
12. A clone failure, fetch failure, nonexistent revision, checkout failure, and
    submodule failure each stop configuration.
13. `DESTINATION_PATH`, the default `ALP_EXTERN_DIR`, `DO_NOT_ADD_SUBPROJECT`,
    `NOT_SYSTEM`, and `<name>_SOURCE_DIR` behave as documented.
14. An existing non-Git directory and a repository with a mismatched `origin`
    fail without data loss.
15. The script update check runs at most once, does not recurse, and cannot
    break an otherwise offline fixed-revision call.
16. The test runner reaches every scenario; no unconditional early return or
    equivalent skip may make the suite report success without executing its
    assertions.

## Known gaps in the current implementation

These are implementation defects or ambiguities revealed by comparing the
current script with the requirements; they are not requirements themselves.

- The test helper's unconditional `return()` bypasses most assertions and every
  second-call scenario.
- The self-update check can access the network even when the requested
  dependency is already completely correct locally.
- A repository at the right superproject commit skips submodule verification
  and repair.
- Local-branch protection is applied only in some fetch paths; a locally
  available tag or commit can currently cause a developer branch to be checked
  out away from its tip.
- Submodule update failures and checkout failures are warnings, after which the
  dependency may still be added.
- Fetch failure is only a warning, even when the requested revision cannot be
  provided.
- Ref classification is based partly on whether the text contains `/`, which
  misclassifies tags or local branches containing slashes.
- The existing repository's `origin` is not checked against `URL`.
- `DEEP_CLONE` does not define or enforce what happens to an existing shallow
  clone.
- Submodule URLs are not synchronized after switching commits.
- Argument validation and reporting of unparsed arguments are missing.
- Destination and subprocess arguments are inconsistently quoted.
- CMake compatibility for `add_subdirectory(... SYSTEM)` is not stated or
  checked.

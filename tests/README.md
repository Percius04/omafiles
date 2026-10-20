# Hybrid filename search regression tests

Requires Linux with Bubblewrap (`bwrap`), Python 3.9+, Bash, and the Qt6 Test and
QuickTest development components in addition to the app's build dependencies.
Build the native app and opt-in Qt tests in a private worktree, not an installed
source tree. No installation is needed:

```sh
cmake -S . -B build -DOMAFILES_BUILD_SEARCH_TESTS=ON \
  -DCMAKE_INSTALL_PREFIX="$PWD/build/test-prefix" \
  -DOMAFILES_BIN_INSTALL_DIR="$PWD/build/test-prefix/bin" \
  -DOMAFILES_DATA_INSTALL_DIR="$PWD/build/test-prefix/share" \
  -DOMAFILES_QML_INSTALL_DIR="$PWD/build/test-prefix/lib/qt6/qml"
cmake --build build -j4
python3 -m unittest discover -s tests -p test_search_runner.py -v
evidence=$(python3 -c 'import tempfile; print(tempfile.mkdtemp(prefix="omafiles-search-"))')
python3 tests/run-search-tests.py --build build --evidence "$evidence/qml"
python3 tests/run-search-tests.py --build build --native --evidence "$evidence/native"
python3 tests/run-search-tests.py --build build --selfcheck --evidence "$evidence/selfcheck"
```

Evidence paths must be **new directories** below Python's `tempfile.gettempdir()`
(the OS temporary directory by default). Set `TMPDIR` to an existing writable
private directory to choose another physical temporary parent. Resolved paths
outside that parent, including symlink escapes, are rejected before setup. Each
run records its exact command, output and exit code; keep any needed logs before
removing the evidence directory.

The runner creates a private writable HOME and physically temporary-backed
`/tmp`, with the host read-only, private `/run`, no session/system D-Bus, no
network and offscreen Qt. It requires Bubblewrap and never falls back to running
the app directly. **Never run the raw selfcheck or the CMake `selfcheck` target
on the host:** it can empty the user's Trash. Compare failures to the same
sandboxed base build. Runner unit tests intercept subprocess execution to check
portable path admission and sandbox command construction; they are not a
substitute for the actual Bubblewrap integration runs above.

The QML suite runs the real SearchBackend/SearchOps, native SearchWorker and
ProcessRunner. Index scripts are controlled stale/empty/error fixtures, using
synthetic filenames and contents only. A test-only QThreadPool semaphore
controls source arrival order. SearchOps tests use a real ListView and singleton
state; root/tab transitions use the actual NavigationController and TabOps.
Enter is exercised through the real SearchBar key handler as absolute-path
reveal/navigation, never as an external file launch. Empty root/index progress
must leave initial selection pending until the first nonempty snapshot;
subsequent snapshots must preserve deliberate deselection.

The native worker suite compiles the actual production worker with
`OMAFILES_SEARCH_TEST_GATE`, only on its test target. That compile-only scheduling
seam blocks at an actual descendant directory while the receiver processes the
root snapshot. It cannot delay the production app/plugin. It proves root delivery
before a walk completes, completion flags, queued-generation cancellation and
receiver destruction safety. It does not replace filesystem traversal with a
mock or rely on timing a large directory fixture.

The native `results(entries, truncated)` signal remains final-only for legacy
callers/selfchecks; hybrid search consumes the new `snapshot` signal.
Final merged-result assertions wait for `complete=true`, not a guessed number
of snapshots. Name searches publish a bounded ranked top 200 after scanning the
root, periodically (100ms) while continuing the breadth-first walk, and finally
with completion. Known dependency/cache directories are pruned and directory
symlinks are not followed. Index and local completion are tracked separately;
content mode uses its existing single-source semantics. Late snapshots remap
selection/anchor by absolute path and retain scroll; missing selected paths
clear selection rather than selecting a different file. Origin bindings are
invalidated on query, hidden-mode, path, tab and same-path navigation transitions.

No installer, live app launch, real user content mutation or deployment is part
of this test workflow. Offscreen integration is not a claim of visual acceptance
in the installed GUI.

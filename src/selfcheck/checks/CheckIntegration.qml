import QtQuick
import Omafiles.Backend as Backend
import "../../../state"
import "../../../shared/Utils.js" as Utils

// Domain checks extracted from app/SelfCheck.qml (_register).
// Structural refactor only — behavior unchanged.
QtObject {
  function register(sc) {
        sc.add("Conflict detection sees a broken symlink (BUG-01)", function (done) {
          var link = sc.opsDir + "/bug01-broken-" + Date.now()
          sc._sh(["ln", "-s", "/omafiles-no-such-target-xyz", link], function (r) {
            if (r.exitCode !== 0) { done(false, "couldn't create the broken symlink: " + r.stderr); return }
            var hit = Backend.FileOperations.existingPaths([link])
            done(hit.length === 1 && hit[0] === link,
                 hit.length === 1 ? "broken symlink detected as a conflict"
                                  : "existingPaths did NOT detect the broken symlink (n=" + hit.length + ")")
          })
        })

        // ======================= BUG-02 (Hardening-1) =======================
        // Smoke tests of the .sh scripts that are still part of the
        // UI's behavior. Goal: that a regression like the one in
        // empty-trash.sh (which passed 70/70 green) makes the harness fail.

        // Runs the REAL Backend.FileOperations.emptyTrash() against a FIXTURE
        // trash root, confined there by OMAFILES_SELFCHECK_TRASH_ROOT (see
        // FileOperations_Trash.cpp::emptyTrash) so the user's real trash is
        // never touched (#29). The fixture is seeded with one item, so an
        // emptyTrash that discovers no root or removes nothing fails here.
        sc.add("Backend.FileOperations emptyTrash empties trash roots (BUG-02)", function (done) {
          var root = sc.dir + "/trash"
          var mk = "mkdir -p " + sc._q(root + "/files") + " " + sc._q(root + "/info")
            + " && printf 'x\\n' > " + sc._q(root + "/files/x.txt")
            + " && printf '%s\\n' '[Trash Info]' " + sc._q("Path=" + sc.note)
            + " 'DeletionDate=2026-01-01T00:00:00' > " + sc._q(root + "/info/x.txt.trashinfo")
          sc._sh(["bash", "-c", mk], function (r0) {
            if (r0.exitCode !== 0) { done(false, "fixture trash setup failed: " + r0.stderr); return }

            // Registered by hand rather than via sc._fileOp(), which owns that
            // hook itself: this way the signals are disconnected on EVERY exit
            // path -- success, error, and the runner's timeout (which calls
            // sc._activeFileOpCleanup unconditionally).
            function cleanup() {
              Backend.FileOperations.finished.disconnect(onFinished)
              Backend.FileOperations.error.disconnect(onError)
              if (sc._activeFileOpCleanup === cleanup) sc._activeFileOpCleanup = null
            }
            function onError(op, path, msg) {
              if (op !== "emptyTrash") return
              cleanup()
              done(false, "emptyTrash error: " + msg)
            }
            function onFinished(op, path) {
              if (op !== "emptyTrash") return
              cleanup()
              var count = "find " + sc._q(root + "/files") + " " + sc._q(root + "/info") + " -mindepth 1 | wc -l"
              sc._sh(["bash", "-c", count], function (r) {
                var n = parseInt(String(r.stdout).trim(), 10)
                done(n === 0, n === 0 ? "fixture trash emptied cleanly" : "items remained: " + n)
              })
            }
            Backend.FileOperations.finished.connect(onFinished)
            Backend.FileOperations.error.connect(onError)
            sc._activeFileOpCleanup = cleanup

            // Cleared synchronously on the very next line: emptyTrash() captures
            // the override before queuing its job, so no exit path of this check
            // (timeout included) can leave the var set for a later check.
            Backend.Env.set("OMAFILES_SELFCHECK_TRASH_ROOT", root)
            Backend.FileOperations.emptyTrash()
            Backend.Env.set("OMAFILES_SELFCHECK_TRASH_ROOT", "")
          })
        })

        // list-archive.sh over a deterministic .tar built from listDir
        // (sub/ + alpha/beta/gamma.txt). Confirms that it lists the top-level
        // elements in the NUL-delimited contract (name\0isdir\0...).
        sc.add("list-archive.sh lists a tar fixture (BUG-02)", function (done) {
          var tarPath = sc.opsDir + "/la-fixture.tar"
          var mk = "tar -cf " + sc._q(tarPath) + " -C " + sc._q(sc.listDir) + " sub alpha.txt beta.txt gamma.txt"
          sc._sh(["bash", "-c", mk], function (r0) {
            if (r0.exitCode !== 0) { done(false, "tar setup failed: " + r0.stderr); return }
            sc._sh(["bash", sc.resourceRoot + "/scripts/runtime/list-archive.sh", tarPath, ""], function (r) {
              var toks = String(r.stdout).split("\0")
              var names = []
              for (var i = 0; i < toks.length; i += 2) if (toks[i]) names.push(toks[i])
              var ok = r.exitCode === 0 && names.indexOf("sub") >= 0 && names.indexOf("alpha.txt") >= 0
              done(ok, ok ? "listed " + names.length + " top-level entries"
                          : "output=[" + names.join(",") + "] exit=" + r.exitCode)
            })
          })
        })

        // mount-iso.sh: can't mount in headless. It exercises the FAILURE
        // PATH: given a nonexistent path the script must not print a fake "Mounted…"
        // nor hang -> it exits != 0 and with no stdout. Verifies that it's invoked and that
        // its guard (set -e + loopdev check) works.
        sc.add("mount-iso.sh fails safely on a bad path (BUG-02)", function (done) {
          sc._sh(["bash", sc.resourceRoot + "/scripts/runtime/mount-iso.sh", sc.dir + "/no-such-file.iso"], function (r) {
            var ok = r.exitCode !== 0 && String(r.stdout).trim() === ""
            done(ok, "exit=" + r.exitCode + " stdout='" + String(r.stdout).trim() + "'")
          })
        })

        // MimeResolver: getting apps for a .txt file should return at least one app
        sc.add("MimeResolver.getAppsForFile returns valid list (BUG-02)", function (done) {
          var apps = Backend.MimeResolver.getAppsForFile(sc.note)
          if (!apps || apps.length === 0) {
            done(false, "No apps returned for text file")
            return
          }
          if (apps[0].id === undefined) {
            done(false, "App must have an ID")
            return
          }
          if (apps[0].name === undefined) {
            done(false, "App must have a Name")
            return
          }
          done(true, "Returned " + apps.length + " apps")
        })

        // ======================= BUG-03 (Hardening-2) =======================

        // Properties/chmod built `du -shc -- <all>` and `stat -c%a -- <all>`
        // in a single bash line -> with a huge selection it blew the length
        // limit (ARG_MAX / 128 KiB per argument) and the dialog was left without
        // size/permissions. Now they use Backend.FileOperations.totalSize/octalModes (native,
        // no command line). The test builds a list that DOES overflow that
        // line: the native path handles it; the old shell fails. It fails with the
        // previous code (octalModes didn't exist -> TypeError).
        sc.add("Properties/chmod handle a huge selection without ARG_MAX (BUG-03)", function (done) {
          // Two fixtures that exist (to assert correct sum/mode) + padding of
          // long nonexistent paths until the `stat/du -- <all>` line that
          // the old code used would overflow the per-argument limit (128 KiB).
          var reals = [sc.note, sc.png]
          var expected = Backend.FileOperations.totalSize(reals)
          var pad = new Array(160).join("x")
          var big = reals.slice()
          while (big.length < 2000) big.push(sc.opsDir + "/" + pad + big.length)
          // NATIVE: doesn't build a command line -> handles the huge list.
          var total = Backend.FileOperations.totalSize(big)      // sums only the 2 real ones
          var modes = Backend.FileOperations.octalModes(big)     // aligned with big, "" if missing
          var nativeOk = total === expected
            && modes.length === big.length && modes[0].length > 0 && modes[2] === ""
          if (!nativeOk) { done(false, "native: total=" + total + " exp=" + expected
            + " len=" + modes.length + " m0='" + modes[0] + "' m2='" + modes[2] + "'"); return }
          // OLD: the SAME `stat -c%a -- <all>` form that the old code used
          // -> the -c arg overflows the limit and exec fails (exit != 0).
          var oldCmd = "stat -c%a -- " + big.map(function (p) { return sc._q(p) }).join(" ")
          sc._sh(["bash", "-c", oldCmd], function (r) {
            done(r.exitCode !== 0,
                 "native OK (" + big.length + " paths); old shell line failed (exit=" + r.exitCode + ")")
          })
        })

        // Properties panel used to shell out to `stat`/`du` for a single
        // entry (see logic/PropertiesLoader.qml); native statInfo()/
        // requestDirSize() replaced them (v1.2-dev). This checks both
        // against the values the codebase already trusts elsewhere:
        // octalModes() for the mode, totalSize() for the recursive size.
        sc.add("Backend.FileOperations.statInfo()/requestDirSize() match octalModes()/totalSize() (native Properties)", function (done) {
          var info = Backend.FileOperations.statInfo(sc.note)
          var expectedMode = Backend.FileOperations.octalModes([sc.note])[0]
          if (!info.perms || info.perms.charAt(0) !== "-") { done(false, "statInfo perms doesn't look like a regular file: '" + info.perms + "'"); return }
          if (info.perms.indexOf(expectedMode) < 0) { done(false, "statInfo perms '" + info.perms + "' doesn't contain octalModes mode '" + expectedMode + "'"); return }
          if (!info.ownerGroup || info.ownerGroup.indexOf(":") < 0) { done(false, "statInfo ownerGroup malformed: '" + info.ownerGroup + "'"); return }
          if (!info.mtime) { done(false, "statInfo mtime empty"); return }

          var expectedBytes = Backend.FileOperations.totalSize([sc.opsDir])
          var reqId = 424242
          function onReady(id, bytes) {
            if (id !== reqId) return
            Backend.FileOperations.dirSizeReady.disconnect(onReady)
            done(bytes === expectedBytes,
                 bytes === expectedBytes
                   ? ("statInfo perms=" + info.perms + " owner=" + info.ownerGroup + ", requestDirSize matched totalSize (" + bytes + " bytes)")
                   : ("requestDirSize=" + bytes + " != totalSize=" + expectedBytes))
          }
          Backend.FileOperations.dirSizeReady.connect(onReady)
          Backend.FileOperations.requestDirSize(reqId, sc.opsDir)
        })

        // ======================= BUG-05 (Hardening-2) =======================

        // ArchiveActions opened an archive member with `tar xf A -O <member>`
        // without "--": a member starting with "-" (e.g. "-foo") was taken by tar
        // as options and failed. The corrected pattern is `tar xf A -O -- <member>`.
        // A .tar with a member "-foo" is created and it's checked that the NEW form
        // dumps it and the OLD one fails.
        sc.add("tar extracts a member whose name starts with '-' (BUG-05)", function (done) {
          var d = sc.opsDir + "/bug05"
          var arch = d + "/a.tar"
          var setup = "mkdir -p " + sc._q(d) + " && cd " + sc._q(d)
            + " && printf 'contenido05' > ./-foo && tar cf " + sc._q(arch) + " -- -foo"
          sc._sh(["bash", "-c", setup], function (r0) {
            if (r0.exitCode !== 0) { done(false, "setup failed: " + r0.stderr); return }
            sc._sh(["bash", "-c", "tar xf " + sc._q(arch) + " -O -- " + sc._q("-foo")], function (rNew) {
              sc._sh(["bash", "-c", "tar xf " + sc._q(arch) + " -O " + sc._q("-foo") + " 2>/dev/null"], function (rOld) {
                var ok = rNew.exitCode === 0 && String(rNew.stdout) === "contenido05" && rOld.exitCode !== 0
                done(ok, "new: exit=" + rNew.exitCode + " out='" + String(rNew.stdout)
                  + "' | old exit=" + rOld.exitCode)
              })
            })
          })
        })
        // ======================= BUG-06 (Phase 43 Regression) =======================
        sc.add("Terminal resolver error path (BUG-06)", function (done) {
          var signaled = false
          var onErr = function (msg) {
            if (msg === "No supported terminal emulator found.") signaled = true
          }
          Backend.TerminalResolver.error.connect(onErr)
          var oldPath = Backend.Env.get("PATH")
          var oldTerm = Backend.Env.get("TERMINAL")
          Backend.Env.set("PATH", "/dev/null/fake")
          Backend.Env.set("TERMINAL", "omafiles-fake-terminal")
          Backend.TerminalResolver.launchTerminal("/tmp")
          Backend.Env.set("PATH", oldPath)
          Backend.Env.set("TERMINAL", oldTerm)
          Backend.TerminalResolver.error.disconnect(onErr)
          done(signaled, signaled ? "error signal emitted" : "error signal NOT emitted")
        })

        sc.add("Relative path quoting test (BUG-06)", function (done) {
          var lastCopied = ""
          var onCopied = function (text) { lastCopied = text }
          Backend.TerminalResolver.copied.connect(onCopied)
          Backend.TerminalResolver.copyPathsRelative(["/tmp/a b.txt", "/tmp/c'd.txt"], "/tmp")
          Backend.TerminalResolver.copied.disconnect(onCopied)
          var ok = (lastCopied === "'a b.txt' 'c'\\''d.txt'")
          done(ok, ok ? "paths quoted properly" : "got: " + lastCopied)
        })

        sc.add("Keyboard shortcut integration test (BUG-06)", function (done) {
          var kbdComp = Qt.createComponent("../../../logic/KeyboardShortcuts.qml")
          if (kbdComp.status !== Component.Ready) { done(false, "kbd comp not ready: " + kbdComp.errorString()); return }
          // P2.5 (2026-08-17): handlePress() now resolves event -> action id
          // via hostControllers.keybindingResolver before dispatching, so the
          // stub needs a real resolver, not just a real actionEngine -- an
          // isolated JS object literal can't replicate actionFor()'s logic.
          var resolverComp = Qt.createComponent("../../../logic/KeybindingResolver.qml")
          if (resolverComp.status !== Component.Ready) { done(false, "resolver comp not ready: " + resolverComp.errorString()); return }
          var resolver = resolverComp.createObject(sc)
          var called = {}
          var stubEngine = {
            startRename: function() { called.F2 = true },
            requestDelete: function() { called.Del = true },
            copySelected: function() { called.CtrlC = true },
            cutSelected: function() { called.CtrlX = true },
            paste: function() { called.CtrlV = true }
          }
          var kbd = kbdComp.createObject(sc, {
            "hostControllers": { "actionEngine": stubEngine, "navController": {}, "keybindingResolver": resolver },
            "hostRoot": {}
          })
          var ev = function(k, mod) { return { "key": k, "modifiers": mod || Qt.NoModifier, "accepted": false } }
          kbd.handlePress(ev(Qt.Key_F2))
          kbd.handlePress(ev(Qt.Key_Delete))
          kbd.handlePress(ev(Qt.Key_C, Qt.ControlModifier))
          kbd.handlePress(ev(Qt.Key_X, Qt.ControlModifier))
          kbd.handlePress(ev(Qt.Key_V, Qt.ControlModifier))
          // P1-3 (architectural audit 2026-08-17): Shift+Return ("open
          // terminal here") calls Backend.TerminalResolver, but this file
          // only imports QtQuick and ../state -- caught here explicitly
          // (try/catch) instead of letting a ReferenceError propagate as a
          // generic "exception: ..." failure from the runner.
          var terminalShortcutError = null
          try {
            kbd.handlePress(ev(Qt.Key_Return, Qt.ShiftModifier))
          } catch (e) {
            terminalShortcutError = String(e)
          }
          kbd.destroy()
          resolver.destroy()

          // Also checked against the REAL production instance (nested under
          // panels/ActiveFileList.qml, reached here through
          // sc._content.actionEngine.list -- see P0-1's lesson in
          // ARCHITECTURE_EVOLUTION_AUDIT.md: QML's id-based context
          // resolution can make an isolated Qt.createComponent() repro
          // behave differently from the real nested tree, so imports are
          // verified both ways rather than trusting either alone.
          var realTreeError = null
          var c = sc._content
          if (c && c.actionEngine && c.actionEngine.list && c.actionEngine.list.keyboardShortcuts) {
            try {
              c.actionEngine.list.keyboardShortcuts.handlePress(ev(Qt.Key_Return, Qt.ShiftModifier))
            } catch (e) {
              realTreeError = String(e)
            }
          }

          var ok = called.F2 && called.Del && called.CtrlC && called.CtrlX && called.CtrlV
            && !terminalShortcutError && !realTreeError
          done(ok, ok ? "all 6 shortcuts routed correctly (isolated + real tree)"
                      : (terminalShortcutError ? "Shift+Return (isolated) threw: " + terminalShortcutError
                        : realTreeError ? "Shift+Return (real tree) threw: " + realTreeError
                        : JSON.stringify(called)))
        })

        // Regression for P1-3 (architectural audit 2026-08-17):
        // core/DialogLayer.qml's onAuthSubmitted (network "connect to
        // server" auth dialog) calls Backend.NetworkResolver.submitAuth(),
        // but the file only imported qs.Commons/qs.Ui/../dialogs/../state --
        // same missing-import bug as KeyboardShortcuts.qml above, different
        // file. Exercises the REAL composition root (sc._content) by
        // emitting the real ConnectServer dialog's authSubmitted signal, not
        // a reimplementation.
        sc.add("DialogLayer: network auth submission resolves Backend.NetworkResolver (P1-3 regression)", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var authError = null
          try {
            c.dialogLayer.connectServer.authSubmitted("user", "pass", false)
          } catch (e) {
            authError = String(e)
          }
          done(!authError, authError ? "authSubmitted threw: " + authError : "Backend.NetworkResolver resolved correctly")
        })

        // ======================= P0-3 (forensic audit 2026-08-16) =======================
        // openFileInArchive() extracts a single archive member to
        // ~/.cache/omafiles/archive-open/<sha1(archivePath+member)>/<name> via a
        // plain shell `>` redirection. Before the fix, if an attacker could plant a
        // symlink at that fully-predictable (unsalted SHA-1, no randomness) path
        // BEFORE the victim opened the file, the redirection followed the symlink
        // and overwrote whatever it pointed to with the archive's (attacker-
        // controlled) content instead of creating a fresh file. This plants the
        // exact exploit and asserts the victim target survives untouched.
        sc.add("openFileInArchive: pre-planted symlink at the cache path is not followed (P0-3 regression)", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var zipPath = sc.opsDir + "/p03-archive.zip"
          var victim = sc.opsDir + "/p03-victim.txt"
          var buildCmd = "cd " + sc._q(sc.opsDir)
            + " && rm -rf p03src && mkdir p03src"
            + " && echo PWNED_CONTENT > p03src/secret.txt"
            + " && (cd p03src && zip -q " + sc._q(zipPath) + " secret.txt)"
            + " && rm -rf p03src"
            + " && echo VICTIM_UNTOUCHED > " + sc._q(victim)
          sc._sh(["bash", "-c", buildCmd], function (buildResult) {
            if (buildResult.exitCode !== 0) { done(false, "fixture build failed: " + buildResult.stderr); return }
            var outDir = Paths.homeDir + "/.cache/omafiles/archive-open/"
              + Backend.ThumbnailProvider.cacheKey(zipPath + "|secret.txt")
            var out = outDir + "/secret.txt"
            var plantCmd = "rm -rf -- " + sc._q(outDir) + " && mkdir -p -- " + sc._q(outDir)
              + " && ln -s -- " + sc._q(victim) + " " + sc._q(out)
            sc._sh(["bash", "-c", plantCmd], function (plantResult) {
              if (plantResult.exitCode !== 0) { done(false, "couldn't plant symlink: " + plantResult.stderr); return }
              c.archiveBrowser.enter(zipPath)
              c.archiveBrowser.openFile({ name: "secret.txt", type: "file" })
              // openFileInArchive is fire-and-forget (its own internal
              // ProcessRunner isn't exposed to the test); a tiny single-file
              // extraction settles in a few ms, 500ms is a generous margin.
              var timeout = Qt.createQmlObject('import QtQuick; Timer { interval: 500; repeat: false }', sc)
              timeout.triggered.connect(function () {
                c.archiveBrowser.exit()
                sc._sh(["bash", "-c", "cat -- " + sc._q(victim)], function (victimResult) {
                  var victimIntact = String(victimResult.stdout).trim() === "VICTIM_UNTOUCHED"
                  done(victimIntact, victimIntact
                    ? "victim file untouched — pre-planted symlink was destroyed and replaced before extraction"
                    : "VULNERABLE: the pre-planted symlink was followed, victim file now contains: " + String(victimResult.stdout).trim())
                })
              })
              timeout.start()
            })
          })
        })

        // ======================= V1.2 grid view =======================

        sc.add("ViewState.toggleMode() persists to ui-prefs.json (v1.2 grid view)", function (done) {
          var original = ViewState.mode
          var wasLoaded = ViewState.loaded
          // Persistence.qml's auto-save Connections only fires once
          // loadUiPrefs()'s async read has delivered (ViewState.loaded) --
          // the selfcheck composition root is deliberately never open()'d
          // (real load() calls live there, and selfcheck must not touch the
          // user's real persisted state), so `loaded` never flips true on
          // its own here. Forcing it true for this isolated check is the
          // same precondition a real running app reaches after startup.
          ViewState.loaded = true
          ViewState.toggleMode()
          var toggled = ViewState.mode
          if (toggled === original) { ViewState.loaded = wasLoaded; done(false, "toggleMode() didn't change mode"); return }
          // Backend.JsonStore.write() is synchronous (QSaveFile temp+rename)
          // -- the file is already written by the time toggleMode() returns
          // above, no polling/delay needed.
          sc._sh(["cat", "--", Paths.uiPrefsFile], function (r) {
            var ok = false
            try { ok = JSON.parse(r.stdout).viewMode === toggled } catch (e) { ok = false }
            ViewState.mode = original // restore regardless of outcome
            ViewState.loaded = wasLoaded
            done(ok, ok ? ("ui-prefs.json correctly saved viewMode=" + toggled)
                        : ("ui-prefs.json did not reflect the toggle: " + r.stdout))
          })
        })

        sc.add("SelectionState grid marquee selects a real row x column rectangle (v1.2 grid view)", function (done) {
          // visibleEntries is derived (readonly) from NavState.entries --
          // with no active searchQuery (the default) it's the SAME array,
          // so setting entries is what actually controls it here.
          var savedEntries = NavState.entries
          var savedQuery = NavState.searchQuery
          var savedMode = ViewState.mode
          var savedCols = ViewState.columnsPerRow
          var savedCW = ViewState.cellWidth
          var savedCH = ViewState.cellHeight
          function restore() {
            NavState.entries = savedEntries
            NavState.searchQuery = savedQuery
            ViewState.mode = savedMode
            ViewState.columnsPerRow = savedCols
            ViewState.cellWidth = savedCW
            ViewState.cellHeight = savedCH
            SelectionState.selectNone()
          }
          // 40 synthetic entries -- generous enough that whatever
          // columnsPerRow the REAL, live ActiveFileGrid instance settles on
          // (sc._content's own composition root reactively recomputes it
          // from ViewState.cellWidth, see ActiveFileGrid.qml's `cols`) still
          // has entries to select from; the marquee area below is small
          // enough it wouldn't cover all 40 regardless of column count.
          var synthetic = []
          for (var i = 0; i < 40; i++) synthetic.push({ name: "grid-fixture-" + i, type: "file" })
          NavState.searchQuery = "" // guarantee visibleEntries === entries below
          NavState.entries = synthetic
          ViewState.mode = "grid"
          ViewState.cellWidth = 100
          ViewState.cellHeight = 100 // plain assignment (not setCellWidth()) -- nothing else reactively owns this one

          SelectionState.startMarquee(50, 50, 50, false)
          SelectionState.moveMarquee(250, 150, 150, 100)
          var got = SelectionState.selectedIndices.slice().sort(function (a, b) { return a - b })
          // Computed from whatever ViewState.columnsPerRow actually is
          // right now (NOT a hardcoded 3): a live ActiveFileGrid instance
          // in sc._content reactively owns this property from its own real
          // width, same as it would in the running app -- this test
          // verifies updateMarqueeSelection()'s row x column math is
          // correct GIVEN the current columnsPerRow, not that
          // columnsPerRow holds one specific value nothing else may touch.
          var cols = Math.max(1, ViewState.columnsPerRow)
          var rowFrom = Math.floor(50 / 100), rowTo = Math.floor(150 / 100)
          var colFrom = Math.floor(50 / 100), colTo = Math.min(cols - 1, Math.floor(250 / 100))
          var expected = []
          for (var r = rowFrom; r <= rowTo; r++)
            for (var c = colFrom; c <= colTo; c++) {
              var idx = r * cols + c
              if (idx < synthetic.length) expected.push(idx)
            }
          SelectionState.endMarquee()
          var ok = got.length === expected.length && got.every(function (v, i) { return v === expected[i] })
          restore()
          done(ok, ok ? ("grid marquee selected " + JSON.stringify(got) + " as expected (cols=" + cols + ")")
                      : ("grid marquee selected " + JSON.stringify(got) + ", expected " + JSON.stringify(expected) + " (cols=" + cols + ")"))
        })

        // Real bug (josema, v1.2-dev): opening the preview of a file with
        // no matching content kind right after previewing one that DID
        // (e.g. an image) showed "No preview available" overlapping the
        // filename title. Root-caused empirically (dumped real y/height):
        // the title/separator/content blocks used to be flat siblings in
        // ONE Column, and Column's positioner does not reliably reflow
        // when several children's `visible` flip in the SAME tick (which
        // is exactly what happens here -- isImageEntry: true->false and
        // the "no preview" Column's condition: false->true, together).
        // Fixed by moving all the mutually-exclusive content kinds out of
        // that Column into a plain Item (contentArea) that doesn't
        // positioner-stack them at all. This test reproduces the EXACT
        // transition that triggered it, not just a static end-state
        // (earlier draft diagnostics that set every property once at
        // creation never reproduced the bug).
        sc.add("PreviewPanel: content area doesn't overlap the title after a mid-session content-kind transition (v1.2 regression)", function (done) {
          var comp = Qt.createComponent(Qt.resolvedUrl("../../../panels/PreviewPanel.qml"))
          if (comp.status === Component.Error) { done(false, comp.errorString()); return }
          var pp = comp.createObject(sc, {
            width: 400, height: 700, open: false, hasEntry: false,
            entryName: "some-other-file.png",
            isImageEntry: true, isVideoEntry: false, isTextEntry: false,
            isPdfEntry: false, isAudioEntry: false
          })
          if (!pp) { done(false, "createObject null"); return }
          var t = Qt.createQmlObject('import QtQuick; Timer { interval: 60; repeat: false }', sc)
          t.triggered.connect(function () {
            // The transition itself: several isXEntry flags flip in the
            // same tick, same as NavigationController/ActiveFileList.qml
            // switching the previewed entry to one with no preview kind.
            pp.open = true
            pp.hasEntry = true
            pp.entryName = "no-preview-file.WPE64"
            pp.isImageEntry = false
            var t2 = Qt.createQmlObject('import QtQuick; Timer { interval: 60; repeat: false }', sc)
            t2.triggered.connect(function () {
              var ok = pp.contentAreaItem.y >= pp.titleTextItem.y + pp.titleTextItem.height
              var msg = ok
                ? ("contentArea.y=" + pp.contentAreaItem.y + " correctly below title (y=" + pp.titleTextItem.y + " height=" + pp.titleTextItem.height + ")")
                : ("contentArea.y=" + pp.contentAreaItem.y + " OVERLAPS title (y=" + pp.titleTextItem.y + " height=" + pp.titleTextItem.height + ")")
              pp.destroy()
              t.destroy()
              t2.destroy()
              done(ok, msg)
            })
            t2.start()
          })
          t.start()
        })

        sc.add("ViewState.setCellWidth() clamps to [minCellWidth, maxCellWidth] and keeps aspect ratio (v1.2 Ctrl+scroll zoom)", function (done) {
          var savedW = ViewState.cellWidth
          var savedH = ViewState.cellHeight
          ViewState.setCellWidth(9999)
          var clampedHigh = ViewState.cellWidth === ViewState.maxCellWidth
          ViewState.setCellWidth(-9999)
          var clampedLow = ViewState.cellWidth === ViewState.minCellWidth
          ViewState.setCellWidth(140)
          var aspectOk = ViewState.cellHeight === Math.round(140 * (128 / 112))
          ViewState.cellWidth = savedW
          ViewState.cellHeight = savedH
          var ok = clampedHigh && clampedLow && aspectOk
          done(ok, ok ? "clamps correctly at both ends and derives cellHeight from the original aspect ratio"
                      : ("clampedHigh=" + clampedHigh + " clampedLow=" + clampedLow + " aspectOk=" + aspectOk))
        })

        // The trash round-trip checks (CheckFilesystemTrash, CheckActions)
        // leave ~54 fixture items in the REAL trash; until #29 the emptyTrash
        // check above removed them only by accident, together with the user's
        // own items. This sweeps them properly, and the origin path is the
        // safety rule: an entry whose .trashinfo Path= is NOT under a
        // ~/.cache/omafiles-selfcheck-* dir (no user file lives there) is the
        // user's data and is never touched -- and since that metadata is not
        // trusted to be canonical, a Path= containing "/../" is refused rather
        // than resolved. The prefix covers EVERY selfcheck temp dir, not just
        // this run's, so items left behind by a run that crashed or timed out
        // are reclaimed too. Registered last -- no check after this one
        // (CheckKeybindings included) touches the trash.
        sc.add("selfcheck leaves no fixture items in the real trash", function (done) {
          var prefix = sc.dir.replace(/omafiles-selfcheck-[^/]*$/, "omafiles-selfcheck-")
          var reqSeq = 0
          var active = true

          // Trash metadata is async since the P0 trash-freeze fix
          // (V1_1_P0_TRASH_FREEZE); each scan filters by its own request id.
          // A scan still pending when the runner's watchdog settles this check
          // would otherwise fire into the NEXT check (starting _seqOps, whose
          // _fileOp would steal that check's cleanup hook and signals), so
          // while one is in flight its disconnect is registered on
          // sc._activeFileOpCleanup -- called on every settle path -- and
          // `active` makes any late callback a no-op.
          function scanMine(cb) {
            var reqId = Date.now() + (reqSeq++)
            function cleanup() {
              active = false
              Backend.FileOperations.trashInfoReady.disconnect(onInfo)
              if (sc._activeFileOpCleanup === cleanup) sc._activeFileOpCleanup = null
            }
            function onInfo(id, info) {
              if (id !== reqId || !active) return
              Backend.FileOperations.trashInfoReady.disconnect(onInfo)
              if (sc._activeFileOpCleanup === cleanup) sc._activeFileOpCleanup = null
              var mine = []
              for (var i = 0; i < info.length; i++) {
                var orig = String(info[i].origPath)
                if (orig.indexOf(prefix) === 0 && orig.indexOf("/../") === -1) mine.push(info[i])
              }
              cb(mine)
            }
            Backend.FileOperations.trashInfoReady.connect(onInfo)
            sc._activeFileOpCleanup = cleanup
            Backend.FileOperations.requestTrashInfo(reqId)
          }

          scanMine(function (mine) {
            if (mine.length === 0) { done(true, "swept 0 fixture items"); return }
            // No batch remove() in FileOperations.h -- one op per path,
            // sequenced (files/<name> and info/<name>.trashinfo per entry).
            var starts = []
            for (var i = 0; i < mine.length; i++) {
              (function (e) {
                starts.push(function () { Backend.FileOperations.remove(e.trashRoot + "/files/" + e.name, true) })
                starts.push(function () { Backend.FileOperations.remove(e.trashRoot + "/info/" + e.name + ".trashinfo", true) })
              })(mine[i])
            }
            sc._seqOps(starts, done, function () {
              scanMine(function (left) {
                if (!active) return
                done(left.length === 0, left.length === 0
                  ? "swept " + mine.length + " fixture items"
                  : left.length + " fixture items still in trash")
              })
            })
          })
        })
  }
}

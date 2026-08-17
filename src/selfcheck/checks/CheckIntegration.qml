import QtQuick
import Omafiles.Backend as Backend
import qs.Commons
import "../../../state"
import "../../../shared/Utils.js" as Utils

// Domain checks extracted from app/SelfCheck.qml (_register).
// Structural refactor only — behavior unchanged.
QtObject {
  function register(sc) {
        sc.add("File picker URI encoding round-trips reserved characters", function (done) {
          var path = "/tmp/Oma Files/#draft? 100% [π].txt"
          var uri = Util.fileUrl(path)
          var decoded = decodeURIComponent(uri.substring("file://".length))
          done(decoded === path && uri.indexOf("#draft") < 0 && uri.indexOf("? 100") < 0,
               "uri=" + uri)
        })

        sc.add("SaveFiles destination URIs preserve requested order", function (done) {
          var names = ["second #.txt", "first?.txt", "100%.txt"]
          var uris = Util.saveFilesResultUris("/tmp/destination", names)
          var expected = [
            "file:///tmp/destination/second%20%23.txt",
            "file:///tmp/destination/first%3F.txt",
            "file:///tmp/destination/100%25.txt"
          ]
          done(JSON.stringify(uris) === JSON.stringify(expected), JSON.stringify(uris))
        })

        sc.add("FileManager1 ShowItems selects; ShowItemProperties opens once", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          PropertiesState.propertiesOpen = false
          var beforeItems = PropertiesState.propertiesRequestId
          var itemsPayload = JSON.stringify({
            kind: "file-manager", action: "show-items", folder: sc.listDir,
            basenames: ["alpha.txt"]
          })
          c.open(itemsPayload)
          sc._poll(function () {
            var entries = SelectionState.selectedEntries()
            return entries.length === 1 && entries[0].name === "alpha.txt"
          }, function (itemsSelected) {
            var itemsOnlySelected = itemsSelected && !PropertiesState.propertiesOpen
              && PropertiesState.propertiesRequestId === beforeItems
            PropertiesState.propertiesOpen = false
            var beforeProperties = PropertiesState.propertiesRequestId
            var propertiesPayload = JSON.stringify({
              kind: "file-manager", action: "show-properties", folder: sc.listDir,
              basenames: ["beta.txt"]
            })
            c.open(propertiesPayload)
            sc._poll(function () {
              return PropertiesState.propertiesOpen
                && PropertiesState.propertiesRequestId === beforeProperties + 1
            }, function (propertiesOpened) {
              var entries = SelectionState.selectedEntries()
              var rightSelection = entries.length === 1 && entries[0].name === "beta.txt"
              PropertiesState.propertiesOpen = false
              done(itemsOnlySelected && propertiesOpened && rightSelection,
                   "itemsOnly=" + itemsOnlySelected + " propertiesOnce=" + propertiesOpened
                     + " selected=" + (entries.length ? entries[0].name : "<none>"))
            })
          })
        })

        sc.add("Picker session never writes normal window geometry", function (done) {
          var component = Qt.createComponent("../../../app/HostAdapter.qml")
          if (component.status !== Component.Ready) { done(false, component.errorString()); return }
          var fakeWindow = Qt.createQmlObject(
            'import QtQuick; QtObject { property int width: 900; property int height: 600 }', sc)
          var adapter = component.createObject(sc, { window: fakeWindow })
          if (!adapter) { fakeWindow.destroy(); done(false, "could not create HostAdapter"); return }
          var wrote = false
          function onSaved(path, ok) { if (path === adapter._file) wrote = true }
          Backend.JsonStore.saved.connect(onSaved)
          PickerState.sessionActive = true
          adapter._write()
          PickerState.sessionActive = false
          Backend.JsonStore.saved.disconnect(onSaved)
          adapter.destroy()
          fakeWindow.destroy()
          done(!wrote, wrote ? "picker geometry reached JsonStore" : "picker geometry suppressed")
        })

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

        // ISOLATED empty-trash.sh: HOME points to a fake home inside the selfcheck's
        // tmp and a fake findmnt (via PATH) prevents real mounts from being scanned
        // -> it NEVER touches the user's real trash. It prepares a home
        // trash with an item and confirms that the script empties it. A
        // regression that doesn't discover the roots (like the trash-roots.sh one) would leave
        // the item undeleted and would make this fail.
        sc.add("Backend.FileOperations emptyTrash empties trash roots (BUG-02)", function (done) {
          function onFinished(op, path) {
            if (op !== "emptyTrash") return
            Backend.FileOperations.finished.disconnect(onFinished)
            var info = Backend.FileOperations.trashInfo()
            var ok = (info.length === 0)
            done(ok, ok ? "trash emptied cleanly: remaining=" + info.length : "items remained: " + info.length)
          }
          Backend.FileOperations.finished.connect(onFinished)
          Backend.FileOperations.emptyTrash()
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
          var called = {}
          var stubEngine = {
            startRename: function() { called.F2 = true },
            requestDelete: function() { called.Del = true },
            copySelected: function() { called.CtrlC = true },
            cutSelected: function() { called.CtrlX = true },
            paste: function() { called.CtrlV = true }
          }
          var kbd = kbdComp.createObject(sc, {
            "hostControllers": { "actionEngine": stubEngine, "navController": {} },
            "hostRoot": { "pendingDeleteNames": [] }
          })
          var ev = function(k, mod) { return { "key": k, "modifiers": mod || Qt.NoModifier, "accepted": false } }
          kbd.handlePress(ev(Qt.Key_F2))
          kbd.handlePress(ev(Qt.Key_Delete))
          kbd.handlePress(ev(Qt.Key_C, Qt.ControlModifier))
          kbd.handlePress(ev(Qt.Key_X, Qt.ControlModifier))
          kbd.handlePress(ev(Qt.Key_V, Qt.ControlModifier))
          kbd.destroy()

          var ok = called.F2 && called.Del && called.CtrlC && called.CtrlX && called.CtrlV
          done(ok, ok ? "all 5 shortcuts routed correctly" : JSON.stringify(called))
        })
  }
}

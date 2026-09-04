import QtQuick
import Omafiles.Backend as Backend
import "../../../state"
import "../../../shared/Utils.js" as Utils

// Domain checks extracted from app/SelfCheck.qml (_register).
// Structural refactor only — behavior unchanged.
QtObject {
  function register(sc) {
        sc.add("Backend.JsonStore write/read round-trip", function (done) {
          var payload = { a: 1, b: "x", nested: { k: [1, 2, 3] } }
          function onSaved(path, ok) {
            Backend.JsonStore.saved.disconnect(onSaved)
            if (!ok) { done(false, "write failed"); return }
            function onLoaded(p, data, lok) {
              Backend.JsonStore.loaded.disconnect(onLoaded)
              if (!lok) { done(false, "read failed"); return }
              var good = data && data.a === 1 && data.b === "x"
                && data.nested && data.nested.k.length === 3
              done(good, good ? "" : "data doesn't match: " + JSON.stringify(data))
            }
            Backend.JsonStore.loaded.connect(onLoaded)
            Backend.JsonStore.read(sc.jsonFile)
          }
          Backend.JsonStore.saved.connect(onSaved)
          Backend.JsonStore.write(sc.jsonFile, payload)
        })

        // Saved network-connection profiles (V1.1, headline #4). Exercises
        // the REAL BookmarksState.addNetworkProfile()/removeNetworkProfile()
        // mutators (dedupe-and-move-to-front, cap, remove) AND a real
        // on-disk round-trip via Paths.networkProfilesFile -- not a scratch
        // path, since that's the whole point of testing the real function.
        // This is the user's actual state file, so it's backed up first and
        // restored afterward (file content + in-memory
        // BookmarksState.networkProfiles), same "swap, verify, restore"
        // discipline as this session's installed-vs-build-tree .so backups.
        //
        // Crash/timeout-safe (cleanup pass): the restore used to only run
        // at the end of the normal success/failure path -- if this test
        // threw or its 8s timeout fired first, the real file (and
        // BookmarksState.networkProfiles in memory) stayed holding this
        // test's fixture data instead of the user's real saved profiles.
        // sc._activeFileOpCleanup is SelfCheckRunner's existing guaranteed
        // hook for exactly this (already relied on by sc._fileOp; see its
        // own doc comment there) -- _done() calls it unconditionally on
        // every settle path (pass, fail, exception, or timeout), so
        // registering the restore there once covers all of them instead of
        // only the one normal-completion call site.
        sc.add("BookmarksState network profiles: dedupe, remove, real on-disk round-trip (V1.1 regression)", function (done) {
          var realPath = Paths.networkProfilesFile
          var prevMemory = BookmarksState.networkProfiles

          function onBackupRead(path, data, ok) {
            if (path !== realPath) return
            Backend.JsonStore.loaded.disconnect(onBackupRead)
            var backupExisted = ok
            var backupData = data
            var restored = false

            function doRestore() {
              if (restored) return
              restored = true
              BookmarksState.networkProfiles = prevMemory
              if (backupExisted) Backend.JsonStore.write(realPath, backupData)
              else Backend.Detached.run(["rm", "-f", realPath])
            }
            sc._activeFileOpCleanup = doRestore

            function restoreAndFinish(pass, msg) {
              doRestore()
              if (sc._activeFileOpCleanup === doRestore) sc._activeFileOpCleanup = null
              done(pass, msg)
            }

            BookmarksState.networkProfiles = []
            var savedCount = 0
            function onSavedTick(p, sok) {
              if (p !== realPath) return
              savedCount += 1
            }
            Backend.JsonStore.saved.connect(onSavedTick)

            BookmarksState.addNetworkProfile("sftp://a@host1/path")
            BookmarksState.addNetworkProfile("sftp://b@host2/path")
            BookmarksState.addNetworkProfile("sftp://a@host1/path") // duplicate: moves to front, doesn't duplicate
            var dedupeOk = BookmarksState.networkProfiles.length === 2
              && BookmarksState.networkProfiles[0] === "sftp://a@host1/path"
              && BookmarksState.networkProfiles[1] === "sftp://b@host2/path"

            BookmarksState.removeNetworkProfile("sftp://b@host2/path")
            var removeOk = BookmarksState.networkProfiles.length === 1
              && BookmarksState.networkProfiles[0] === "sftp://a@host1/path"

            sc._poll(function () { return savedCount >= 4 }, function (allSaved) {
              Backend.JsonStore.saved.disconnect(onSavedTick)
              if (!allSaved) { restoreAndFinish(false, "writes never landed (savedCount=" + savedCount + ")"); return }

              function onFinalRead(p2, data2, ok2) {
                if (p2 !== realPath) return
                Backend.JsonStore.loaded.disconnect(onFinalRead)
                var roundTripOk = ok2 && Array.isArray(data2) && data2.length === 1 && data2[0] === "sftp://a@host1/path"
                var pass = dedupeOk && removeOk && roundTripOk
                restoreAndFinish(pass, pass ? "dedupe/remove logic correct and real disk state matches"
                  : "dedupeOk=" + dedupeOk + " removeOk=" + removeOk + " roundTripOk=" + roundTripOk + " disk=" + JSON.stringify(data2))
              }
              Backend.JsonStore.loaded.connect(onFinalRead)
              Backend.JsonStore.read(realPath)
            })
          }
          Backend.JsonStore.loaded.connect(onBackupRead)
          Backend.JsonStore.read(realPath)
        })

        // ui-prefs.json now carries the sort key/direction and the dotfiles
        // toggle next to the view mode: restored by Persistence's loaded
        // handler, saved by its new Connections. No file back-up needed (the
        // state dir is the harness's temp dir), but the in-memory values are
        // reset afterwards -- later checks assume the default name/asc order.
        sc.add("ui-prefs: sort + hidden restore and save round-trip", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var path = Paths.uiPrefsFile
          var reset = false

          function doReset() {
            if (reset) return
            reset = true
            SortState.sortKey = "name"
            SortState.sortDesc = false
            NavState.showHidden = false
            c.controllers.navController.refresh()
          }
          sc._activeFileOpCleanup = doReset

          function resetAndFinish(pass, msg) {
            doReset()
            if (sc._activeFileOpCleanup === doReset) sc._activeFileOpCleanup = null
            done(pass, msg)
          }

          function onFixtureSaved(p, sok) {
            if (p !== path) return
            Backend.JsonStore.saved.disconnect(onFixtureSaved)
            if (!sok) { resetAndFinish(false, "fixture write failed"); return }
            c.controllers.persistence.loadUiPrefs()
            sc._poll(function () {
              return SortState.sortKey === "size" && SortState.sortDesc && NavState.showHidden
            }, function (applied) {
              if (!applied) {
                resetAndFinish(false, "not restored from disk: sortKey=" + SortState.sortKey
                  + " sortDesc=" + SortState.sortDesc + " showHidden=" + NavState.showHidden)
                return
              }
              // Save side: this change goes through the new Connections on
              // SortState, and JsonStore.write is synchronous, so the file is
              // already updated by the time the read below is queued.
              SortState.sortDesc = false
              function onFinalRead(p2, data2, ok2) {
                if (p2 !== path) return
                Backend.JsonStore.loaded.disconnect(onFinalRead)
                var pass = ok2 && data2 && data2.sortKey === "size"
                  && data2.sortDesc === false && data2.showHidden === true
                resetAndFinish(pass, pass ? "sort key/direction and hidden toggle survive a round-trip"
                  : "disk doesn't match after save: " + JSON.stringify(data2))
              }
              Backend.JsonStore.loaded.connect(onFinalRead)
              Backend.JsonStore.read(path)
            })
          }
          Backend.JsonStore.saved.connect(onFixtureSaved)
          Backend.JsonStore.write(path, { viewMode: ViewState.mode, cellWidth: ViewState.cellWidth,
            sortKey: "size", sortDesc: true, showHidden: true })
        })
  }
}

import QtQuick
import Omafiles.Backend as Backend
import "../../../state"
import "../../../shared/Utils.js" as Utils

// Domain checks extracted from app/SelfCheck.qml (_register).
// Structural refactor only — behavior unchanged.
QtObject {
  function register(sc) {
        sc.add("Background panel refreshes on content change (non-active tab)", function (done) {
          var c = sc._content
          if (!c) { done(false, "no _content"); return }
          var bgDir = sc.dir + "/bgpanel-" + Date.now()

          Backend.FileOperations.mkdir(bgDir)
          sc._fileOp(done, function () {                    // bgDir created (empty)
            // Real SortOps: with default SortState (name/asc) isDefaultOrder is
            // true, so _sorted returns the entries as is without touching
            // fileTypeUtils/root (that's why they can be null). panelsRow is a stub
            // for the geometries; slotWidth/height 0 => the ListView doesn't instantiate
            // delegates and no null visual dependencies are touched.
            var panelsRow = sc._panelsRowStub.createObject(sc)
            var bgC = Qt.createComponent(Qt.resolvedUrl("../../../panels/BackgroundPanel.qml"))
            if (bgC.status !== Component.Ready) { done(false, "BackgroundPanel: " + bgC.errorString()); return }
            // index 1 != activeTabIndex 0 => visible (NON-active tab), which is
            // exactly the condition of the refreshMe() guard.
            TabsState.activeTabIndex = 0
            var bg = bgC.createObject(sc, {
              modelData: { path: bgDir }, index: 1, hostRoot: sc._content, hostPanelsRow: panelsRow,
            })
            if (!bg) { panelsRow.destroy(); done(false, "BackgroundPanel null"); return }

            function cleanup() { bg.destroy(); panelsRow.destroy() }
            function cache() { return c.tabEntriesCache[bgDir] }

            // 1) wait for the initial listing (onCompleted -> refreshMe, a direct
            //    call, not via the Connections) to populate the cache with the empty folder.
            sc._poll(function () { return cache() !== undefined && cache().length === 0 }, function (ok0) {
              if (!ok0) { cleanup(); done(false, "the panel didn't list the initial empty folder"); return }
              // 2) mutate the folder and trigger the refresh ONLY via refreshTick.
              Backend.FileOperations.copy(sc.note, bgDir + "/appeared.txt")
              sc._fileOp(done, function () {
                NavState.refreshTick += 1
                // 3) the background panel must re-list and reflect the new file.
                //    If the Connections is broken, the cache stays empty -> timeout.
                sc._poll(function () { var e = cache(); return e && sc._has(e, "appeared.txt") }, function (ok) {
                  // bgDir lives inside the harness's QTemporaryDir (main.cpp
                  // deletes it on exit); NO async remove is launched here -- a
                  // fire-and-forget in the last test runs concurrent with the
                  // QTemporaryDir cleanup and aborts its removeRecursively.
                  cleanup()
                  done(ok, ok ? "the background panel reflected the change via refreshTick"
                              : "the background panel did NOT refresh after refreshTick (broken Connections)")
                })
              })
            })
          })
        })
  }
}

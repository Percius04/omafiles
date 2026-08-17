import QtQuick
import Omafiles.Backend as Backend
import "../../../state"
import "../../../shared/Utils.js" as Utils

// Domain checks extracted from app/SelfCheck.qml (_register).
// Structural refactor only — behavior unchanged.
QtObject {
  function register(sc) {
        sc.add("Backend.DirectoryModel list + natural order", function (done) {
          sc._listOnce(sc.listDir, function (e) {
            var names = e.map(function (x) { return x.name })
            // 3 files + 1 subfolder; folders first, then naturalCompare.
            var okCount = e.length === 4
            var okOrder = names[0] === "sub" && names[1] === "alpha.txt"
              && names[2] === "beta.txt" && names[3] === "gamma.txt"
            done(okCount && okOrder, "order=[" + names.join(", ") + "]")
          })
        })

        sc.add("QFileSystemWatcher create event", function (done) {
          var m = sc._dmFactory.createObject(sc)
          var watched = m.watch(sc.watchDir)
          if (!watched) { m.destroy(); done(false, "watch() returned false"); return }
          // Waits for BOTH: the watcher's directoryChanged and the finished of the mkdir
          // trigger (consumed so as not to leak it to later tests).
          var gotChange = false, gotFinish = false, settled = false
          function finish(ok, msg) {
            if (settled) return
            settled = true
            m.directoryChanged.disconnect(onChanged)
            m.unwatch(); m.destroy()
            done(ok, msg)
          }
          function maybe() { if (gotChange && gotFinish) finish(true, "directoryChanged after creating subfolder") }
          function onChanged() { gotChange = true; maybe() }
          m.directoryChanged.connect(onChanged)
          sc._fileOp(function (ok, msg) { finish(false, "mkdir trigger: " + msg) },
                     function () { gotFinish = true; maybe() })
          Backend.FileOperations.mkdir(sc.watchDir + "/trigger")
        })
  }
}

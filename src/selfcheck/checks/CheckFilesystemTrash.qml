import QtQuick
import Omafiles.Backend as Backend
import "../../../state"
import "../../../shared/Utils.js" as Utils

// Trash & conflict detection domain checks.
// Structural refactor only — behavior unchanged.
QtObject {
  function register(sc) {
        sc.add("Trash removes item from source", function (done) {
          var work = sc.opsDir + "/trash-src.txt"
          sc._seqOps([
            function () { Backend.FileOperations.copy(sc.note, work) },
            function () { Backend.FileOperations.trash(work) }
          ], done, function () {
            sc._listOnce(sc.opsDir, function (e) {
              var gone = !sc._has(e, "trash-src.txt")
              sc._seqOps([function () { Backend.FileOperations.restoreByOrigPath(work) }], done, function () {
                sc._listOnce(sc.opsDir, function (e2) {
                  done(gone && sc._has(e2, "trash-src.txt"),
                       gone ? "sent and restored" : "didn't leave the source")
                })
              })
            })
          })
        })

        sc.add("ActionEngine trash+restore end-to-end (frontend wiring)", function (done) {
          var aeComp = Qt.createComponent(Qt.resolvedUrl("../../../logic/ActionEngine.qml"))
          if (aeComp.status === Component.Error) { done(false, aeComp.errorString()); return }
          var stubNav = Qt.createQmlObject('import QtQuick; Item { function refresh() {} }', sc)
          var ae = aeComp.createObject(sc, { "navController": stubNav })
          if (!ae) { done(false, "couldn't create ActionEngine"); return }
          var work = sc.opsDir + "/ae-trash-" + Date.now() + ".txt"
          var wname = work.substring(work.lastIndexOf("/") + 1)
          sc._seqOps([function () { Backend.FileOperations.copy(sc.note, work) }], done, function () {
            ae.runNativeTrash([work], "", function () {
              sc._listOnce(sc.opsDir, function (e) {
                var gone = !sc._has(e, wname)
                ae.runNativeRestore([work], "", function () {
                  sc._listOnce(sc.opsDir, function (e2) {
                    var back = sc._has(e2, wname)
                    ae.destroy(); stubNav.destroy()
                    done(gone && back, gone ? (back ? "trash+restore via ActionEngine OK" : "restore didn't put the file back")
                                            : "runNativeTrash didn't take the file out of the source")
                  })
                })
              })
            })
          })
        })

        sc.add("Trash + restore directory (round-trip)", function (done) {
          var dir = sc.opsDir + "/trashdir"
          sc._seqOps([
            function () { Backend.FileOperations.copy(sc.listDir, dir) },
            function () { Backend.FileOperations.trash(dir) },
            function () { Backend.FileOperations.restoreByOrigPath(dir) }
          ], done, function () {
            sc._listOnce(dir, function (e) {
              done(e.length === 4 && sc._has(e, "sub"), "tree restored: " + e.length)
            })
          })
        })

        sc.add("Trash + restore symlink (round-trip)", function (done) {
          var lnk = sc.opsDir + "/trashlink"
          sc._seqOps([
            function () { Backend.FileOperations.copy(sc.dir + "/link.txt", lnk) },
            function () { Backend.FileOperations.trash(lnk) },
            function () { Backend.FileOperations.restoreByOrigPath(lnk) }
          ], done, function () {
            sc._listOnce(sc.opsDir, function (e) {
              var ok = false
              for (var i = 0; i < e.length; i++)
                if (e[i].name === "trashlink" && e[i].link && e[i].link.length > 0) ok = true
              done(ok, ok ? "symlink restored as a link" : "didn't come back as a symlink")
            })
          })
        })

        sc.add("Trash + restore Unicode name (round-trip)", function (done) {
          var uni = sc.opsDir + "/café ñ 文件.txt"
          sc._seqOps([
            function () { Backend.FileOperations.copy(sc.note, uni) },
            function () { Backend.FileOperations.trash(uni) },
            function () { Backend.FileOperations.restoreByOrigPath(uni) }
          ], done, function () {
            sc._listOnce(sc.opsDir, function (e) {
              done(sc._has(e, "café ñ 文件.txt"), "unicode round-trip OK")
            })
          })
        })

        sc.add("Trash collision (restore both by orig path)", function (done) {
          var csub = sc.opsDir + "/csub"
          var a = sc.opsDir + "/coll.txt"
          var b = csub + "/coll.txt"
          sc._seqOps([
            function () { Backend.FileOperations.mkdir(csub) },
            function () { Backend.FileOperations.copy(sc.note, a) },
            function () { Backend.FileOperations.copy(sc.note, b) },
            function () { Backend.FileOperations.trash(a) },
            function () { Backend.FileOperations.trash(b) },
            function () { Backend.FileOperations.restoreByOrigPath(a) },
            function () { Backend.FileOperations.restoreByOrigPath(b) }
          ], done, function () {
            sc._listOnce(sc.opsDir, function (e) {
              var aBack = sc._has(e, "coll.txt")
              sc._listOnce(csub, function (e2) {
                var bBack = sc._has(e2, "coll.txt")
                done(aBack && bBack, aBack && bBack ? "collision resolved, both restored" : "didn't restore both")
              })
            })
          })
        })

        sc.add("Restore collision (destination exists -> error)", function (done) {
          var work = sc.opsDir + "/restcoll.txt"
          sc._seqOps([
            function () { Backend.FileOperations.copy(sc.note, work) },
            function () { Backend.FileOperations.trash(work) },
            function () { Backend.FileOperations.copy(sc.note, work) }
          ], done, function () {
            function onErr(op, path, msg) {
              if (path !== work) return
              cleanup()
              sc._seqOps([
                function () { Backend.FileOperations.remove(work) },
                function () { Backend.FileOperations.restoreByOrigPath(work) }
              ], done, function () { done(true, "error if the destination exists: " + msg) })
            }
            function onFin(op, path) { if (path !== work) return; cleanup(); done(false, "should not restore over an existing destination") }
            function cleanup() { Backend.FileOperations.error.disconnect(onErr); Backend.FileOperations.finished.disconnect(onFin) }
            Backend.FileOperations.error.connect(onErr)
            Backend.FileOperations.finished.connect(onFin)
            Backend.FileOperations.restoreByOrigPath(work)
          })
        })

        sc.add("Restore recreates missing parent", function (done) {
          var psub = sc.opsDir + "/psub"
          var item = psub + "/child.txt"
          sc._seqOps([
            function () { Backend.FileOperations.mkdir(psub) },
            function () { Backend.FileOperations.copy(sc.note, item) },
            function () { Backend.FileOperations.trash(item) },
            function () { Backend.FileOperations.remove(psub) },
            function () { Backend.FileOperations.restoreByOrigPath(item) }
          ], done, function () {
            sc._listOnce(psub, function (e) {
              done(sc._has(e, "child.txt"), "parent recreated and file restored")
            })
          })
        })

        sc.add("ActionEngine native trash runner + undo (delete-to-trash path)", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var work = sc.opsDir + "/runner-trash.txt"
          sc._fileOp(done, function () {
            var started = c.actionEngine.runNativeTrash([work], "", function () {
              c.actionEngine.pushUndo("delete test",
                function () { return c.actionEngine.runNativeRestore([work], "") },
                function () { return c.actionEngine.runNativeTrash([work], "") })
              sc._listOnce(sc.opsDir, function (e) {
                if (sc._has(e, "runner-trash.txt")) { done(false, "wasn't sent to trash"); return }
                sc._fileOp(done, function () {
                  sc._listOnce(sc.opsDir, function (e2) {
                    done(sc._has(e2, "runner-trash.txt"), "sent and restored by undo")
                  })
                })
                c.undoLast()
              })
            })
            if (!started) done(false, "runNativeTrash returned false")
          })
          Backend.FileOperations.copy(sc.note, work)
        })

        sc.add("Trash + restore from symlinked directory (path normalization)", function (done) {
          var realTargetDir = sc.dir + "/sym-real-dir"
          var symlinkDir = sc.dir + "/sym-link-dir"
          var symFile = symlinkDir + "/sym-target.txt"
          var realFile = realTargetDir + "/sym-target.txt"
          sc._seqOps([
            function () { Backend.FileOperations.mkdir(realTargetDir) },
            function () {
              sc._sh(["ln", "-s", realTargetDir, symlinkDir], function (r) {
                if (r.exitCode !== 0) { done(false, "symlink setup failed"); return }
                Backend.FileOperations.copy(sc.note, realFile)
              })
            }
          ], done, function () {
            Backend.FileOperations.trash(symFile)
            var timer = Qt.createQmlObject('import QtQuick; Timer { interval: 40; repeat: false }', sc)
            timer.triggered.connect(function () {
              Backend.FileOperations.restoreByOrigPath(symFile)
              var timer2 = Qt.createQmlObject('import QtQuick; Timer { interval: 40; repeat: false }', sc)
              timer2.triggered.connect(function () {
                sc._listOnce(realTargetDir, function (entries) {
                  var restored = sc._has(entries, "sym-target.txt")
                  done(restored, restored ? "restored via symlink path OK" : "restore by symlink path failed")
                })
              })
              timer2.start()
            })
            timer.start()
          })
        })

        sc.add("Conflict detection: existingPaths (file/dir/symlink)", function (done) {
          var f = sc.opsDir + "/cd-file.txt"
          var d = sc.opsDir + "/cd-dir"
          var l = sc.opsDir + "/cd-link"
          var missing = sc.opsDir + "/cd-missing-" + Date.now()
          sc._seqOps([
            function () { Backend.FileOperations.copy(sc.note, f) },
            function () { Backend.FileOperations.copy(sc.listDir, d) },
            function () { Backend.FileOperations.copy(sc.dir + "/link.txt", l) }
          ], done, function () {
            var res = Backend.FileOperations.existingPaths([f, d, l, missing])
            var ok = res.length === 3 && res.indexOf(f) >= 0 && res.indexOf(d) >= 0 &&
                     res.indexOf(l) >= 0 && res.indexOf(missing) < 0
            done(ok, "detected " + res.length + "/3 (without the nonexistent one)")
          })
        })

        sc.add("Copy conflict overwrite (directory replaces)", function (done) {
          var src = sc.opsDir + "/ccd-src"
          var dst = sc.opsDir + "/ccd-dst"
          sc._seqOps([
            function () { Backend.FileOperations.copy(sc.listDir, src) },
            function () { Backend.FileOperations.mkdir(dst) },
            function () { Backend.FileOperations.copy(src, dst, true) }
          ], done, function () {
            sc._listOnce(dst, function (e) {
              done(e.length === 4 && sc._has(e, "sub"), "dir replaced: " + e.length + " entries")
            })
          })
        })

        sc.add("Copy conflict without overwrite errors (skip semantics)", function (done) {
          var dst = sc.opsDir + "/ccs.txt"
          sc._seqOps([function () { Backend.FileOperations.copy(sc.note, dst) }], done, function () {
            function onErr(op, path, msg) { cleanup(); done(msg.indexOf("exists") >= 0, "error: " + msg) }
            function onFin(op, path) { cleanup(); done(false, "should not copy over existing without overwrite") }
            function cleanup() { Backend.FileOperations.error.disconnect(onErr); Backend.FileOperations.finished.disconnect(onFin) }
            Backend.FileOperations.error.connect(onErr)
            Backend.FileOperations.finished.connect(onFin)
            Backend.FileOperations.copy(sc.note, dst)
          })
        })

        sc.add("Move conflict without overwrite errors (skip semantics)", function (done) {
          var work = sc.opsDir + "/mcs-work.txt"
          var dst = sc.opsDir + "/mcs-dst.txt"
          sc._seqOps([
            function () { Backend.FileOperations.copy(sc.note, work) },
            function () { Backend.FileOperations.copy(sc.note, dst) }
          ], done, function () {
            function onErr(op, path, msg) { cleanup(); done(msg.indexOf("exists") >= 0, "error: " + msg) }
            function onFin(op, path) { cleanup(); done(false, "should not move over existing without overwrite") }
            function cleanup() { Backend.FileOperations.error.disconnect(onErr); Backend.FileOperations.finished.disconnect(onFin) }
            Backend.FileOperations.error.connect(onErr)
            Backend.FileOperations.finished.connect(onFin)
            Backend.FileOperations.move(work, dst)
          })
        })

        sc.add("Conflict overwrite replaces symlink dest", function (done) {
          var l = sc.opsDir + "/cos-link"
          sc._seqOps([
            function () { Backend.FileOperations.copy(sc.dir + "/link.txt", l) },
            function () { Backend.FileOperations.copy(sc.note, l, true) }
          ], done, function () {
            sc._listOnce(sc.opsDir, function (e) {
              var isFileNow = false
              for (var i = 0; i < e.length; i++)
                if (e[i].name === "cos-link") isFileNow = (!e[i].link || e[i].link.length === 0)
              done(isFileNow, isFileNow ? "symlink replaced by file" : "still a symlink")
            })
          })
        })
  }
}

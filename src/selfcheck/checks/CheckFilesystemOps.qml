import QtQuick
import Omafiles.Backend as Backend
import "../../../state"
import "../../../shared/Utils.js" as Utils

// Filesystem basic operations domain checks.
// Structural refactor only — behavior unchanged.
QtObject {
  function register(sc) {
        sc.add("Backend.FileOperations mkdir", function (done) {
          sc._fileOp(done, function (op, path) {
            sc._listOnce(sc.opsDir, function (e) {
              var ok = sc._has(e, "newdir")
              done(ok, ok ? "" : "newdir doesn't appear")
            })
          })
          Backend.FileOperations.mkdir(sc.opsDir + "/newdir")
        })

        sc.add("Backend.FileOperations rename", function (done) {
          Backend.FileOperations.copy(sc.note, sc.opsDir + "/toRename.txt")
          sc._fileOp(done, function () {
            sc._fileOp(done, function () {
              sc._listOnce(sc.opsDir, function (e) {
                var ok = sc._has(e, "renamed.txt") && !sc._has(e, "toRename.txt")
                done(ok, ok ? "" : "rename not reflected")
              })
            })
            Backend.FileOperations.rename(sc.opsDir + "/toRename.txt", "renamed.txt")
          })
        })

        sc.add("Backend.FileOperations copy", function (done) {
          sc._fileOp(done, function () {
            sc._listOnce(sc.opsDir, function (e) {
              var ok = sc._has(e, "copy.txt")
              done(ok, ok ? "" : "copy.txt doesn't appear")
            })
          })
          Backend.FileOperations.copy(sc.note, sc.opsDir + "/copy.txt")
        })

        sc.add("Backend.FileOperations copy overwrite (replace)", function (done) {
          var dst = sc.opsDir + "/ow.txt"
          sc._fileOp(done, function () {
            sc._fileOp(done, function () { done(true, "destination replaced") })
            Backend.FileOperations.copy(sc.note, dst, true)
          })
          Backend.FileOperations.copy(sc.note, dst)
        })

        sc.add("Backend.FileOperations copy directory (recursive)", function (done) {
          sc._fileOp(done, function () {
            sc._listOnce(sc.opsDir + "/listcopy", function (e) {
              var ok = e.length === 4 && sc._has(e, "sub") && sc._has(e, "alpha.txt")
              done(ok, ok ? e.length + " entries copied" : "incomplete tree")
            })
          })
          Backend.FileOperations.copy(sc.listDir, sc.opsDir + "/listcopy")
        })

        sc.add("Backend.FileOperations copy symlink preserved", function (done) {
          sc._fileOp(done, function () {
            sc._listOnce(sc.opsDir, function (e) {
              var ok = false
              for (var i = 0; i < e.length; i++)
                if (e[i].name === "linkcopy" && e[i].link && e[i].link.length > 0) ok = true
              done(ok, ok ? "copied as a link" : "didn't stay a symlink")
            })
          })
          Backend.FileOperations.copy(sc.dir + "/link.txt", sc.opsDir + "/linkcopy")
        })

        sc.add("Backend.FileOperations copy preserves permissions", function (done) {
          var srcPerm = Backend.PreviewProvider.info(sc.note).permissions
          sc._fileOp(done, function () {
            var dstPerm = Backend.PreviewProvider.info(sc.opsDir + "/permcopy").permissions
            var ok = srcPerm && dstPerm && srcPerm === dstPerm
            done(ok, "src=" + srcPerm + " dst=" + dstPerm)
          })
          Backend.FileOperations.copy(sc.note, sc.opsDir + "/permcopy")
        })

        sc.add("ActionEngine native copy runner (paste/drop path)", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var dst = sc.opsDir + "/enginecopy.txt"
          var started = c.actionEngine.runNativeCopy([{ src: sc.note, dest: dst }], "Copying…", false, function () {
            sc._listOnce(sc.opsDir, function (e) {
              var ok = sc._has(e, "enginecopy.txt")
              done(ok, ok ? "runNativeCopy OK" : "didn't copy")
            })
          })
          if (!started) done(false, "runNativeCopy returned false (busy?)")
        })

        sc.add("Backend.FileOperations move overwrite (replace)", function (done) {
          var work = sc.opsDir + "/mvow-src.txt"
          var dst = sc.opsDir + "/mvow-dst.txt"
          sc._fileOp(done, function () {
            sc._fileOp(done, function () {
              sc._fileOp(done, function () {
                sc._listOnce(sc.opsDir, function (e) {
                  var ok = sc._has(e, "mvow-dst.txt") && !sc._has(e, "mvow-src.txt")
                  done(ok, ok ? "replaced, source consumed" : "unexpected state")
                })
              })
              Backend.FileOperations.move(work, dst, true)
            })
            Backend.FileOperations.copy(sc.note, dst)
          })
          Backend.FileOperations.copy(sc.note, work)
        })

        sc.add("Backend.FileOperations move directory (recursive)", function (done) {
          var srcDir = sc.opsDir + "/mvdir-src"
          var dstDir = sc.opsDir + "/mvdir-dst"
          sc._fileOp(done, function () {
            sc._fileOp(done, function () {
              sc._listOnce(dstDir, function (e) {
                var okDst = e.length === 4 && sc._has(e, "sub") && sc._has(e, "alpha.txt")
                sc._listOnce(sc.opsDir, function (top) {
                  var okGone = !sc._has(top, "mvdir-src")
                  done(okDst && okGone, okDst ? (okGone ? "tree moved, source gone" : "source wasn't deleted") : "destination tree incomplete")
                })
              })
            })
            Backend.FileOperations.move(srcDir, dstDir)
          })
          Backend.FileOperations.copy(sc.listDir, srcDir)
        })

        sc.add("Backend.FileOperations move symlink preserved", function (done) {
          var work = sc.opsDir + "/mvlink-src"
          var dst = sc.opsDir + "/mvlink-dst"
          sc._fileOp(done, function () {
            sc._fileOp(done, function () {
              sc._listOnce(sc.opsDir, function (e) {
                var ok = false
                for (var i = 0; i < e.length; i++)
                  if (e[i].name === "mvlink-dst" && e[i].link && e[i].link.length > 0) ok = true
                done(ok, ok ? "moved as a link" : "didn't stay a symlink")
              })
            })
            Backend.FileOperations.move(work, dst)
          })
          Backend.FileOperations.copy(sc.dir + "/link.txt", work)
        })

        sc.add("Backend.FileOperations move cross-filesystem (best-effort /tmp)", function (done) {
          var work = sc.opsDir + "/xfs-src.txt"
          var xfsDst = "/tmp/omafiles-selfcheck-xfs-" + Date.now() + ".txt"
          sc._fileOp(done, function () {
            sc._fileOp(done, function () {
              var destInfo = Backend.PreviewProvider.info(xfsDst)
              var destOk = destInfo && Object.keys(destInfo).length > 0
              sc._listOnce(sc.opsDir, function (e) {
                var srcGone = !sc._has(e, "xfs-src.txt")
                sc._fileOp(done, function () {
                  done(destOk && srcGone, (destOk ? "dest ok" : "dest missing") + ", " + (srcGone ? "source gone" : "source stays"))
                })
                Backend.FileOperations.remove(xfsDst)
              })
            })
            Backend.FileOperations.move(work, xfsDst)
          })
          Backend.FileOperations.copy(sc.note, work)
        })

        sc.add("Copy/move cancellation (cooperative, source safe)", function (done) {
          var dst = sc.opsDir + "/big-copy.bin"
          var srcPath = sc.dir + "/big.bin"
          function onErr(op, path, msg) {
            if (path !== srcPath) return
            cleanup()
            if (msg !== "cancelled") { done(false, "unexpected error: " + msg); return }
            var srcOk = Backend.PreviewProvider.info(srcPath)
            done(srcOk && Object.keys(srcOk).length > 0, "cancelled, source intact")
          }
          function onFin(op, path) {
            if (path !== srcPath) return
            cleanup(); done(false, "finished before it could cancel")
          }
          function cleanup() {
            Backend.FileOperations.error.disconnect(onErr)
            Backend.FileOperations.finished.disconnect(onFin)
          }
          Backend.FileOperations.error.connect(onErr)
          Backend.FileOperations.finished.connect(onFin)
          Backend.FileOperations.copy(sc.dir + "/big.bin", dst)
          Backend.FileOperations.cancel()
        })

        sc.add("ActionEngine native move runner + undo (paste/drop path)", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var work = sc.opsDir + "/mv-runner-src.txt"
          var dst = sc.opsDir + "/mv-runner-dst.txt"
          sc._fileOp(done, function () {
            var pairs = [{ src: work, dest: dst }]
            var started = c.actionEngine.runNativeMove(pairs, "Moving…", false, function () {
              var reversed = [{ src: dst, dest: work }]
              c.actionEngine.pushUndo("move test",
                function () { return c.actionEngine.runNativeMove(reversed, "", false) },
                function () { return c.actionEngine.runNativeMove(pairs, "", false) })
              sc._listOnce(sc.opsDir, function (e) {
                if (!(sc._has(e, "mv-runner-dst.txt") && !sc._has(e, "mv-runner-src.txt"))) {
                  done(false, "didn't move"); return
                }
                sc._fileOp(done, function () {
                  sc._listOnce(sc.opsDir, function (e2) {
                    var undone = sc._has(e2, "mv-runner-src.txt") && !sc._has(e2, "mv-runner-dst.txt")
                    done(undone, undone ? "moved and undone" : "undo didn't revert")
                  })
                })
                c.undoLast()
              })
            })
            if (!started) done(false, "runNativeMove returned false")
          })
          Backend.FileOperations.copy(sc.note, work)
        })

        sc.add("Backend.FileOperations delete directory (recursive)", function (done) {
          sc._fileOp(done, function () {
            sc._fileOp(done, function () {
              sc._listOnce(sc.opsDir, function (e) {
                var ok = !sc._has(e, "deldir")
                done(ok, ok ? "tree deleted" : "still exists")
              })
            })
            Backend.FileOperations.remove(sc.opsDir + "/deldir")
          })
          Backend.FileOperations.copy(sc.listDir, sc.opsDir + "/deldir")
        })

        sc.add("Backend.FileOperations delete symlink (target preserved)", function (done) {
          sc._fileOp(done, function () {
            sc._fileOp(done, function () {
              sc._listOnce(sc.opsDir, function (e) {
                var linkGone = !sc._has(e, "dellink")
                var target = Backend.PreviewProvider.info(sc.note)
                done(linkGone && Object.keys(target).length > 0,
                     linkGone ? "link deleted, target intact" : "the link stays")
              })
            })
            Backend.FileOperations.remove(sc.opsDir + "/dellink")
          })
          Backend.FileOperations.copy(sc.dir + "/link.txt", sc.opsDir + "/dellink")
        })

        sc.add("Backend.FileOperations delete read-only (permission failure)", function (done) {
          var target = sc.dir + "/readonly/locked.txt"
          function onErr(op, path, msg) { if (path !== target) return; cleanup(); done(true, "error reported: " + msg) }
          function onFin(op, path) { if (path !== target) return; cleanup(); done(false, "should not be able to delete in a read-only folder") }
          function cleanup() { Backend.FileOperations.error.disconnect(onErr); Backend.FileOperations.finished.disconnect(onFin) }
          Backend.FileOperations.error.connect(onErr)
          Backend.FileOperations.finished.connect(onFin)
          Backend.FileOperations.remove(target, false)
        })

        sc.add("Backend.FileOperations delete missing (error vs ignoreMissing)", function (done) {
          var gone = sc.opsDir + "/never-existed-" + Date.now()
          var gone2 = sc.opsDir + "/never2-" + Date.now()
          function onErr(op, path, msg) {
            if (path !== gone) return
            cleanup1()
            function onFin2(o, p) { if (p !== gone2) return; cleanup2(); done(true, "error if missing, ok with ignoreMissing") }
            function onErr2(o, p, m) { if (p !== gone2) return; cleanup2(); done(false, "ignoreMissing shouldn't fail") }
            function cleanup2() { Backend.FileOperations.finished.disconnect(onFin2); Backend.FileOperations.error.disconnect(onErr2) }
            Backend.FileOperations.finished.connect(onFin2)
            Backend.FileOperations.error.connect(onErr2)
            Backend.FileOperations.remove(gone2, true)
          }
          function onFin(op, path) { if (path !== gone) return; cleanup1(); done(false, "should fail without ignoreMissing") }
          function cleanup1() { Backend.FileOperations.error.disconnect(onErr); Backend.FileOperations.finished.disconnect(onFin) }
          Backend.FileOperations.error.connect(onErr)
          Backend.FileOperations.finished.connect(onFin)
          Backend.FileOperations.remove(gone, false)
        })

        sc.add("Backend.FileOperations delete cancellation (recursive tree)", function (done) {
          var target = sc.dir + "/bigdir"
          function onErr(op, path, msg) {
            if (path !== target) return
            cleanup()
            done(msg === "cancelled", "error=" + msg)
          }
          function onFin(op, path) { if (path !== target) return; cleanup(); done(false, "finished before it could cancel") }
          function cleanup() { Backend.FileOperations.error.disconnect(onErr); Backend.FileOperations.finished.disconnect(onFin) }
          Backend.FileOperations.error.connect(onErr)
          Backend.FileOperations.finished.connect(onFin)
          Backend.FileOperations.remove(target)
          Backend.FileOperations.cancel()
        })

        sc.add("ActionEngine native remove runner (delete path)", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var a = sc.opsDir + "/del-a.txt"
          var b = sc.opsDir + "/del-b.txt"
          sc._fileOp(done, function () {
            sc._fileOp(done, function () {
              var started = c.actionEngine.runNativeRemove([a, b], "", true, function () {
                sc._listOnce(sc.opsDir, function (e) {
                  var ok = !sc._has(e, "del-a.txt") && !sc._has(e, "del-b.txt")
                  done(ok, ok ? "runNativeRemove OK" : "didn't delete")
                })
              })
              if (!started) done(false, "runNativeRemove returned false")
            })
            Backend.FileOperations.copy(sc.note, b)
          })
          Backend.FileOperations.copy(sc.note, a)
        })

        sc.add("QML basename validator table", function (done) {
          var nul = String.fromCharCode(0)
          var cases = [
            ["", false], [".", false], ["..", false], ["a/b", false],
            ["/tmp/x", false], ["../x", false], ["a" + nul + "b", false],
            ["  ", true], ["-rf", true], ["café-文件", true]
          ]
          var ok = cases.every(function (c) { return Utils.validBasename(c[0]) === c[1] })
          done(ok, ok ? "invalid path forms rejected; spaces/dash/Unicode accepted" : "validator table mismatch")
        })

        sc.add("Native coordinator reports partial result and keeps exact completed items", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var a = sc.opsDir + "/partial-a"
          var b = sc.opsDir + "/partial-missing"
          var d = sc.opsDir + "/partial-d"
          var ad = sc.opsDir + "/partial-a-moved"
          var bd = sc.opsDir + "/partial-b-moved"
          var dd = sc.opsDir + "/partial-d-moved"
          sc._seqOps([
            function () { Backend.FileOperations.copy(sc.note, a) },
            function () { Backend.FileOperations.copy(sc.note, d) }
          ], done, function () {
            c.actionEngine.runNativeMove([
              { src: a, dest: ad }, { src: b, dest: bd }, { src: d, dest: dd }
            ], "", false, function (result) {
              var shape = result && result.success === false && result.cancelled === false
                && result.succeeded.length === 1 && result.failed.length === 1 && result.unattempted.length === 1
              var targets = Backend.FileOperations.existingPaths([a, ad, d, dd])
              var exact = targets.indexOf(a) < 0 && targets.indexOf(ad) >= 0
                && targets.indexOf(d) >= 0 && targets.indexOf(dd) < 0
              done(shape && exact, "shape=" + shape + " exact=" + exact)
            })
          })
        })

        sc.add("QML rename rejects every existing target and adds no undo", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var base = sc.opsDir + "/rename-conflicts"
          var setup = "set -eu; rm -rf " + sc._q(base) + "; mkdir -p " + sc._q(base)
            + "; printf source-file > " + sc._q(base + "/src-file")
            + "; printf old-file > " + sc._q(base + "/dst-file")
            + "; printf source-link > " + sc._q(base + "/src-link")
            + "; printf target > " + sc._q(base + "/target")
            + "; ln -s target " + sc._q(base + "/dst-link")
            + "; printf source-broken > " + sc._q(base + "/src-broken")
            + "; ln -s missing " + sc._q(base + "/dst-broken")
            + "; printf source-emptydir > " + sc._q(base + "/src-emptydir")
            + "; mkdir " + sc._q(base + "/dst-emptydir")
            + "; printf source-nonemptydir > " + sc._q(base + "/src-nonemptydir")
            + "; mkdir " + sc._q(base + "/dst-nonemptydir")
            + "; printf child > " + sc._q(base + "/dst-nonemptydir/child")
          sc._sh(["bash", "-c", setup], function (created) {
            if (created.exitCode !== 0) { done(false, "setup failed: " + created.stderr); return }
            UndoState.undoStack = []
            UndoState.redoStack = []
            var kinds = ["file", "link", "broken", "emptydir", "nonemptydir"]
            kinds.forEach(function (kind) {
              ConflictState.pendingRename = {
                oldPath: base + "/src-" + kind,
                newPath: base + "/dst-" + kind,
                newName: "dst-" + kind
              }
              c.actionEngine.runPendingRename()
            })
            var verify = "set -eu"
              + "; test \"$(cat " + sc._q(base + "/src-file") + ")\" = source-file"
              + "; test \"$(cat " + sc._q(base + "/dst-file") + ")\" = old-file"
              + "; test \"$(cat " + sc._q(base + "/src-link") + ")\" = source-link"
              + "; test \"$(readlink " + sc._q(base + "/dst-link") + ")\" = target"
              + "; test \"$(cat " + sc._q(base + "/src-broken") + ")\" = source-broken"
              + "; test \"$(readlink " + sc._q(base + "/dst-broken") + ")\" = missing"
              + "; test \"$(cat " + sc._q(base + "/src-emptydir") + ")\" = source-emptydir"
              + "; test -d " + sc._q(base + "/dst-emptydir")
              + "; test \"$(cat " + sc._q(base + "/src-nonemptydir") + ")\" = source-nonemptydir"
              + "; test \"$(cat " + sc._q(base + "/dst-nonemptydir/child") + ")\" = child"
            sc._sh(["bash", "-c", verify], function (checked) {
              var noHistory = UndoState.undoStack.length === 0 && UndoState.redoStack.length === 0
              done(checked.exitCode === 0 && noHistory,
                   "targets unchanged=" + (checked.exitCode === 0) + " no history=" + noHistory)
            })
          })
        })

        sc.add("Native warning stays correlated and yields an undo-capable success", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var src = sc.opsDir + "/warning-src"
          var dst = sc.opsDir + "/warning-dst"
          sc._fileOp(done, function () {
            UndoState.undoStack = []
            c.actionEngine.runNativeMove([{ src: src, dest: dst }], "", false, function (result) {
              c.actionEngine._pushMoveUndo(result.succeeded, false)
              var ok = result.success && result.succeeded.length === 1
                && result.warnings.length === 1 && UndoState.undoStack.length === 1
                && Backend.FileOperations.existingPaths([src]).length === 0
                && Backend.FileOperations.existingPaths([dst]).length === 1
              done(ok, "success=" + result.success + " warnings=" + result.warnings.length
                   + " undo entries=" + UndoState.undoStack.length)
            })
            c.actionEngine._handleNativeWarning("move", src, "forced committed cleanup warning")
          })
          Backend.FileOperations.copy(sc.note, src)
        })
  }
}

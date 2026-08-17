import QtQuick
import Omafiles.Backend as Backend
import "../../../state"
import "../../../shared/Utils.js" as Utils

// ActionEngine / Undo / Redo domain checks.
// Structural refactor only — behavior unchanged.
QtObject {
  function register(sc) {
        sc.add("Undo + redo move (full cycle)", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var work = sc.opsDir + "/ur-src.txt"
          var dst = sc.opsDir + "/ur-dst.txt"
          sc._fileOp(done, function () {
            var pairs = [{ src: work, dest: dst }]
            c.actionEngine.runNativeMove(pairs, "Moving…", false, function () {
              var reversed = [{ src: dst, dest: work }]
              c.actionEngine.pushUndo("move test",
                function () { return c.actionEngine.runNativeMove(reversed, "", false) },
                function () { return c.actionEngine.runNativeMove(pairs, "", false) })
              sc._fileOp(done, function () {
                sc._listOnce(sc.opsDir, function (e) {
                  var undone = sc._has(e, "ur-src.txt") && !sc._has(e, "ur-dst.txt")
                  if (!undone) { done(false, "undo failed"); return }
                  sc._fileOp(done, function () {
                    sc._listOnce(sc.opsDir, function (e2) {
                      var redone = sc._has(e2, "ur-dst.txt") && !sc._has(e2, "ur-src.txt")
                      done(redone, redone ? "undo and redo OK" : "redo didn't re-apply")
                    })
                  })
                  c.redoLast()
                })
              })
              c.undoLast()
            })
          })
          Backend.FileOperations.copy(sc.note, work)
        })

        sc.add("Undo + redo trash (full cycle)", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var work = sc.opsDir + "/urt-src.txt"
          sc._fileOp(done, function () {
            c.actionEngine.runNativeTrash([work], "", function () {
              c.actionEngine.pushUndo("delete test",
                function () { return c.actionEngine.runNativeRestore([work], "") },
                function () { return c.actionEngine.runNativeTrash([work], "") })
              sc._fileOp(done, function () {
                sc._listOnce(sc.opsDir, function (e) {
                  var undone = sc._has(e, "urt-src.txt")
                  if (!undone) { done(false, "undo didn't restore"); return }
                  sc._fileOp(done, function () {
                    sc._listOnce(sc.opsDir, function (e2) {
                      var redone = !sc._has(e2, "urt-src.txt")
                      done(redone, redone ? "undo and redo trash OK" : "redo trash failed")
                    })
                  })
                  c.redoLast()
                })
              })
              c.undoLast()
            })
          })
          Backend.FileOperations.copy(sc.note, work)
        })

        sc.add("Undo sequence (LIFO: reverts the last one first)", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var a = sc.opsDir + "/lifo-a.txt"
          var b = sc.opsDir + "/lifo-b.txt"
          var da = sc.opsDir + "/lifo-da.txt"
          var db = sc.opsDir + "/lifo-db.txt"
          sc._seqOps([
            function () { Backend.FileOperations.copy(sc.note, a) },
            function () { Backend.FileOperations.copy(sc.note, b) }
          ], done, function () {
            c.actionEngine.runNativeMove([{ src: a, dest: da }], "", false, function () {
              c.actionEngine.pushUndo("move A",
                function () { return c.actionEngine.runNativeMove([{ src: da, dest: a }], "", false) },
                function () { return c.actionEngine.runNativeMove([{ src: a, dest: da }], "", false) })
              c.actionEngine.runNativeMove([{ src: b, dest: db }], "", false, function () {
                c.actionEngine.pushUndo("move B",
                  function () { return c.actionEngine.runNativeMove([{ src: db, dest: b }], "", false) },
                  function () { return c.actionEngine.runNativeMove([{ src: b, dest: db }], "", false) })
                sc._fileOp(done, function () {
                  sc._listOnce(sc.opsDir, function (e) {
                    var bReverted = sc._has(e, "lifo-b.txt") && sc._has(e, "lifo-da.txt")
                    if (!bReverted) { done(false, "first undo didn't revert B"); return }
                    sc._fileOp(done, function () {
                      sc._listOnce(sc.opsDir, function (e2) {
                        var aReverted = sc._has(e2, "lifo-a.txt")
                        done(aReverted, aReverted ? "LIFO OK: B and then A" : "second undo didn't revert A")
                      })
                    })
                    c.undoLast()
                  })
                })
                c.undoLast()
              })
            })
          })
        })

        sc.add("Cancel then undo (cancellation doesn't alter the stack)", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var work = sc.opsDir + "/ctu-src.txt"
          var dst = sc.opsDir + "/ctu-dst.txt"
          sc._fileOp(done, function () {
            var pairs = [{ src: work, dest: dst }]
            c.actionEngine.runNativeMove(pairs, "", false, function () {
              var reversed = [{ src: dst, dest: work }]
              c.actionEngine.pushUndo("valid move",
                function () { return c.actionEngine.runNativeMove(reversed, "", false) },
                function () { return c.actionEngine.runNativeMove(pairs, "", false) })
              var bigDst = sc.opsDir + "/ctu-big-copy.bin"
              function onErr(op, path, msg) {
                if (path !== sc.dir + "/big.bin") return
                cleanup()
                sc._fileOp(done, function () {
                  sc._listOnce(sc.opsDir, function (e) {
                    var undone = sc._has(e, "ctu-src.txt")
                    done(undone, undone ? "undo after cancellation reverts the move" : "stack corrupted")
                  })
                })
                c.undoLast()
              }
              function onFin(op, path) { if (path !== sc.dir + "/big.bin") return; cleanup(); done(false, "big copy didn't cancel") }
              function cleanup() { Backend.FileOperations.error.disconnect(onErr); Backend.FileOperations.finished.disconnect(onFin) }
              Backend.FileOperations.error.connect(onErr)
              Backend.FileOperations.finished.connect(onFin)
              Backend.FileOperations.copy(sc.dir + "/big.bin", bigDst)
              Backend.FileOperations.cancel()
            })
          })
          Backend.FileOperations.copy(sc.note, work)
        })

        sc.add("Undo registry consistency (UndoState stacks)", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          UndoState.undoStack = []
          UndoState.redoStack = []
          var work = sc.opsDir + "/urc-src.txt"
          var dst = sc.opsDir + "/urc-dst.txt"
          sc._fileOp(done, function () {
            c.actionEngine.runNativeMove([{ src: work, dest: dst }], "", false, function () {
              c.actionEngine.pushUndo("urc",
                function () { return c.actionEngine.runNativeMove([{ src: dst, dest: work }], "", false) },
                function () { return c.actionEngine.runNativeMove([{ src: work, dest: dst }], "", false) })
              var afterPush = UndoState.undoStack.length === 1 && UndoState.redoStack.length === 0
              c.undoLast()
              var afterUndo = UndoState.undoStack.length === 0 && UndoState.redoStack.length === 1
              sc._fileOp(done, function () {
                c.redoLast()
                var afterRedo = UndoState.undoStack.length === 1 && UndoState.redoStack.length === 0
                sc._fileOp(done, function () {
                  done(afterPush && afterUndo && afterRedo,
                       "push/undo/redo stacks: " + afterPush + "/" + afterUndo + "/" + afterRedo)
                })
              })
            })
          })
          Backend.FileOperations.copy(sc.note, work)
        })

        sc.add("Backend.FileOperations move", function (done) {
          sc._fileOp(done, function () {
            sc._fileOp(done, function () {
              sc._listOnce(sc.opsDir, function (e) {
                var ok = sc._has(e, "move-dst.txt") && !sc._has(e, "move-src.txt")
                done(ok, ok ? "" : "move not reflected")
              })
            })
            Backend.FileOperations.move(sc.opsDir + "/move-src.txt", sc.opsDir + "/move-dst.txt")
          })
          Backend.FileOperations.copy(sc.note, sc.opsDir + "/move-src.txt")
        })

        sc.add("Backend.FileOperations remove", function (done) {
          sc._fileOp(done, function () {
            sc._fileOp(done, function () {
              sc._listOnce(sc.opsDir, function (e) {
                var ok = !sc._has(e, "del-me.txt")
                done(ok, ok ? "" : "file still exists")
              })
            })
            Backend.FileOperations.remove(sc.opsDir + "/del-me.txt")
          })
          Backend.FileOperations.copy(sc.note, sc.opsDir + "/del-me.txt")
        })

        sc.add("Backend.FileOperations trash + restore (net-zero)", function (done) {
          sc._fileOp(done, function () {
            sc._fileOp(done, function () {
              sc._listOnce(sc.opsDir, function (e) {
                if (sc._has(e, "to-trash.txt")) { done(false, "didn't move to trash"); return }
                sc._fileOp(done, function () {
                  sc._listOnce(sc.opsDir, function (e2) {
                    var ok = sc._has(e2, "to-trash.txt")
                    done(ok, ok ? "restored to its place" : "didn't restore")
                  })
                })
                Backend.FileOperations.restoreByOrigPath(sc.opsDir + "/to-trash.txt")
              })
            })
            Backend.FileOperations.trash(sc.opsDir + "/to-trash.txt")
          })
          Backend.FileOperations.copy(sc.note, sc.opsDir + "/to-trash.txt")
        })

        sc.add("Undo + redo rename (full cycle)", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var oldFile = sc.opsDir + "/ren-old.txt"
          var newFile = sc.opsDir + "/ren-new.txt"
          sc._fileOp(done, function () {
            ConflictState.pendingRename = { oldPath: oldFile, newPath: newFile }
            c.controllers.actionEngine.runPendingRename(false)
            var timeout = Qt.createQmlObject('import QtQuick; Timer { interval: 60; repeat: false }', sc)
            timeout.triggered.connect(function () {
              sc._listOnce(sc.opsDir, function (e1) {
                var renamed = sc._has(e1, "ren-new.txt") && !sc._has(e1, "ren-old.txt")
                if (!renamed) { done(false, "rename failed"); return }
                c.undoLast()
                var timeout2 = Qt.createQmlObject('import QtQuick; Timer { interval: 60; repeat: false }', sc)
                timeout2.triggered.connect(function () {
                  sc._listOnce(sc.opsDir, function (e2) {
                    var undone = sc._has(e2, "ren-old.txt") && !sc._has(e2, "ren-new.txt")
                    if (!undone) { done(false, "undo rename failed"); return }
                    c.redoLast()
                    var timeout3 = Qt.createQmlObject('import QtQuick; Timer { interval: 60; repeat: false }', sc)
                    timeout3.triggered.connect(function () {
                      sc._listOnce(sc.opsDir, function (e3) {
                        var redone = sc._has(e3, "ren-new.txt") && !sc._has(e3, "ren-old.txt")
                        done(redone, redone ? "rename undo/redo OK" : "redo rename failed")
                      })
                    })
                    timeout3.start()
                  })
                })
                timeout2.start()
              })
            })
            timeout.start()
          })
          Backend.FileOperations.copy(sc.note, oldFile)
        })
  }
}

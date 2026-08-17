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

        sc.add("Trash undo restores its exact generation", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var work = sc.opsDir + "/exact-generation.txt"
          var record = { origPath: work, payloadPath: "" }
          UndoState.undoStack = []
          UndoState.redoStack = []
          sc._sh(["bash", "-c", "printf first > " + sc._q(work)], function (createdFirst) {
            if (createdFirst.exitCode !== 0) { done(false, "first generation setup failed"); return }
            c.actionEngine.runNativeTrash([{ src: work, payloadRecord: record }], "", function (firstTrash) {
              if (!firstTrash.success || firstTrash.succeeded.length !== 1
                  || firstTrash.succeeded[0].payloadPath !== record.payloadPath
                  || !record.payloadPath) {
                done(false, "first trash did not report an exact payload"); return
              }
              c.actionEngine.pushUndo("exact generation",
                function () { return c.actionEngine.runNativeRestorePayload([record.payloadPath], "") },
                function () { return c.actionEngine.runNativeTrash([{ src: record.origPath, payloadRecord: record }], "") })
              sc._sh(["bash", "-c", "printf second > " + sc._q(work)], function (createdSecond) {
                if (createdSecond.exitCode !== 0) { done(false, "second generation setup failed"); return }
                sc._fileOp(done, function () {
                  sc._fileOp(done, function () {
                    sc._sh(["cat", work], function (readBack) {
                      var remaining = Backend.FileOperations.trashInfo().filter(function (item) {
                        return item.origPath === work
                      })
                      var firstUndoOk = readBack.stdout === "first" && remaining.length === 1
                        && remaining[0].payloadPath !== record.payloadPath
                        && UndoState.undoStack.length === 0 && UndoState.redoStack.length === 1
                      if (!firstUndoOk) {
                        done(false, "first undo restored=" + readBack.stdout + " unrelated generations=" + remaining.length)
                        return
                      }
                      sc._fileOp(done, function () {
                        var redoOk = Backend.FileOperations.existingPaths([work]).length === 0
                          && Backend.FileOperations.existingPaths([record.payloadPath]).length === 1
                          && UndoState.undoStack.length === 1 && UndoState.redoStack.length === 0
                        sc._fileOp(done, function () {
                          sc._sh(["cat", work], function (secondReadBack) {
                            var secondUndoOk = secondReadBack.stdout === "first"
                              && UndoState.undoStack.length === 0 && UndoState.redoStack.length === 1
                            done(redoOk && secondUndoOk,
                                 "redo payload tracked=" + redoOk + " second undo=" + secondReadBack.stdout)
                          })
                        })
                        c.actionEngine.undoLast()
                      })
                      c.actionEngine.redoLast()
                    })
                  })
                  c.actionEngine.undoLast()
                })
                Backend.FileOperations.trash(work)
              })
            })
          })
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
              var retainedDuringUndo = UndoState.undoStack.length === 1 && UndoState.redoStack.length === 0
              sc._fileOp(done, function () {
                Qt.callLater(function () {
                  var afterUndo = UndoState.undoStack.length === 0 && UndoState.redoStack.length === 1
                  c.redoLast()
                  var retainedDuringRedo = UndoState.undoStack.length === 0 && UndoState.redoStack.length === 1
                  sc._fileOp(done, function () {
                    Qt.callLater(function () {
                      var afterRedo = UndoState.undoStack.length === 1 && UndoState.redoStack.length === 0
                      done(afterPush && retainedDuringUndo && afterUndo && retainedDuringRedo && afterRedo,
                           "push/retained/undo/retained/redo: " + afterPush + "/" + retainedDuringUndo + "/" + afterUndo + "/" + retainedDuringRedo + "/" + afterRedo)
                    })
                  })
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

        sc.add("Undo history moves stacks only after delayed success/error/cancel", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          UndoState.undoStack = []
          UndoState.redoStack = []
          c.actionEngine.pushUndo("delayed success",
            function () { return c.actionEngine.runAction("sleep 0.12; true") },
            function () { return c.actionEngine.runAction("true") })
          c.undoLast()
          var retained = UndoState.undoStack.length === 1 && UndoState.redoStack.length === 0
          c.undoLast()
          var blockedSecond = UndoState.undoStack.length === 1 && UndoState.redoStack.length === 0
          var successTimer = Qt.createQmlObject('import QtQuick; Timer { interval: 240; repeat: false }', sc)
          successTimer.triggered.connect(function () {
            var successMoved = UndoState.undoStack.length === 0 && UndoState.redoStack.length === 1
            c.actionEngine.pushUndo("delayed error",
              function () { return c.actionEngine.runAction("sleep 0.08; false") },
              function () { return c.actionEngine.runAction("true") })
            c.undoLast()
            var errorTimer = Qt.createQmlObject('import QtQuick; Timer { interval: 180; repeat: false }', sc)
            errorTimer.triggered.connect(function () {
              var errorRetained = UndoState.undoStack.length === 1 && UndoState.redoStack.length === 0
              c.actionEngine.pushUndo("delayed cancel",
                function () { return c.actionEngine.runAction("sleep 2") },
                function () { return c.actionEngine.runAction("true") })
              c.undoLast()
              var cancelTimer = Qt.createQmlObject('import QtQuick; Timer { interval: 40; repeat: false }', sc)
              cancelTimer.triggered.connect(function () { c.actionEngine.cancelAction() })
              cancelTimer.start()
              var settleTimer = Qt.createQmlObject('import QtQuick; Timer { interval: 220; repeat: false }', sc)
              settleTimer.triggered.connect(function () {
                var cancelRetained = UndoState.undoStack.length === 2 && UndoState.redoStack.length === 0
                  && UndoState.undoStack[UndoState.undoStack.length - 1].label === "delayed cancel"
                done(retained && blockedSecond && successMoved && errorRetained && cancelRetained,
                     "retained/block/success/error/cancel=" + retained + "/" + blockedSecond + "/" + successMoved + "/" + errorRetained + "/" + cancelRetained)
              })
              settleTimer.start()
            })
            errorTimer.start()
          })
          successTimer.start()
        })

        sc.add("Two-item move history stays atomic after one undo failure", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var a = sc.opsDir + "/atomic-a"
          var b = sc.opsDir + "/atomic-b"
          var da = sc.opsDir + "/atomic-a-moved"
          var db = sc.opsDir + "/atomic-b-moved"
          sc._seqOps([
            function () { Backend.FileOperations.copy(sc.note, a) },
            function () { Backend.FileOperations.copy(sc.note, b) }
          ], done, function () {
            UndoState.undoStack = []
            UndoState.redoStack = []
            var pairs = [{ src: a, dest: da }, { src: b, dest: db }]
            c.actionEngine.runNativeMove(pairs, "", false, function (result) {
              c.actionEngine._pushMoveUndo(result.succeeded, false)
              var twoEntries = UndoState.undoStack.length === 2
              sc._fileOp(done, function () {
                c.undoLast() // B cannot move back while the obstacle exists.
                var failedTimer = Qt.createQmlObject('import QtQuick; Timer { interval: 100; repeat: false }', sc)
                failedTimer.triggered.connect(function () {
                  var failedRetained = UndoState.undoStack.length === 2
                    && UndoState.redoStack.length === 0
                    && Backend.FileOperations.existingPaths([da, db]).length === 2
                  c.actionEngine.runNativeRemove([b], "", false, function () {
                    c.undoLast()
                    var secondTimer = Qt.createQmlObject('import QtQuick; Timer { interval: 100; repeat: false }', sc)
                    secondTimer.triggered.connect(function () {
                      var oneMoved = UndoState.undoStack.length === 1 && UndoState.redoStack.length === 1
                        && Backend.FileOperations.existingPaths([b, da]).length === 2
                        && Backend.FileOperations.existingPaths([a, db]).length === 0
                      c.undoLast()
                      var firstTimer = Qt.createQmlObject('import QtQuick; Timer { interval: 100; repeat: false }', sc)
                      firstTimer.triggered.connect(function () {
                        var independent = UndoState.undoStack.length === 0 && UndoState.redoStack.length === 2
                          && Backend.FileOperations.existingPaths([a, b]).length === 2
                          && Backend.FileOperations.existingPaths([da, db]).length === 0
                        done(twoEntries && failedRetained && oneMoved && independent,
                             "two=" + twoEntries + " retained=" + failedRetained
                             + " one=" + oneMoved + " independent=" + independent)
                      })
                      firstTimer.start()
                    })
                    secondTimer.start()
                  })
                })
                failedTimer.start()
              })
              Backend.FileOperations.copy(sc.note, b) // obstacle for B undo
            })
          })
        })

        sc.add("Warning then finished advances history exactly once", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var ae = c.actionEngine
          var pair = { src: sc.opsDir + "/late-cancel-src", dest: sc.opsDir + "/late-cancel-dst" }
          var entry = { label: "late cancel", undo: function () { return true }, redo: function () { return true } }
          UndoState.undoStack = [entry]
          UndoState.redoStack = []
          ae._historyInFlight = { direction: "undo", entry: entry }
          ae.nativeBusy = true
          ae._nativeKind = "move"
          ae._batchQueue = [pair]
          ae._batchIdx = 1
          ae._batchSucceeded = [pair]
          ae._batchFailed = []
          ae._batchWarnings = [{ item: pair, message: "cleanup retained" }]
          ae._cancelling = true
          ae._batchOnDone = function (result) {
            var ok = result.success && !result.cancelled && result.succeeded.length === 1
              && result.warnings.length === 1 && UndoState.undoStack.length === 0
              && UndoState.redoStack.length === 1 && ae._historyInFlight === null
            done(ok, "success/cancelled/undo/redo=" + result.success + "/" + result.cancelled
              + "/" + UndoState.undoStack.length + "/" + UndoState.redoStack.length)
          }
          ae._batchNext()
        })

        sc.add("Chmod undo uses captured path after navigation", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var path = sc.opsDir + "/chmod-captured"
          sc._fileOp(done, function () {
            sc._sh(["chmod", "600", path], function (setup) {
              if (setup.exitCode !== 0) { done(false, "chmod setup failed"); return }
              UndoState.undoStack = []
              UndoState.redoStack = []
              ChmodState.chmodNames = ["chmod-captured"]
              ChmodState.chmodRecords = [{ name: "chmod-captured", path: path, originalMode: "600" }]
              ChmodState.chmodRecursive = false
              c.actionEngine.commitChmod("644")
              var applyTimer = Qt.createQmlObject('import QtQuick; Timer { interval: 100; repeat: false }', sc)
              applyTimer.triggered.connect(function () {
                var applied = Backend.FileOperations.octalModes([path])[0] === "644"
                var previousPath = NavState.currentPath
                NavState.currentPath = sc.opsDir + "/different-folder"
                c.undoLast()
                var undoTimer = Qt.createQmlObject('import QtQuick; Timer { interval: 120; repeat: false }', sc)
                undoTimer.triggered.connect(function () {
                  var restored = Backend.FileOperations.octalModes([path])[0] === "600"
                  NavState.currentPath = previousPath
                  done(applied && restored, "applied=" + applied + " restored captured path=" + restored)
                })
                undoTimer.start()
              })
              applyTimer.start()
            })
          })
          Backend.FileOperations.copy(sc.note, path)
        })

        sc.add("Exclusive new file history belongs only to a confirmed creation", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var existing = sc.opsDir + "/owned-existing-file"
          var fresh = sc.opsDir + "/owned-fresh-file"
          sc._sh(["bash", "-c", "printf winner > " + sc._q(existing)], function (setup) {
            if (setup.exitCode !== 0) { done(false, "setup failed"); return }
            UndoState.undoStack = []
            UndoState.redoStack = []
            ConflictState.pendingNewFile = { path: existing, name: "owned-existing-file" }
            c.actionEngine.runPendingNewFile(false)
            sc._poll(function () { return !c.actionEngine.nativeBusy }, function (settled) {
              var rejectedOwnedNothing = settled && UndoState.undoStack.length === 0
              ConflictState.pendingNewFile = { path: fresh, name: "owned-fresh-file" }
              c.actionEngine.runPendingNewFile(false)
              sc._poll(function () { return !c.actionEngine.nativeBusy }, function (created) {
                sc._sh(["cat", existing], function (readBack) {
                  var ok = rejectedOwnedNothing && created && readBack.stdout === "winner"
                    && Backend.FileOperations.existingPaths([fresh]).length === 1
                    && UndoState.undoStack.length === 1
                  done(ok, "rejected no-history=" + rejectedOwnedNothing
                    + " created=" + created + " undo=" + UndoState.undoStack.length)
                })
              })
            })
          })
        })

        sc.add("Exclusive new folder history belongs only to a confirmed creation", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var existing = sc.opsDir + "/owned-existing-folder"
          var fresh = sc.opsDir + "/owned-parent/owned-fresh-folder"
          sc._sh(["mkdir", existing], function (setup) {
            if (setup.exitCode !== 0) { done(false, "setup failed"); return }
            UndoState.undoStack = []
            UndoState.redoStack = []
            ConflictState.pendingNewFolder = { path: existing, name: "owned-existing-folder" }
            c.actionEngine.runPendingNewFolder(false)
            sc._poll(function () { return !c.actionEngine.nativeBusy }, function (settled) {
              var rejectedOwnedNothing = settled && UndoState.undoStack.length === 0
              ConflictState.pendingNewFolder = { path: fresh, name: "owned-fresh-folder" }
              c.actionEngine.runPendingNewFolder(false)
              sc._poll(function () { return !c.actionEngine.nativeBusy }, function (created) {
                var ok = rejectedOwnedNothing && created
                  && Backend.FileOperations.existingPaths([existing, fresh]).length === 2
                  && UndoState.undoStack.length === 1
                done(ok, "rejected no-history=" + rejectedOwnedNothing
                  + " created=" + created + " undo=" + UndoState.undoStack.length)
              })
            })
          })
        })

        sc.add("Bulk rename excludes every conflict and duplicate destination", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var base = sc.opsDir + "/bulk-plan"
          sc._sh(["bash", "-c", "mkdir -p " + sc._q(base)
            + "; printf occupied > " + sc._q(base + "/occupied")], function (setup) {
            if (setup.exitCode !== 0) { done(false, "setup failed"); return }
            var pairs = [
              { oldName: "a", newName: "dupe", oldPath: base + "/a", newPath: base + "/dupe" },
              { oldName: "b", newName: "dupe", oldPath: base + "/b", newPath: base + "/dupe" },
              { oldName: "c", newName: "occupied", oldPath: base + "/c", newPath: base + "/occupied" },
              { oldName: "d", newName: "free", oldPath: base + "/d", newPath: base + "/free" }
            ]
            var plan = c.actionEngine._planBulkRename(pairs)
            var ok = plan.blockedCount === 3 && plan.duplicateCount === 2
              && plan.eligible.length === 1 && plan.eligible[0].oldName === "d"
            done(ok, "blocked=" + plan.blockedCount + " duplicates=" + plan.duplicateCount
              + " eligible=" + plan.eligible.length)
          })
        })

        sc.add("Bulk rename partial failure records only confirmed pairs", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var base = sc.opsDir + "/bulk-partial"
          sc._sh(["bash", "-c", "mkdir -p " + sc._q(base)
            + "; printf source > " + sc._q(base + "/first")], function (setup) {
            if (setup.exitCode !== 0) { done(false, "setup failed"); return }
            UndoState.undoStack = []
            UndoState.redoStack = []
            ConflictState.pendingBulkRename = [
              { oldName: "first", newName: "first-new", oldPath: base + "/first", newPath: base + "/first-new" },
              { oldName: "missing", newName: "missing-new", oldPath: base + "/missing", newPath: base + "/missing-new" }
            ]
            c.actionEngine.runPendingBulkRename()
            sc._poll(function () { return !c.actionEngine.nativeBusy }, function (settled) {
              var ok = settled && Backend.FileOperations.existingPaths([base + "/first-new"]).length === 1
                && Backend.FileOperations.existingPaths([base + "/first"]).length === 0
                && UndoState.undoStack.length === 1
                && UndoState.undoStack[0].label.indexOf("first") >= 0
              done(ok, "settled=" + settled + " undo=" + UndoState.undoStack.length)
            })
          })
        })

        sc.add("Overwrite move has no undo; no-overwrite move does", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var src = sc.opsDir + "/overwrite-history-src"
          var dst = sc.opsDir + "/overwrite-history-dst"
          var safeSrc = sc.opsDir + "/safe-history-src"
          var safeDst = sc.opsDir + "/safe-history-dst"
          sc._sh(["bash", "-c", "printf new > " + sc._q(src)
            + "; printf old > " + sc._q(dst) + "; printf safe > " + sc._q(safeSrc)], function (setup) {
            if (setup.exitCode !== 0) { done(false, "setup failed"); return }
            UndoState.undoStack = []
            UndoState.redoStack = []
            c.actionEngine.runNativeMove([{ src: src, dest: dst }], "", true, function (overwritten) {
              c.actionEngine._pushMoveUndo(overwritten.succeeded, true)
              var overwriteNoHistory = overwritten.succeeded.length === 1 && UndoState.undoStack.length === 0
              c.actionEngine.runNativeMove([{ src: safeSrc, dest: safeDst }], "", false, function (safe) {
                c.actionEngine._pushMoveUndo(safe.succeeded, false)
                var ok = overwriteNoHistory && safe.succeeded.length === 1 && UndoState.undoStack.length === 1
                done(ok, "overwrite no-history=" + overwriteNoHistory
                  + " safe undo=" + UndoState.undoStack.length)
              })
            })
          })
        })

        sc.add("Archive extraction commands are no-clobber", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var ae = c.actionEngine
          var zip = ae.archiveExtractCommand("zip", "/tmp/a.zip", "/tmp/out").cmd
          var seven = ae.archiveExtractCommand("7z", "/tmp/a.7z", "/tmp/out").cmd
          var rar = ae.archiveExtractCommand("rar", "/tmp/a.rar", "/tmp/out").cmd
          var tar = ae.archiveExtractCommand("tar", "/tmp/a.tar", "/tmp/out").cmd
          var ok = zip.indexOf("unzip -n ") === 0 && zip.indexOf("unzip -o") < 0
            && seven.indexOf("-aos") >= 0 && rar.indexOf("-o-") >= 0
            && tar.indexOf("--skip-old-files") >= 0
          done(ok, ok ? "zip/7z/rar/tar all skip existing entries"
                      : [zip, seven, rar, tar].join(" | "))
        })
  }
}

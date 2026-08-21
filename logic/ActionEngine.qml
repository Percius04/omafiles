import QtQuick
import "../shared/Utils.js" as Utils
import qs.Commons
import "../state"
import Omafiles.Backend as Backend

// The central file action engine (rename/delete/copy/move/
// compress/extract/chmod/link, everything goes through here) + undo/redo +
// the copy/move progress bar -- thirteenth component
// extracted from core, and the most impactful: dozens of functions in
// core (commitNewFolder, requestDelete, runPaste, runDrop,
// commitChmod, makeLinkFor, restoreFromTrash...) call runAction()/
// pushUndo() as if they were their own. Changing the 50+ call sites
// would have been far more risk than the benefit -- instead, root
Item {
  id: actionEngine

  property Item root: null
  property Item navController: null
  property var _nativeMkdirPending: ({})
  // Native "new folder" REDOS in flight -> completion callback (see the
  // undo/redo "started vs finished" fix below, next to pushUndo()). Separate
  // from _nativeMkdirPending above: that one is keyed for "register a NEW
  // undo entry", this one is keyed for "an EXISTING entry is being redone,
  // just tell it when the native mkdir actually finishes" -- a redo must
  // never call pushUndo() again (undoLast()/redoLast() already move the
  // entry between stacks themselves).
  property var _nativeMkdirRedoPending: ({})

  // Exposes archiveProc's real busy state (cleanup pass) -- the selfcheck
  // suite's compress-then-extract tests used to bridge the gap between
  // ActionState.actionBusy clearing and archiveProc itself actually
  // settling with a guessed fixed-duration Timer (a real, empirically-
  // reproduced flake otherwise, ~10% of runs for the .7z case: the
  // compress subprocess writing its output file to disk doesn't guarantee
  // runActionWithProgress()'s own busy guard, which checks archiveProc.active
  // directly, has cleared yet). This lets a test poll the SAME thing the
  // guard checks instead of guessing how long that takes.
  property alias archiveBusy: archiveProc.active


  // Simple stack of reversible actions: rename, new folder/file,
  // delete (to trash), move (cut+paste/drag), bulk
  // rename, chmod and link. Copy/compress are left out on purpose --
  // undoing them is more ambiguous (delete the copy? what if it was already moved/edited?)
  // than losing by mistake something renamed/moved/deleted/with permissions
  // changed. undoStack/redoStack themselves live in state/UndoState.qml
  // (singleton) -- only these three functions that manipulate them live here.
  function pushUndo(label, undoFn, redoFn) {
    UndoState.undoStack = UndoState.undoStack.concat([{ label: label, undo: undoFn, redo: redoFn }]).slice(-20)
    UndoState.redoStack = []
  }

  // undo/redo closures accept an optional onSettled callback (fixes the
  // "started vs finished" gap documented in docs/architecture/ARCHITECTURE.md
  // -- entry.undo()/entry.redo() returning true only ever meant "accepted
  // and launched", not "actually completed", yet the entry moved to the
  // OPPOSITE stack immediately on that return, before the real work was
  // done. A redo pressed right after could fire while its own undo was
  // still mid-flight. Every closure already had a real completion hook
  // available (runAction()'s onSuccess param, runNative*()'s onDone param)
  // except the native "new folder" redo (Backend.FileOperations.mkdir()
  // called directly, no such param) -- see _nativeMkdirRedoPending below for
  // that one case. onSettled only fires on SUCCESS, matching each
  // underlying onSuccess/onDone's own contract -- if the undo/redo itself
  // fails or is cancelled, the entry is not moved to the opposite stack at
  // all (silently dropped from undo history from that point on). This is
  // strictly safer than the previous behavior, which offered a "redo" for
  // an undo that had just genuinely failed.
  function undoLast() {
    if (UndoState.undoStack.length === 0) return
    var entry = UndoState.undoStack[UndoState.undoStack.length - 1]
    UndoState.undoStack = UndoState.undoStack.slice(0, -1)
    // entry.undo() returns what runAction()/runNative*() returns: false if
    // it was discarded because another action was in progress. Before, this
    // said "Undone" no matter what, even when the undo didn't even get
    // launched, AND the entry was lost from the stack anyway. Now, if it
    // didn't get launched, it is returned to the stack so it can be retried.
    var started = entry.undo(function () {
      // Only reached on genuine completion (see the comment above) -- NOT
      // every undoStack entry has a redoFn (see the comment next to
      // pushUndo).
      if (entry.redo) UndoState.redoStack = UndoState.redoStack.concat([entry]).slice(-20)
    })
    if (started === false) {
      UndoState.undoStack = UndoState.undoStack.concat([entry])
      Backend.Notifier.notify("Couldn't undo \"" + entry.label + "\": still busy with another action")
      return
    }
    Backend.Notifier.notify("Undoing: " + entry.label)
  }

  function redoLast() {
    if (UndoState.redoStack.length === 0) return
    var entry = UndoState.redoStack[UndoState.redoStack.length - 1]
    UndoState.redoStack = UndoState.redoStack.slice(0, -1)
    var started = entry.redo(function () {
      // Back to undoStack WITHOUT going through pushUndo() -- that would
      // empty redoStack, which is exactly what we don't want in the middle
      // of an undo/redo/undo cycle. Only reached on genuine completion.
      UndoState.undoStack = UndoState.undoStack.concat([entry]).slice(-20)
    })
    if (started === false) {
      UndoState.redoStack = UndoState.redoStack.concat([entry])
      Backend.Notifier.notify("Couldn't redo \"" + entry.label + "\": still busy with another action")
      return
    }
    Backend.Notifier.notify("Redoing: " + entry.label)
  }

  // actionProc/nativeBusy/archiveProc are each a single process/flag shared
  // across all file actions (rename, delete, copy/move, compress, native
  // batch ops...). Without this guard, a second call while the first is
  // still running (double click, or an extra keypress during a long
  // operation) changed its command and restarted it, cutting off the
  // ongoing operation mid-copy without any notice.
  function _isBusy() {
    return actionProc.busy || nativeBusy || archiveProc.active
  }

  // Reject-on-busy guard: kept for rename/chmod/mkdir/link/bulk-rename/
  // trash/restore/emptyTrash (runAction(), emptyTrash()) -- all quick,
  // rarely queued-for in practice. Shared by runAction() and emptyTrash()
  // -- was 4 byte-identical copies of this exact check (cleanup pass); the
  // other 2 (native copy/move, archive compress/extract) queue instead,
  // see _transferQueue below.
  function _busyGuard() {
    if (!_isBusy()) return false
    Backend.Notifier.notify("Still busy with the previous action — try again in a moment")
    return true
  }

  // Transfer queue (V1.1): copy/move (native) and compress/extract
  // (archiveProc) are the operations actually worth queuing instead of
  // rejecting -- they can take long enough that a second one arriving
  // mid-flight (another paste, another drop, another archive) is a normal
  // thing to want to happen automatically, not just a "try again" dead
  // end. Each entry is { label, run }: `run` is a closure that just
  // re-calls the original _runNative()/runActionWithProgress() invocation
  // (no separate dispatch table -- when dequeued, _isBusy() is false
  // again, so it just runs its normal path), `label` is only for display
  // (DialogLayer's pending-queue indicator). Always reassigned via
  // concat()/slice(), never push()/splice() -- this is a QML `property
  // var`, and in-place mutation doesn't fire the change notification a UI
  // binding on it depends on.
  property var _transferQueue: []

  function _drainTransferQueue() {
    if (_isBusy()) return
    if (_transferQueue.length === 0) return
    var job = _transferQueue[0]
    _transferQueue = _transferQueue.slice(1)
    job.run()
  }

  // Drops a still-pending entry before it ever runs (DialogLayer's "Pending"
  // rows, V1.1) -- `run` is simply discarded, never invoked, so nothing on
  // disk is touched and no undo entry is ever registered for it. If the
  // dropped entry happened to be a queued undo/redo (pushUndo()'s closures
  // can themselves land in this same queue, see runNativeMove's onSettled
  // usage), it stays unreachable from either undo/redo stack -- the same
  // "silently dropped from undo history" contract already documented for
  // any undo/redo that fails or is cancelled (see undoLast()/redoLast()),
  // not a new case to special-case here.
  function cancelQueuedJob(index) {
    if (index < 0 || index >= _transferQueue.length) return
    _transferQueue = _transferQueue.slice(0, index).concat(_transferQueue.slice(index + 1))
  }

  function runAction(cmd, busyLabel, onSuccess) {
    if (_busyGuard()) return false
    ActionState.actionLabel = busyLabel || ""
    ActionState.actionBusy = !!busyLabel
    ActionState._actionOnSuccess = onSuccess || null
    // group:true -- the command runs in its own process group instead
        // kill the "bash -c" itself -- any cp/mv/zip that bash had
    // launched as a child was left orphaned and kept running in the background
    // as if nothing, even though the UI had already given the action for cancelled.
    actionProc.start(["bash", "-c", cmd], true)
    return true
  }

  // Joins commands of a batch operation (paste/drop/delete N files,
  // bulk rename...) so that one's failure doesn't eat the others.
  // Before they were joined with "&&": as soon as item 2 of 5 failed (no longer
  // existed, permission denied...) items 3-5 weren't even attempted
  // and on top of that there was no notice. With this, all are attempted, and if any
  // fails the process exits with status != 0 so actionProc reports it
  // (see runAction/actionProc above) -- without saying which one specifically,
  // but they are no longer lost silently.
  function chainCmds(cmds) {
    if (cmds.length <= 1) return cmds[0] || "true"
    return "st=0; " + cmds.map(function (c) { return "{ " + c + "; } || st=1" }).join("; ") + "; exit $st"
  }

  function cancelAction() {
    // Native copy/move in progress (Phase 13.A/G): cooperative cancellation
    // in C++. The worker aborts between chunks, CLEANS UP ITSELF the partial
    // copy of the destination (forceRemove in backend/FileOperations) and emits error
    // "cancelled" -> bad() -> _nativeDone cleans up the state and refreshes. There is no longer
    // a shell `rm -rf`: the backend is self-sufficient to clean up.
    if (nativeBusy) {
      _cancelling = true
      Backend.FileOperations.cancel()
      return
    }
    // Archive extract/compress (archiveProc, watched for progress): same
    // whole-process-group semantics as actionProc.cancel() below, via
    // ProcessWatcher.stop(). No partial-destination cleanup here either --
    // same reasoning as the shell actions.
    if (archiveProc.active) {
      archiveProc.stop()
      return
    }
    // Actions still in shell (rename/create/chmod/...): actionProc.
    // cancel() kills the whole process group. They have no progress nor a
    // partial destination to clean up here (their overwrite is atomic or handled
    // by their own command).
    actionProc.cancel()
    _resetActionState()
    _drainTransferQueue()
  }

  function _resetActionState() {
    ActionState.actionBusy = false
    ActionState.actionLabel = ""
    ActionState.actionProgressPct = -1
    navController.refresh()
    NavState.refreshTick += 1
  }

  // ---------- Native byte progress & batch lifecycle ----------
  // Replaces du polling with totalSize + Backend.FileOperations signals.
  property real _progTotal: 0   // total bytes of the batch (all sources)
  property real _progBase: 0    // bytes already completed from previous items
  property real _lastItemTotal: 0 // total of the current item (last progress)

  function startCopyProgress(sourcePaths, destPaths) {
    _progTotal = Backend.FileOperations.totalSize(sourcePaths)
    _progBase = 0
    _lastItemTotal = 0
    // Bar from 0% if there is something to measure; dots if the total is 0 (empty items).
    ActionState.actionProgressPct = _progTotal > 0 ? 0 : -1
  }

  // ---------- Archive extract/compress progress (V1.1) ----------
  // Not byte-based like copy/move above -- zip/7z/unrar/tar don't agree on
  // a common byte-progress format, but they all print one output line per
  // file when run verbose (not quiet), which IS a format they share. So
  // this counts LINES against a known total entry count (from the same
  // archive listing already fetched for conflict detection, or entries.length
  // for compress) instead of bytes. Same clamping/dots-vs-bar convention as
  // the native path above. Clamped to 99, never 100, until onFinished says
  // so -- undercounting (e.g. zip -r recursing into a folder) must never
  // read as "done" while the process is still working.
  property real _archiveProgTotal: 0
  property real _archiveProgDone: 0

  // Multi-volume archives (foo.part01.rar..partNN.rar, foo.7z.001..NNN):
  // line-counting breaks down here -- confirmed live (2026-08-18) that
  // unrar prints several lines while still on volume 1 of a 9-volume
  // archive, hitting the line-count total almost immediately. Weighted by
  // REAL byte size of each volume instead. Which volume is "active" is
  // DERIVED from the tool's own live "NN%" (a fraction of the whole
  // logical file, spanning every volume seamlessly -- confirmed directly,
  // 2026-08-18, real 8-volume 7z archive) mapped onto the known cumulative
  // volume sizes -- not detected from output text: neither unrar nor 7z
  // ever print a later volume's filename when they move on to reading it,
  // so a "did this line mention part03.rar" scheme can never advance past
  // volume 0 in practice (the bug behind the first attempt at this).
  property var _archiveVolumes: null   // sorted [{name, num, size}], or null
  property int _archiveVolIdx: -1      // index of the volume currently believed active (derived, see onLineRead)
  property real _archiveVolBytesTotal: 0
  property string _archiveBaseLabel: ""

  function startArchiveProgress(total) {
    _archiveProgTotal = total
    _archiveProgDone = 0
    _archiveVolumes = null
    _archiveVolIdx = -1
    ActionState.actionProgressPct = total > 0 ? 0 : -1
  }

  function startArchiveVolumeProgress(volumes, baseLabel) {
    _archiveVolumes = volumes
    _archiveVolIdx = 0
    _archiveVolBytesTotal = volumes.reduce(function (sum, v) { return sum + v.size }, 0)
    _archiveBaseLabel = baseLabel
    ActionState.actionProgressPct = _archiveVolBytesTotal > 0 ? 0 : -1
    ActionState.actionLabel = baseLabel + " (part 1/" + volumes.length + ")"
  }

  // Finds the sibling volumes of a multi-volume archive by matching known
  // naming conventions against the CURRENT folder's already-loaded listing
  // (NavState.visibleEntries) -- no extra filesystem round-trip needed,
  // and entry.size is already there for the weighting above. Returns null
  // if `name` doesn't look like a numbered volume, or only one match
  // exists (nothing to weight against).
  function _multiVolumeSiblings(name) {
    var m = name.match(/^(.*)\.part\d+\.rar$/i) || name.match(/^(.*)\.7z\.\d+$/i)
    if (!m) return null
    var escapedBase = m[1].replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    var re = /\.part\d+\.rar$/i.test(name)
      ? new RegExp("^" + escapedBase + "\\.part(\\d+)\\.rar$", "i")
      : new RegExp("^" + escapedBase + "\\.7z\\.(\\d+)$", "i")
    var vols = []
    NavState.visibleEntries.forEach(function (e) {
      var mm = e.name.match(re)
      if (mm) vols.push({ name: e.name, num: parseInt(mm[1], 10), size: e.size || 0 })
    })
    if (vols.length <= 1) return null
    vols.sort(function (a, b) { return a.num - b.num })
    return vols
  }

  // Runs an archive extract/compress command with live progress, via
  // archiveProc (ProcessWatcher) instead of actionProc (ProcessRunner) --
  // same single-flight guard (see the archiveProc.active checks alongside
  // actionProc.busy/nativeBusy elsewhere in this file), same "bash -c" +
  // process-group convention, but streams stdout instead of only
  // reporting the final result. `volumes` (optional): the multi-volume
  // sibling set from _multiVolumeSiblings(), for weighted/live-part
  // progress instead of the flat line-count fallback.
  // zip/7z/unrar/tar all suppress their own live "NN%" progress display
  // when stdout isn't a real terminal -- confirmed directly (2026-08-18):
  // 7z extracting piped through `bash -c` produced ZERO \r updates; the
  // exact same command under `script` (a fake controlling terminal)
  // produced 21, with real "0%"/"44%"/etc content. This is the ordinary,
  // near-universal isatty()-gated behavior CLI progress bars use, not
  // specific to one tool -- it's why onLineRead only ever saw whole-line
  // events (volume switches) and never the live intra-file percentage.
  // `script` (util-linux) is the standard way to fake a controlling
  // terminal for exactly this case. -e makes it propagate the real child
  // exit code (needed by archiveProc.onFinished); -q/-c: quiet, run this
  // one command.
  //
  // NOT unconditionally though: some distros split the binary out of the
  // core util-linux package (Fedora ships it as `util-linux-script`), and
  // when it is absent the process never starts, so every compress/extract
  // silently hung with the transfer queue jammed behind it. Probing with
  // `command -v` inside the wrapper costs nothing and degrades gracefully:
  // without `script` the job still runs to completion and reports
  // success/failure normally -- it only loses the live intra-file
  // percentage (isatty-gated in the archivers), keeping the whole-line
  // events (per-file/volume lines) that onLineRead also parses.
  function _ptyArgs(cmd) {
    var inner = "bash -c " + Util.shellQuote(cmd)
    return ["bash", "-c",
      "if command -v script >/dev/null 2>&1; then exec script -qec "
        + Util.shellQuote(inner) + " /dev/null; else exec " + inner + "; fi"]
  }

  function runActionWithProgress(cmd, busyLabel, total, onSuccess, volumes) {
    if (_isBusy()) {
      _transferQueue = _transferQueue.concat([{ label: busyLabel || "Archive job", run: function () { runActionWithProgress(cmd, busyLabel, total, onSuccess, volumes) } }])
      return true
    }
    ActionState.actionLabel = busyLabel || ""
    ActionState.actionBusy = !!busyLabel
    ActionState._actionOnSuccess = onSuccess || null
    if (volumes && volumes.length > 1) startArchiveVolumeProgress(volumes, busyLabel || "")
    else startArchiveProgress(total)
    archiveProc.start(_ptyArgs(cmd), true)
    return true
  }

  // Static declarative signal handler for all native file operations:
  // eliminates per-batch-item dynamic connect()/disconnect() churn.
  Connections {
    target: Backend.FileOperations

    function onProgress(op, path, done, total) {
      if (!nativeBusy || _progTotal <= 0) return
      _lastItemTotal = total
      ActionState.actionProgressPct = Math.min(100, (_progBase + done) * 100 / _progTotal)
    }

    function onFinished(op, path) {
      if (!nativeBusy) return
      if (_nativeKind === "emptyTrash") {
        _finishNative(true)
        return
      }
      // Recorded BEFORE advancing _batchIdx: this is what makes the undo
      // entry (see _finishNative) reflect exactly the items that really
      // completed, not the whole batch that was merely requested (P1-1/
      // P1-2, architectural audit 2026-08-17).
      _batchCompleted.push(_batchQueue[_batchIdx])
      _progBase += _lastItemTotal
      _lastItemTotal = 0
      _batchIdx += 1
      _batchNext()
    }

    function onError(op, path, msg) {
      if (!nativeBusy) return
      if (msg && msg !== "cancelled")
        Backend.Notifier.notify(msg || "Action failed")
      _finishNative(false)
    }
  }

  // ---------- Native copy/move/trash/restore/remove/emptyTrash ----------
  property bool nativeBusy: false
  property string _nativeKind: "copy"
  property var _batchQueue: []
  property int _batchIdx: 0
  property bool _batchOverwrite: false
  property var _batchOnDone: null
  property bool _cancelling: false
  // Items of _batchQueue that ACTUALLY finished (see onFinished above) --
  // NOT the whole batch that was requested. _finishNative hands exactly
  // this to _batchOnDone, so a caller building an undo entry can never
  // claim more happened than really did (P1-1/P1-2, architectural audit
  // 2026-08-17).
  property var _batchCompleted: []

  function runNativeCopy(pairs, busyLabel, overwrite, onDone) {
    return _runNative("copy", pairs, busyLabel, overwrite, onDone)
  }

  function runNativeMove(pairs, busyLabel, overwrite, onDone) {
    return _runNative("move", pairs, busyLabel, overwrite, onDone)
  }

  function _toPairs(paths) {
    return paths.map(function (p) { return { src: p } })
  }

  function runNativeRemove(paths, busyLabel, ignoreMissing, onDone) {
    return _runNative("remove", _toPairs(paths), busyLabel, ignoreMissing, onDone)
  }

  function runNativeTrash(paths, busyLabel, onDone) {
    return _runNative("trash", _toPairs(paths), busyLabel, false, onDone)
  }

  function runNativeRestore(origPaths, busyLabel, onDone) {
    return _runNative("restore", _toPairs(origPaths), busyLabel, false, onDone)
  }

  function emptyTrash(onDone) {
    if (_busyGuard()) return false
    nativeBusy = true
    _cancelling = false
    _nativeKind = "emptyTrash"
    _batchQueue = []
    _batchIdx = 0
    _batchOverwrite = false
    _batchOnDone = onDone || null
    _batchCompleted = []
    ActionState.actionLabel = "Emptying trash…"
    ActionState.actionBusy = true
    ActionState.actionProgressPct = -1
    Backend.FileOperations.emptyTrash()
    return true
  }

  function _runNative(kind, pairs, busyLabel, overwrite, onDone) {
    if (_isBusy()) {
      if (kind === "copy" || kind === "move") {
        _transferQueue = _transferQueue.concat([{ label: busyLabel || (kind === "move" ? "Move" : "Copy"), run: function () { _runNative(kind, pairs, busyLabel, overwrite, onDone) } }])
        return true
      }
      Backend.Notifier.notify("Still busy with the previous action — try again in a moment")
      return false
    }
    nativeBusy = true
    _cancelling = false
    _nativeKind = kind
    _batchQueue = pairs
    _batchIdx = 0
    _batchOverwrite = overwrite === true
    _batchOnDone = onDone || null
    _batchCompleted = []
    ActionState.actionLabel = busyLabel || ""
    ActionState.actionBusy = !!busyLabel
    if (busyLabel && (kind === "copy" || kind === "move"))
      startCopyProgress(pairs.map(function (p) { return p.src }),
                        pairs.map(function (p) { return p.dest }))
    _batchNext()
    return true
  }

  function _batchNext() {
    if (_cancelling) { _finishNative(false); return }
    if (_batchIdx >= _batchQueue.length) { _finishNative(true); return }
    var p = _batchQueue[_batchIdx]
    if (_nativeKind === "remove")
      Backend.FileOperations.remove(p.src, _batchOverwrite)  // _batchOverwrite = ignoreMissing
    else if (_nativeKind === "trash")
      Backend.FileOperations.trash(p.src)
    else if (_nativeKind === "restore")
      Backend.FileOperations.restoreByOrigPath(p.src)
    else if (_nativeKind === "move")
      Backend.FileOperations.move(p.src, p.dest, _batchOverwrite)
    else
      Backend.FileOperations.copy(p.src, p.dest, _batchOverwrite)
  }

  function _finishNative(success) {
    nativeBusy = false
    _resetActionState()
    var cb = _batchOnDone
    var completed = _batchCompleted
    _batchOnDone = null
    _batchCompleted = []
    // Real bug (P1-1/P1-2, architectural audit 2026-08-17): this used to
    // gate on `success` alone, so a batch that failed or was cancelled
    // AFTER a few items had already really completed on disk skipped
    // _batchOnDone entirely -- zero undo entry for work that genuinely
    // happened, even though `success` and "nothing happened" are different
    // things. The only thing that matters for "is there something to
    // report/undo" is whether anything actually finished; `cb` now always
    // receives the real completed subset (never the full original batch)
    // so it can never register an undo for more than truly succeeded.
    if (cb && completed.length > 0) Qt.callLater(function () { cb(completed) })
    _drainTransferQueue()
  }

  Backend.ProcessRunner {
    id: actionProc
    onFinished: function (result) {
      _resetActionState()
      var cb = ActionState._actionOnSuccess
      ActionState._actionOnSuccess = null
      if (result.exitCode === 0) {
        if (cb) cb()
      } else if (!result.cancelled) {
        // actionProc is the ONE shared process for every shell-based action
        // that doesn't need progress (rename, bulk rename, chmod,
        // make-link, new-file/-folder overwrite...; compress/extract moved
        // to archiveProc below, V1.1, for progress) -- this fallback used
        // to say "Couldn't restore from trash", written back when restore-
        // from-trash was itself shell-based. It no longer is (restoreFromTrash()
        // uses runNativeRestore(), a separate native path with its own
        // "Action failed" fallback below) -- so that string was stale for
        // every one of this handler's actual current callers (P2.7,
        // 2026-08-17). "Action failed" matches the native path's own
        // fallback for the same reason: neither handler knows which of its
        // several callers is the one that just failed.
        Backend.Notifier.notify(result.stderr.trim() || "Action failed")
      }
      _drainTransferQueue()
    }
  }

  // Archive extract/compress (V1.1): same shared-single-process idea as
  // actionProc above, but a ProcessWatcher instead of a ProcessRunner so
  // progress can be observed live instead of only at the end -- see
  // runActionWithProgress()/startArchiveProgress() above.
  Backend.ProcessWatcher {
    id: archiveProc
    onLineRead: function (line) {
      if (!ActionState.actionBusy) return
      if (_archiveVolumes) {
        // Multi-volume: confirmed directly (2026-08-18, a real 8-volume 7z
        // archive, .7z.001..008) that neither unrar nor 7z ever print a
        // later volume's filename when they move on to reading it -- the
        // ORIGINAL "detect volume switch by filename match" scheme above
        // could therefore never advance past volume 0, which is the real
        // reason this never actually tracked live progress. What IS real,
        // confirmed from the same test: the tool's live "NN%" (e.g. "62% -
        // bigfile3.bin") is already a percentage of the WHOLE logical
        // file's content, seamlessly spanning every volume -- not
        // per-volume, no reset at volume boundaries. So the fix is
        // actually simpler than the original design: trust that %
        // directly as the overall fraction, and only use the known
        // cumulative volume sizes to DERIVE which part it corresponds to,
        // for the "(part N/M)" label -- never to detect it from text.
        //
        // Global match (not just the first): a single captured "line" can
        // contain more than one "NN%" token pasted together from several
        // \r-overwrites landing in the same drain (confirmed: "0%   62%
        // ... Everything is Ok" arrived as one chunk) -- the LAST one is
        // the current value, not the first/stale one.
        var pctMatches = line.match(/(\d{1,3})\s*%/g)
        if (!pctMatches || pctMatches.length === 0 || _archiveVolBytesTotal <= 0) return
        var p = parseInt(pctMatches[pctMatches.length - 1], 10)
        if (p < 0 || p > 100) return
        ActionState.actionProgressPct = Math.min(99, p)
        var bytesSoFar = (p / 100) * _archiveVolBytesTotal
        var acc = 0
        for (var i = 0; i < _archiveVolumes.length; i++) {
          acc += _archiveVolumes[i].size
          _archiveVolIdx = i
          if (bytesSoFar < acc) break
        }
        ActionState.actionLabel = _archiveBaseLabel + " (part " + (_archiveVolIdx + 1) + "/" + _archiveVolumes.length + ")"
        return
      }
      if (_archiveProgTotal <= 0) return
      // Every format's verbose output is roughly one line per file/dir
      // entry -- the fallback for archives that aren't a detected
      // multi-volume set (see _multiVolumeSiblings()). Clamped to 99, not
      // 100, so an undercount (e.g. zip -r recursing into a folder) can
      // never claim done before the process actually says so via
      // onFinished.
      if (line.trim() === "") return
      _archiveProgDone += 1
      ActionState.actionProgressPct = Math.min(99, _archiveProgDone * 100 / _archiveProgTotal)
    }
    onFinished: function (exitCode, cancelled, stdoutText, stderrText) {
      _resetActionState()
      var cb = ActionState._actionOnSuccess
      ActionState._actionOnSuccess = null
      if (exitCode === 0) {
        if (cb) cb()
      } else if (!cancelled) {
        // Running under a fake PTY (_ptyArgs(), for live progress) merges
        // the child's stderr into stdout instead -- confirmed directly,
        // 2026-08-18 -- so stderrText alone can no longer be trusted here.
        // The real error is normally near the end of stdoutText; the last
        // couple of non-empty lines is a reasonable, readable summary for
        // a one-line notification (not the whole banner/scan preamble).
        var tail = stdoutText.split("\n").map(function (l) { return l.trim() })
          .filter(function (l) { return l.length > 0 }).slice(-2).join(" — ")
        Backend.Notifier.notify(stderrText.trim() || tail || "Action failed")
      }
      _drainTransferQueue()
    }
  }

  // Removed actionProgressTotalProc / actionProgressPollProc /
  // actionProgressPollTimer: progress is no longer polled with `du`, it comes by
  // bytes from the FileOperations.progress signal (see the Connections above).

  // --- DeleteOps ---

  function requestDelete() {
    if (ArchiveState.inArchive) return
    var names = SelectionState.selectedEntries().map(function (e) { return e.name })
    if (names.length === 0) return
    ActionState.pendingDeleteNames = names
  }

  function confirmDelete() {
    var names = ActionState.pendingDeleteNames
    ActionState.pendingDeleteNames = []
    if (names.length === 0) return
    if (NavState.currentPath === Paths.trashDir) {
      // NATIVE permanent delete: FileOperations.remove instead
      // of `rm -rf`/`rm -f`. No undo possible. TrashState.trashInfo (see
      // trash-info.sh) knows the real physical root of each item -- it can be the
      // home trash or that of any other mounted disk, Paths.trashDir can no longer
      // be assumed outright. For each item the file at
      // <root>/files/<n> (recursive) and its <root>/info/<n>.trashinfo are deleted, both
      // with ignoreMissing (= `rm -f`: it being missing is not an error).
      var paths = []
      names.forEach(function (n) {
        var info = TrashState.trashInfo[n]
        if (!info) return
        paths.push(info.trashRoot + "/files/" + n)
        paths.push(info.trashRoot + "/info/" + n + ".trashinfo")
      })
      if (paths.length > 0) {
        runNativeRemove(paths, "", true)
      } else {
        // TrashState.trashInfo can genuinely lag the file listing now that
        // requestTrashInfo() is async (V1_1_P0_TRASH_FREEZE, post-fix
        // sanity audit): on a slow mount the names can already be visible
        // (dirModel.listMany finished) while trashInfo -- a SECOND, equally
        // slow discoverTrashRoots() pass -- is still in flight. Without
        // this, selecting+deleting in that window silently did nothing.
        Backend.Notifier.notify("Trash info is still loading — try again in a moment")
      }
    } else {
      // NATIVE send to trash: FileOperations.trash
      // (QFile::moveToTrash, XDG Trash) instead of `gio trash`. Original
      // absolute paths captured HERE (not inside the closures
      // below) -- NavState.currentPath may have changed by the time
      // the user presses undo, much later.
      var origPaths = names.map(function (n) { return Utils.joinPath(NavState.currentPath, n) })
      var label = names.length === 1 ? "delete \"" + names[0] + "\"" : "delete " + names.length + " items"
      runNativeTrash(origPaths, "", function (completed) {
        // The undo is only registered if the send confirmed success, and
        // ONLY for the items that actually made it to the trash -- `completed`
        // (never the full `origPaths`) is what _finishNative reports really
        // finished, so if item 3 of 5 fails/gets cancelled, undo only offers
        // to restore the 2 that genuinely moved (P1-1, architectural audit
        // 2026-08-17). Undo = restore BY ORIGINAL PATH: it searches in ALL the
        // active trashes for the .trashinfo whose original path matches, so
        // it works the same wherever the delete came from -- and it works
        // even if the user undoes much later without having ever opened the
        // Trash.
        var donePaths = completed.map(function (p) { return p.src })
        var doneLabel = donePaths.length === origPaths.length ? label
          : (donePaths.length + " of " + origPaths.length + " items deleted")
        pushUndo(doneLabel, function (onSettled) {
          return runNativeRestore(donePaths, "", onSettled)
        }, function (onSettled) {
          return runNativeTrash(donePaths, "", onSettled)
        })
      })
    }
  }

  // --- ClipboardOps ---

  function copySelected() {
    if (ArchiveState.inArchive) return
    var entries = SelectionState.selectedEntries()
    if (entries.length === 0) return
    ClipboardState.clipboardPaths = entries.map(function (e) { return Utils.entryPath(NavState.currentPath, e) })
    ClipboardState.clipboardMode = "copy"
    syncClipboardToSystem()
  }

  function cutSelected() {
    if (ArchiveState.inArchive) return
    var entries = SelectionState.selectedEntries()
    if (entries.length === 0) return
    ClipboardState.clipboardPaths = entries.map(function (e) { return Utils.entryPath(NavState.currentPath, e) })
    ClipboardState.clipboardMode = "cut"
    syncClipboardToSystem()
  }

  // Previously clipboardPaths was only internal -- copying in Omafiles and pasting
  // in another app (or the other way around) did not work. text/uri-list is the MIME type
  // most widely recognized (file managers, browsers, chat
  // apps...) -- wl-copy can only serve one type per invocation, so
  // broad compatibility is prioritized over being able to distinguish cut/copy
  // for OTHER apps (Omafiles does distinguish cut/copy for its own
  // actions via clipboardMode; this is only to interoperate with the outside).
  // Path(s) as plain text to the clipboard -- to paste into a
  // terminal/chat/another app, not to be confused with copySelected() (which copies
  // the FILES to paste them with paste()). Several selected ->
  // one path per line.
  function copyPathAbsoluteFor(entries) {
    if (!entries || entries.length === 0) return
    var paths = entries.map(function (e) { return Utils.entryPath(NavState.currentPath, e) })
    Backend.TerminalResolver.copyPathsAbsolute(paths)
  }

  function copyPathRelativeFor(entries) {
    if (!entries || entries.length === 0) return
    var paths = entries.map(function (e) { return Utils.entryPath(NavState.currentPath, e) })
    Backend.TerminalResolver.copyPathsRelative(paths, NavState.currentPath)
  }

  function copyPathUriFor(entries) {
    if (!entries || entries.length === 0) return
    var paths = entries.map(function (e) { return Utils.entryPath(NavState.currentPath, e) })
    Backend.TerminalResolver.copyPathsUri(paths)
  }

  function syncClipboardToSystem() {
    if (ClipboardState.clipboardPaths.length === 0) {
      Backend.TerminalResolver.copyText("")
      return
    }
    // carriage returns between URIs (RFC 2483) -- the DnD mimeData
    // below (dragMimeDataFor) already did it right; this matches it so
    // any external app that reads the clipboard receives the same
    // spec-correct format whichever path (copy or drag).
    Backend.TerminalResolver.copyPathsUri(ClipboardState.clipboardPaths)
  }

  // mode: "all" (no conflicts, as is) | "overwrite" | "skip"
  function runPaste(mode) {
    var conflictSet = {}
    ConflictState.pasteConflictNames.forEach(function (n) { conflictSet[n] = true })
    var sources = ClipboardState.clipboardPaths.filter(function (src) {
      if (mode !== "skip") return true
      var name = src.substring(src.lastIndexOf("/") + 1)
      return !conflictSet[name]
    })
    ConflictState.pasteConflictOpen = false
    ConflictState.pasteConflictNames = []
    if (sources.length > 0) {
      var isCut = ClipboardState.clipboardMode === "cut"
      var pairs = sources.map(function (src) {
        var name = src.substring(src.lastIndexOf("/") + 1)
        return { src: src, dest: Utils.joinPath(NavState.currentPath, name) }
      })
      var busyVerb = isCut ? "Moving " : "Copying "
      var busyLabel = pairs.length === 1
        ? busyVerb + "\"" + pairs[0].dest.substring(pairs[0].dest.lastIndexOf("/") + 1) + "\"…"
        : busyVerb + pairs.length + " items…"
      if (!isCut) {
        // NATIVE copy: FileOperations.copy instead of `cp -r`.
        // Copy has no undo (undoing it is ambiguous, see ActionEngine).
        runNativeCopy(pairs, busyLabel, mode === "overwrite")
      } else {
        // NATIVE move: FileOperations.move. Same undo model
        // (move back / redo), now also native -- 0 shell.
        var overwrite = mode === "overwrite"
        runNativeMove(pairs, busyLabel, overwrite, function (completed) {
          // `completed` (never the full `pairs`) is exactly what
          // _finishNative reports really moved -- if item 3 of `pairs` fails
          // or the user cancels mid-batch, undo only offers to reverse the
          // items that genuinely moved (P1-1, architectural audit 2026-08-17).
          var label = completed.length === pairs.length
            ? (pairs.length === 1
                ? "move \"" + pairs[0].dest.substring(pairs[0].dest.lastIndexOf("/") + 1) + "\""
                : "move " + pairs.length + " items")
            : (completed.length + " of " + pairs.length + " items moved")
          var reversed = completed.map(function (p) { return { src: p.dest, dest: p.src } })
          pushUndo(label, function (onSettled) {
            return runNativeMove(reversed, "", false, onSettled)      // undo: no-clobber
          }, function (onSettled) {
            return runNativeMove(completed, "", overwrite, onSettled) // redo: like the original, only what actually moved
          })
        })
      }
    }
    if (ClipboardState.clipboardMode === "cut") {
      ClipboardState.clipboardPaths = []
      ClipboardState.clipboardMode = ""
    }
  }

  function cancelPasteConflict() {
    ConflictState.pasteConflictOpen = false
    ConflictState.pasteConflictNames = []
  }

  // --- RenameOps ---



  // Native "new folder" paths in flight -> name. The undo is registered
  // only when FileOperations.mkdir finishes SUCCESSFULLY (see the Connections
  // below), not before nor on a redo. Same pattern as Persistence with
  // JsonStore (declarative Connections over the services singleton).

  function startRename(index) {
    if (ArchiveState.inArchive) return
    if (index < 0 || index >= NavState.visibleEntries.length) return
    EditModeState.creatingFolder = false
    EditModeState.creatingFile = false
    EditModeState.renamingIndex = index
  }

  function runPendingRename(overwrite) {
    var r = ConflictState.pendingRename
    ConflictState.pendingRename = null
    ConflictState.renameConflictOpen = false
    if (!r) return
    var oldName = r.oldPath.substring(r.oldPath.lastIndexOf("/") + 1)
    // Same as in makeLinkFor: the undo is only registered if the "mv"
    // actually happened. Before, it was always registered, even when runAction
    // discarded it because another action was in progress (the rename had
    // already been assumed done in the UI -- the input closed anyway).
    var renameCmd = "mv " + (overwrite ? "-f" : "-n") + " -- " + Util.shellQuote(r.oldPath) + " " + Util.shellQuote(r.newPath)
    runAction(renameCmd, undefined, function () {
      pushUndo("rename to \"" + oldName + "\"", function (onSettled) {
        return runAction("mv -n -- " + Util.shellQuote(r.newPath) + " " + Util.shellQuote(r.oldPath), undefined, onSettled)
      }, function (onSettled) {
        return runAction(renameCmd, undefined, onSettled)
      })
    })
  }

  function cancelPendingRename() {
    ConflictState.pendingRename = null
    ConflictState.renameConflictOpen = false
  }

  function startNewFolder() {
    if (ArchiveState.inArchive) return
    EditModeState.renamingIndex = -1
    NavState.searching = false
    EditModeState.creatingFile = false
    EditModeState.creatingFolder = true
  }

  function startNewFile() {
    if (ArchiveState.inArchive) return
    EditModeState.renamingIndex = -1
    NavState.searching = false
    EditModeState.creatingFolder = false
    EditModeState.creatingFile = true
  }

  // commitNewFile()/commitNewFolder() (check whether something with
  // that name already exists, further below in this file -- corrected
  // 2026-08-17, P2.1 follow-up, this used to name logic/ConflictActions.qml,
  // folded into ActionEngine.qml on 2026-08-15) are the conflict checks;
  // runPendingNewFile()/runPendingNewFolder() (here) are the real
  // execution, with overwrite=true if the user confirmed overwriting in
  // the conflict dialog.
  function runPendingNewFile(overwrite) {
    var pending = ConflictState.pendingNewFile
    ConflictState.pendingNewFile = null
    ConflictState.newFileConflictOpen = false
    if (!pending) return
    // overwrite: -rf first (it could be a whole folder, not just a
    // file) and then touch -- consistent with the "-f" already used by
    // paste/drop when overwriting (forces without going through the trash).
    var newFileCmd = (overwrite ? "rm -rf -- " + Util.shellQuote(pending.path) + " && " : "")
      + "touch -- " + Util.shellQuote(pending.path)
    runAction(newFileCmd, undefined, function () {
      // gio trash instead of rm: if the user already wrote something before
      // undoing, it goes to the trash instead of being lost with no recovery.
      // It does not try to restore whatever it may have overwritten -- same limit
      // that paste/drop with overwrite already has.
      pushUndo("new file \"" + pending.name + "\"", function (onSettled) {
        return runAction("gio trash -- " + Util.shellQuote(pending.path), undefined, onSettled)
      }, function (onSettled) {
        return runAction(newFileCmd, undefined, onSettled)
      })
    })
  }

  function cancelPendingNewFile() {
    ConflictState.pendingNewFile = null
    ConflictState.newFileConflictOpen = false
  }

  function runPendingNewFolder(overwrite) {
    var pending = ConflictState.pendingNewFolder
    ConflictState.pendingNewFolder = null
    ConflictState.newFolderConflictOpen = false
    if (!pending) return
    if (overwrite) {
      // Overwriting an already-existing name (rare case): it implies a
      // destructive rm -rf, it stays in the tested shell action engine -- Phase
      // 7 only wires the mkdir of the common case to the native backend.
      var cmd = "rm -rf -- " + Util.shellQuote(pending.path) + " && mkdir -p -- " + Util.shellQuote(pending.path)
      runAction(cmd, undefined, function () {
        pushUndo("new folder \"" + pending.name + "\"", function (onSettled) {
          return runAction("rmdir -- " + Util.shellQuote(pending.path), undefined, onSettled)
        }, function (onSettled) {
          return runAction(cmd, undefined, onSettled)
        })
      })
      return
    }
    // Common case: NATIVE mkdir. The undo is registered on
    // successful completion (see the Connections below).
    actionEngine._nativeMkdirPending[pending.path] = pending.name
    Backend.FileOperations.mkdir(pending.path)
  }

  // Closes the loop of the native "new folder": refreshes and registers the
  // undo when mkdir finishes well. Declarative like Persistence with
  // JsonStore.
  Connections {
    target: Backend.FileOperations
    function onFinished(op, path) {
      if (op !== "mkdir") return
      // Immediate refresh (like actionProc.onFinished): the active panel is
      // covered by the watcher, but refreshTick also refreshes the background
      // ones showing this same folder.
      navController.refresh()
      NavState.refreshTick += 1
      // A REDO of a previously-undone "new folder" in flight: fire its
      // onSettled (see undoLast()/redoLast()'s doc comment) instead of
      // registering a brand new undo entry -- Backend.FileOperations.mkdir()
      // has no completion-callback param of its own, so this Connections
      // handler is the only place that ever learns it actually finished.
      var redoOnSettled = actionEngine._nativeMkdirRedoPending[path]
      if (redoOnSettled !== undefined) {
        delete actionEngine._nativeMkdirRedoPending[path]
        redoOnSettled()
        return
      }
      var name = actionEngine._nativeMkdirPending[path]
      if (name === undefined) return // another mkdir entirely: do not re-register
      delete actionEngine._nativeMkdirPending[path]
      pushUndo("new folder \"" + name + "\"", function (onSettled) {
        // rmdir (not rm -rf): if there is already something inside, it fails instead of deleting it.
        return runAction("rmdir -- " + Util.shellQuote(path), undefined, onSettled)
      }, function (onSettled) {
        actionEngine._nativeMkdirRedoPending[path] = onSettled || function () {}
        Backend.FileOperations.mkdir(path) // redo: without re-registering
        return true
      })
    }
    function onError(op, path, message) {
      if (op === "mkdir" && actionEngine._nativeMkdirPending[path] !== undefined)
        delete actionEngine._nativeMkdirPending[path]
      // A pending redo that failed: no completion, so it never joins
      // undoStack again (same "silently dropped on failure" contract as
      // every other undo/redo closure, see undoLast()/redoLast()'s comment).
      if (op === "mkdir" && actionEngine._nativeMkdirRedoPending[path] !== undefined)
        delete actionEngine._nativeMkdirRedoPending[path]
      if (op === "mkdir" && message && message !== "cancelled")
        Backend.Notifier.notify(message || "Rename failed")
    }
  }

  function cancelPendingNewFolder() {
    ConflictState.pendingNewFolder = null
    ConflictState.newFolderConflictOpen = false
  }

  // --- FileOps ---

  function startBulkRename() {
    if (ArchiveState.inArchive) return
    DialogsState.bulkRenamePattern = "{name}{ext}"
    DialogsState.bulkRenameFind = ""
    DialogsState.bulkRenameReplace = ""
    DialogsState.bulkRenameOpen = true
  }

  function runPendingBulkRename() {
    var pairs = ConflictState.pendingBulkRename
    ConflictState.pendingBulkRename = null
    ConflictState.bulkRenameConflictOpen = false
    if (!pairs) return
    // Before, bulk rename was the only risky operation (along with chmod)
    // without any undo -- a badly written {n}/{name}/{ext} pattern could
    // rename dozens of files at once with no safety net.
    var toRename = pairs.filter(function (p) { return p.newName !== p.oldName })
    var cmds = toRename.map(function (p) {
      return "mv -n -- " + Util.shellQuote(p.oldPath) + " " + Util.shellQuote(p.newPath)
    })
    if (cmds.length === 0) return
    var bulkRenameCmd = chainCmds(cmds)
    runAction(bulkRenameCmd, "Renaming " + cmds.length + " items…", function () {
      var label = toRename.length === 1 ? "rename \"" + toRename[0].oldName + "\"" : "bulk rename " + toRename.length + " items"
      pushUndo(label, function (onSettled) {
        var undoCmds = toRename.map(function (p) {
          return "mv -n -- " + Util.shellQuote(p.newPath) + " " + Util.shellQuote(p.oldPath)
        })
        return runAction(chainCmds(undoCmds), undefined, onSettled)
      }, function (onSettled) {
        return runAction(bulkRenameCmd, undefined, onSettled)
      })
    })
  }

  function cancelPendingBulkRename() {
    ConflictState.pendingBulkRename = null
    ConflictState.bulkRenameConflictOpen = false
  }

  function commitChmod(mode) {
    ChmodState.chmodOpen = false
    mode = mode.trim()
    if (!/^[0-7]{3,4}$/.test(mode) || ChmodState.chmodNames.length === 0) return
    // -R is harmless over a loose file (it doesn't descend anywhere),
    // so it can be applied to the whole command without separating files from
    // folders -- simpler than two different chainCmds branches.
    var flag = ChmodState.chmodRecursive ? "-R " : ""
    var cmds = ChmodState.chmodNames.map(function (n) {
      return "chmod " + flag + mode + " -- " + Util.shellQuote(Utils.joinPath(NavState.currentPath, n))
    })
    var label = ChmodState.chmodNames.length === 1
      ? "Setting permissions for \"" + ChmodState.chmodNames[0] + "\"…"
      : "Setting permissions for " + ChmodState.chmodNames.length + " items…"
    // chmod was, along with bulk rename, the only real risky action
    // (even more so with -R) without any undo. It restores the original mode of
    // each selected item -- NOT that of its content if it was applied
    // recursively, see the chmodOriginalModes comment.
    var names = ChmodState.chmodNames
    var originalModes = ChmodState.chmodOriginalModes
    var chmodCmd = chainCmds(cmds)
    runAction(chmodCmd, label, function () {
      var undoLabel = names.length === 1 ? "permissions on \"" + names[0] + "\"" : "permissions on " + names.length + " items"
      pushUndo(undoLabel, function (onSettled) {
        var undoCmds = names.filter(function (n) { return !!originalModes[n] }).map(function (n) {
          return "chmod " + originalModes[n] + " -- " + Util.shellQuote(Utils.joinPath(NavState.currentPath, n))
        })
        if (undoCmds.length === 0) return false
        return runAction(chainCmds(undoCmds), undefined, onSettled)
      }, function (onSettled) {
        return runAction(chmodCmd, undefined, onSettled)
      })
    })
  }

  // ownerIdx: 0=owner (you) 1=group 2=other. bit: 4=read 2=write 1=execute.
  function toggleChmodBit(ownerIdx, bit) {
    var mode = String(ChmodState.chmodMode || "0")
    while (mode.length < 3) mode = "0" + mode
    var digits = mode.substring(mode.length - 3)
    var arr = [digits.charCodeAt(0) - 48, digits.charCodeAt(1) - 48, digits.charCodeAt(2) - 48]
    arr[ownerIdx] = arr[ownerIdx] ^ bit
    ChmodState.chmodMode = "" + arr[0] + arr[1] + arr[2]
  }

  function makeLinkFor(entry) {
    if (ArchiveState.inArchive) return
    if (!entry) return
    var target = Utils.joinPath(NavState.currentPath, entry.name)
    var linkName = "Link to " + entry.name
    var linkPath = Utils.joinPath(NavState.currentPath, linkName)
    // The undo is only registered if "ln -s" confirmed success -- before it was
    // registered blindly, so if a file with the name
    // "Link to X" already existed (ln without -f fails silently in that case), a later
    // Ctrl+Z deleted it anyway even though it had nothing to do with
    // the link that was attempted.
    var makeLinkCmd = "ln -s -- " + Util.shellQuote(target) + " " + Util.shellQuote(linkPath)
    runAction(makeLinkCmd, undefined, function () {
      pushUndo("make link \"" + linkName + "\"", function (onSettled) {
        return runAction("rm -- " + Util.shellQuote(linkPath), undefined, onSettled)
      }, function (onSettled) {
        return runAction(makeLinkCmd, undefined, onSettled)
      })
    })
  }

  function restoreFromTrash() {
    var entries = SelectionState.selectedEntries()
    if (entries.length === 0) return
    // NATIVE restore: FileOperations.restoreByOrigPath instead
    // of restore-by-origpath.sh. TrashState.trashInfo (see trash-info.sh) already
    // knows the absolute original path of each item, resolved even for the
    // trash of another disk (where Path= is relative to the mount point);
    // restoreByOrigPath uses it to locate the correct .trashinfo in
    // any active trash, without assuming a single one.
    var origPaths = entries
      .filter(function (e) { return !!TrashState.trashInfo[e.name] })
      .map(function (e) { return TrashState.trashInfo[e.name].origPath })
    if (origPaths.length === 0) {
      // Same async-trashInfo race as confirmDelete()'s permanent-delete
      // branch above -- see its comment.
      Backend.Notifier.notify("Trash info is still loading — try again in a moment")
      return
    }
    runNativeRestore(origPaths, entries.length === 1 ? "Restoring \"" + entries[0].name + "\"…" : "Restoring " + entries.length + " items…")
  }

  // Drag-and-drop, three steps, all in this file (stale comments here used
  // to describe a pre-Phase-43 split across logic/DragDropOps.qml and
  // logic/ConflictActions.qml, corrected 2026-08-17, P2.1 follow-up --
  // both files were folded into ActionEngine.qml on 2026-08-15):
  // handleFilesDropped() only resolves the DragEvent itself (accept/reject,
  // move vs copy); startDropInto() is the one that actually checks
  // conflicts via existingPaths() and opens ConflictState.dropConflictOpen
  // if needed; runDrop() (below) does the real mv/cp once any conflict is
  // resolved.

  function urlToPath(url) {
    var s = String(url)
    if (s.indexOf("file://") === 0) s = s.substring(7)
    try { return decodeURIComponent(s) } catch (e) { return s }
  }

  // MimeData of the file(s) that row `index` starts to drag --
  // if that row is already part of a multiple selection, it drags the whole
  // selection (like Nautilus); if not, only that row.
  function dragMimeDataFor(index) {
    var indices = (SelectionState.isSelected(index) && SelectionState.selectedIndices.length > 1) ? SelectionState.selectedIndices : [index]
    var paths = indices
      .filter(function (i) { return i >= 0 && i < NavState.visibleEntries.length })
      .map(function (i) { return Utils.joinPath(NavState.currentPath, NavState.visibleEntries[i].name) })
    var data = {}
    data["text/uri-list"] = paths.map(function (p) { return Util.fileUrl(p) }).join("\r\n")
    return data
  }

  // runDrop() (below) executes the real mv/cp after resolving a drop
  // conflict -- see the drag-and-drop comment above handleFilesDropped().

  function cancelDropConflict() {
    ConflictState.dropConflictOpen = false
    ConflictState.dropConflictNames = []
    ConflictState.dropPendingSources = []
    ConflictState.dropTargetDir = ""
  }

  // Called from each DropArea (folder row, bookmark, drive, list
  // background) with the real DragEvent and the destination folder already resolved.
  function handleFilesDropped(drop, destDir) {
    if (ArchiveState.inArchive) { drop.accepted = false; return }
    if (!drop.hasUrls) { drop.accepted = false; return }
    var paths = drop.urls.map(function (u) { return urlToPath(u) }).filter(function (p) { return p.length > 0 })
    if (paths.length === 0) { drop.accepted = false; return }
    var isMove = drop.source !== null && drop.source !== undefined
    drop.accept(isMove ? Qt.MoveAction : Qt.CopyAction)
    actionEngine.startDropInto(destDir, paths, isMove)
  }



  function paste() {
    if (ArchiveState.inArchive) return
    if (ClipboardState.clipboardPaths.length === 0) {
      // Nothing copied from INSIDE Omafiles -- try the system
      // clipboard (copy in Nautilus/the browser/a chat/etc. and paste
      // here). It is always treated as "copy", never "cut": a
      // loose text/uri-list does not carry that distinction (unlike
      // GTK's own x-special/gnome-copied-files, which not all apps
      // that copy paths write).
      systemClipboardReadProc.start(["wl-paste", "-t", "text/uri-list"])
      return
    }
    var destPaths = ClipboardState.clipboardPaths.map(function (src) {
      var name = src.substring(src.lastIndexOf("/") + 1)
      return Utils.joinPath(NavState.currentPath, name)
    })
    // NATIVE conflict detection: FileOperations.existingPaths
    // (synchronous stat) instead of a `test -e` via shell. Same observable
    // result: 0 conflicts -> pastes now; if any, opens the dialog.
    var conflicts = Backend.FileOperations.existingPaths(destPaths)
    if (conflicts.length === 0) {
      actionEngine.runPaste("all")
    } else {
      ConflictState.pasteConflictNames = conflicts.map(function (p) { return p.substring(p.lastIndexOf("/") + 1) })
      ConflictState.pasteConflictOpen = true
    }
  }

  function startDropInto(destDir, sourcePaths, isMove) {
    if (!destDir) return
    sourcePaths = sourcePaths.filter(function (src) {
      var srcDir = src.substring(0, src.lastIndexOf("/"))
      // Avoids dropping onto the source folder itself (no-op) or inside
      // itself if the dragged file is actually a folder.
      return src !== destDir && srcDir !== destDir && (destDir + "/").indexOf(src + "/") !== 0
    })
    if (sourcePaths.length === 0) return
    ConflictState.dropPendingSources = sourcePaths
    ConflictState.dropTargetDir = destDir
    ConflictState.dropIsMove = isMove
    var destPaths = sourcePaths.map(function (src) {
      return Utils.joinPath(destDir, src.substring(src.lastIndexOf("/") + 1))
    })
    // NATIVE conflict detection: same as paste().
    var conflicts = Backend.FileOperations.existingPaths(destPaths)
    if (conflicts.length === 0) {
      runDrop("all")
    } else {
      ConflictState.dropConflictNames = conflicts.map(function (p) { return p.substring(p.lastIndexOf("/") + 1) })
      ConflictState.dropConflictOpen = true
    }
  }

  // format: "zip" (default) | "tar.gz" | "7z" -- V1.1, extends compress
  // beyond the previously hardcoded .zip-only (docs/audits/
  // V1_1_FEATURE_INVENTORY.md §8/§9). Same conflict/progress machinery for
  // all three; only the archive extension and the actual command differ.
  function compressSelected(format) {
    if (ArchiveState.inArchive) return
    var entries = SelectionState.selectedEntries()
    if (entries.length === 0) return
    var ext = format === "tar.gz" ? ".tar.gz" : (format === "7z" ? ".7z" : ".zip")
    var archiveName = entries.length === 1
      ? entries[0].name.replace(/\/$/, "") + ext
      : "selected-files" + ext
    var names = entries.map(function (e) { return Util.shellQuote(e.name) }).join(" ")
    // "rm -f" before creating: if the user confirms overwriting an
    // already-existing archiveName, make it a real replacement -- without
    // the rm, "zip -r"/"7z a" ADD/update entries inside the existing
    // archive instead of replacing it, so confirming "overwrite" did not
    // actually leave a clean archive with only what is selected now (tar
    // doesn't have this problem -- "tar c" always truncates -- but rm
    // first keeps the three paths uniform).
    // "./" before the archive name + "--" before the file list: a real
    // file named, for example, "-rf" (a valid name in Linux) would
    // otherwise be interpreted as flags instead of as a file name --
    // confirmed directly (2026-08-18) this bites all three tools the same
    // way, not just zip (zip additionally rejects a bare "--" right before
    // the archive name itself, "can't use -- before archive name", hence
    // "./" specifically rather than "--" there for all three, for one
    // uniform rule instead of a per-tool exception).
    // Verbose, V1.1: one line per file/dir touched, for progress (see
    // runActionWithProgress()) -- zip/tar do this by default with -v; 7z's
    // "a" (add) is quiet by default unlike its "x" (extract), so -bb1
    // (confirmed directly: prints "+ <name>" per file) is added just for
    // this branch. entries.length is used as the progress total below --
    // exact for a flat file selection; a selected folder makes any of the
    // three recurse and print more lines than that, so the bar reaches
    // 100% a beat before the process actually finishes rather than
    // undercounting visibly -- an accepted approximation rather than a
    // second async pre-pass just to recursively pre-count entries.
    var cmd
    if (format === "tar.gz") {
      cmd = "cd -- " + Util.shellQuote(NavState.currentPath) + " && rm -f -- " + Util.shellQuote(archiveName)
        + " && tar czvf " + Util.shellQuote("./" + archiveName) + " -- " + names
    } else if (format === "7z") {
      cmd = "cd -- " + Util.shellQuote(NavState.currentPath) + " && rm -f -- " + Util.shellQuote(archiveName)
        + " && 7z a -bb1 " + Util.shellQuote("./" + archiveName) + " -- " + names
    } else {
      cmd = "cd -- " + Util.shellQuote(NavState.currentPath) + " && rm -f -- " + Util.shellQuote(archiveName)
        + " && zip -r " + Util.shellQuote("./" + archiveName) + " -- " + names
    }
    ConflictState.pendingCompress = { archiveName: archiveName, cmd: cmd, total: entries.length }
    // NATIVE conflict (BUG-01): existingPaths instead of `test -e` via shell.
    if (Backend.FileOperations.existingPaths([Utils.joinPath(NavState.currentPath, archiveName)]).length > 0)
      ConflictState.compressConflictOpen = true
    else
      actionEngine.runPendingCompress()
  }

  function commitBulkRename() {
    var entries = SelectionState.selectedEntries()
    DialogsState.bulkRenameOpen = false
    if (entries.length === 0) return
    var pattern = DialogsState.bulkRenamePattern
    BookmarksState.addBulkRenameHistory(pattern)
    // Utils.bulkRenameNames() is the single source of truth for the name
    // transformation -- also used by BulkRenamePanel.qml's live preview, so
    // what gets shown before confirming can never diverge from what
    // actually happens here.
    var pairs = Utils.bulkRenameNames(entries, pattern, DialogsState.bulkRenameFind, DialogsState.bulkRenameReplace).map(function (n) {
      return {
        oldName: n.oldName, newName: n.newName,
        oldPath: Utils.joinPath(NavState.currentPath, n.oldName),
        newPath: Utils.joinPath(NavState.currentPath, n.newName)
      }
    })
    // Validate the WHOLE batch upfront, before any conflict check or
    // filesystem call (P2.7, 2026-08-17): a pattern like "{ext}" on an
    // extensionless file, or one that strips everything, can produce an
    // empty name. Without this guard it wasn't a clean silent no-op
    // either: Utils.joinPath(currentPath, "") resolves to currentPath
    // itself, which of course always "already exists" -- so the empty
    // pair tripped the existingPaths() collision check below and opened
    // the bulk-rename CONFLICT dialog, misleadingly presenting an invalid
    // pattern as an "overwrite?" decision. Confirming that dialog would
    // reach runPendingBulkRename() with the empty pair still in it,
    // running `mv -n -- oldpath ''`. Unlike commitRename's own
    // `if (!newName) return` (a single name the user typed themselves, a
    // silent no-op reads as "I didn't confirm"), this is a DERIVED result
    // across possibly many files the user can't preview -- so this gets
    // an explicit, correctly-worded notification instead, same style as
    // the other "couldn't do this" messages in this file.
    var emptyNames = pairs.filter(function (p) { return !p.newName })
    if (emptyNames.length > 0) {
      Backend.Notifier.notify(emptyNames.length === 1
        ? "Bulk rename: pattern produces an empty name for \"" + emptyNames[0].oldName + "\" — nothing renamed"
        : "Bulk rename: pattern produces an empty name for " + emptyNames.length + " items — nothing renamed")
      return
    }
    ConflictState.pendingBulkRename = pairs
    var targetCounts = {}
    pairs.forEach(function (p) {
      if (p.newName === p.oldName) return
      targetCounts[p.newPath] = (targetCounts[p.newPath] || 0) + 1
    })
    ConflictState.bulkRenameInternalDupes = Object.keys(targetCounts).filter(function (k) { return targetCounts[k] > 1 }).length
    var checkPaths = pairs.filter(function (p) { return p.newName !== p.oldName })
                          .map(function (p) { return p.newPath })
    var total = Backend.FileOperations.existingPaths(checkPaths).length + ConflictState.bulkRenameInternalDupes
    if (total === 0) {
      actionEngine.runPendingBulkRename()
    } else {
      ConflictState.bulkRenameConflictCount = total
      ConflictState.bulkRenameConflictOpen = true
    }
  }

  function extractHere(entry) {
    var ext = Utils.extOf(entry.name)
    var path = Util.shellQuote(Utils.joinPath(NavState.currentPath, entry.name))
    var dir = Util.shellQuote(NavState.currentPath)
    var cmd, listCmd
    // All force overwrite (-o/-y/-o+) -- needed so that
    // runPendingExtract can actually overwrite after confirming the
    // conflict notice below. listCmd uses the "flat list" mode of
    // each tool (name per line, no header) to know what would be
    // clobbered, without needing to parse tables -- its raw line count
    // doubles as the progress total (V1.1): each tool's VERBOSE (not
    // quiet) extraction output prints exactly one line per entry too, so
    // "how many of these lines have I seen" tracks "how far along am I"
    // without needing a per-tool byte-progress format (none of the four
    // agree on one). unzip drops -q for this; 7z/unrar already print one
    // line per file by default, no flag needed.
    if (ext === "zip") { cmd = "unzip -o " + path + " -d " + dir; listCmd = "unzip -Z1 -- " + path }
    else if (ext === "7z") { cmd = "7z x -y " + path + " -o" + dir; listCmd = "7z l -ba -slt -- " + path + " | grep '^Path = ' | sed 's/^Path = //'" }
    else if (ext === "rar") { cmd = "unrar x -o+ " + path + " " + dir + "/"; listCmd = "unrar lb -- " + path }
    // No "--" on purpose, unlike the other three -- with "tf"
    // (grouped short form of -t -f) tar takes the NEXT token as
    // the direct argument of -f, so a "--" there is interpreted as the
    // file name itself to open and tar fails with "--: No such file or
    // directory". Real bug: this made the conflict check
    // ALWAYS fail silently for tar/tar.gz/tar.bz2/tar.xz (listCmd
    // returned nothing -> 0 conflicts always detected), although zip/7z/
    // rar were not affected. "v" (verbose) added to "xf" for progress --
    // same argument-order concern doesn't apply, it's not "--".
    else if (FileTypeConfig.tarExt.indexOf(ext) >= 0) { cmd = "tar xvf " + path + " -C " + dir; listCmd = "tar tf " + path }
    else return
    // Before, this overwrote without asking, unlike paste/drop/
    // rename (which do check conflicts). Before extracting, the
    // content of the archive is listed and it is checked whether any top-
    // level element already exists in the current folder.
    // Multi-volume detection (V1.1): if this is one part of a numbered set
    // (foo.part01.rar..NN, foo.7z.001..NNN), runPendingExtract() below
    // weights progress by real volume size and shows which one is active
    // instead of the flat per-line fallback (see _multiVolumeSiblings()).
    ConflictState.pendingExtract = { entry: entry, cmd: cmd, volumes: actionEngine._multiVolumeSiblings(entry.name) }
    extractListProc.start(["bash", "-c", listCmd])
  }

  function commitRename(newName) {
    var index = EditModeState.renamingIndex
    EditModeState.renamingIndex = -1
    // Defense in depth: startRename() already blocks STARTING a
    // rename inside an archive, but it doesn't cover the case of starting to
    // rename OUTSIDE, not confirming, and entering a .zip in the meantime --
    // renamingIndex keeps pointing to an index that now belongs to
    // an archive entry, and without this guard commitRename would run mv
    // over currentPath/<zip-name>, which may coincide by
    // chance with a real file.
    if (ArchiveState.inArchive) return
    if (index < 0 || index >= NavState.visibleEntries.length) return
    var oldName = NavState.visibleEntries[index].name
    newName = newName.trim()
    if (!newName || newName === oldName) return
    var oldPath = Utils.joinPath(NavState.currentPath, oldName)
    var newPath = Utils.joinPath(NavState.currentPath, newName)
    ConflictState.pendingRename = { oldPath: oldPath, newPath: newPath }
    // NATIVE conflict (BUG-01): existingPaths instead of `test -e` via shell.
    if (Backend.FileOperations.existingPaths([newPath]).length > 0) ConflictState.renameConflictOpen = true
    else actionEngine.runPendingRename(false)
  }

  // Existence check BEFORE creating -- real bug fixed here
  // (josema, 2026-08-05): touch/mkdir -p are idempotent (silent
  // success over something that already existed), so without this guard "New
  // file"/"New folder" with a conflicting name created nothing new
  // but DID register an undo -- a later Ctrl+Z sent to the
  // trash the truly PRE-EXISTING item. Now, instead of failing
  // silently (a notify-send easy to miss), the same
  // Overwrite/Cancel dialog that rename already uses is offered.
  function commitNewFile(name) {
    EditModeState.creatingFile = false
    name = name.trim()
    if (!name) return
    var path = Utils.joinPath(NavState.currentPath, name)
    ConflictState.pendingNewFile = { path: path, name: name }
    // NATIVE conflict (BUG-01): existingPaths instead of `test -e` via shell.
    if (Backend.FileOperations.existingPaths([path]).length > 0) ConflictState.newFileConflictOpen = true
    else actionEngine.runPendingNewFile(false)
  }

  function commitNewFolder(name) {
    EditModeState.creatingFolder = false
    EditModeState.creatingFile = false
    name = name.trim()
    if (!name) return
    var path = Utils.joinPath(NavState.currentPath, name)
    ConflictState.pendingNewFolder = { path: path, name: name }
    // NATIVE conflict (BUG-01): existingPaths instead of `test -e` via shell.
    if (Backend.FileOperations.existingPaths([path]).length > 0) ConflictState.newFolderConflictOpen = true
    else actionEngine.runPendingNewFolder(false)
  }

  Backend.ProcessRunner {
    id: systemClipboardReadProc
    onFinished: function (result) {
      // Real bug: RFC 2483 requires CRLF between URIs of a text/uri-list, and
      // the real GTK apps (Nautilus, file pickers,
      // Firefox...) write it that way -- without removing the "\r" that stays
      // stuck at the end of each line, decodeURIComponent left it
      // stuck in the path, pasteCheckProc.test -e never found it, and
      // pasting from outside Omafiles failed silently with no
      // notice.
      var uris = String(result.stdout || "").split("\n").map(function (l) { return l.replace(/\r$/, "") }).filter(function (l) { return l.length > 0 })
      var paths = uris.map(function (u) {
        return u.indexOf("file://") === 0 ? decodeURIComponent(u.substring(7)) : ""
      }).filter(function (p) { return p.length > 0 })
      // Empty = system clipboard with no uris (or nothing) -- there is
      // nothing to notify, paste() did nothing either before in this
      // case.
      if (paths.length === 0) return
      ClipboardState.clipboardPaths = paths
      ClipboardState.clipboardMode = "copy"
      paste()
    }
  }

  Backend.ProcessRunner {
    id: extractListProc
    onFinished: function (result) {
      var rawLines = String(result.stdout || "").split("\n").filter(function (l) { return l.trim() !== "" })
      // Progress total (V1.1): the RAW per-entry line count, not the
      // deduped top-level one below -- this is what the verbose extraction
      // command will print one line per, so it's what onLineRead counts
      // against (see extractHere()/runActionWithProgress()).
      if (ConflictState.pendingExtract) ConflictState.pendingExtract.total = rawLines.length
      var top = {}
      rawLines.forEach(function (line) {
        var name = line.replace(/\/+$/, "")
        if (!name) return
        var slash = name.indexOf("/")
        top[slash >= 0 ? name.substring(0, slash) : name] = true
      })
      var names = Object.keys(top)
      if (names.length === 0) { actionEngine.runPendingExtract(); return }
      // NATIVE conflict (BUG-01): existingPaths over the top-level
      // elements of the archive, instead of a `test -e` per name. (The archive
      // LISTING -- list_raw above -- is still shell: that is not conflict
      // detection and is out of BUG-01's scope.)
      var conflicts = Backend.FileOperations.existingPaths(names.map(function (n) {
        return Utils.joinPath(NavState.currentPath, n)
      })).map(function (p) { return p.substring(p.lastIndexOf("/") + 1) })
      if (conflicts.length === 0) {
        actionEngine.runPendingExtract()
      } else {
        ConflictState.extractConflictNames = conflicts
        ConflictState.extractConflictOpen = true
      }
    }
  }


  // Files dropped onto `destDir` (a folder row, a bookmark,
  // a drive, or the background of the list = the folder open right now).
  // `isMove` comes from DragEvent.source !== null (internal drag) --
  // drags coming from outside always copy, never move the source.
  // mode: "all" (no conflicts) | "overwrite" | "skip". Originally lived in
  // logic/DragDropOps.qml, moved here pre-Phase-43 to break a circular
  // dependency with the conflict-check logic (DragDropOps needed it to
  // check conflicts, and it needed DragDropOps only for this) -- both
  // files were folded into ActionEngine.qml on 2026-08-15 (corrected
  // 2026-08-17, P2.1 follow-up), so the two are one file today and the
  // cycle no longer exists to avoid, but drag-and-drop conflict
  // resolution and its execution stay next to each other on purpose.
  function runDrop(mode) {
    var conflictSet = {}
    ConflictState.dropConflictNames.forEach(function (n) { conflictSet[n] = true })
    var sources = ConflictState.dropPendingSources.filter(function (src) {
      if (mode !== "skip") return true
      var name = src.substring(src.lastIndexOf("/") + 1)
      return !conflictSet[name]
    })
    ConflictState.dropConflictOpen = false
    ConflictState.dropConflictNames = []
    if (sources.length > 0) {
      var destDir = ConflictState.dropTargetDir
      var isMove = ConflictState.dropIsMove
      var pairs = sources.map(function (src) {
        var name = src.substring(src.lastIndexOf("/") + 1)
        return { src: src, dest: Utils.joinPath(destDir, name) }
      })
      var busyVerb = isMove ? "Moving " : "Copying "
      var busyLabel = pairs.length === 1
        ? busyVerb + "\"" + pairs[0].dest.substring(pairs[0].dest.lastIndexOf("/") + 1) + "\"…"
        : busyVerb + pairs.length + " items…"
      if (!isMove) {
        // NATIVE copy: FileOperations.copy instead of `cp -r`.
        actionEngine.runNativeCopy(pairs, busyLabel, mode === "overwrite")
      } else {
        // NATIVE move: FileOperations.move. Same undo model
        // (move back / redo), now also native -- 0 shell.
        var overwrite = mode === "overwrite"
        actionEngine.runNativeMove(pairs, busyLabel, overwrite, function (completed) {
          // `completed` (never the full `pairs`) is exactly what
          // _finishNative reports really moved -- see the identical comment
          // in runPaste() above (P1-1, architectural audit 2026-08-17).
          var label = completed.length === pairs.length
            ? (pairs.length === 1
                ? "move \"" + pairs[0].dest.substring(pairs[0].dest.lastIndexOf("/") + 1) + "\""
                : "move " + pairs.length + " items")
            : (completed.length + " of " + pairs.length + " items moved")
          var reversed = completed.map(function (p) { return { src: p.dest, dest: p.src } })
          actionEngine.pushUndo(label, function (onSettled) {
            return actionEngine.runNativeMove(reversed, "", false, onSettled)      // undo: no-clobber
          }, function (onSettled) {
            return actionEngine.runNativeMove(completed, "", overwrite, onSettled) // redo: like the original, only what actually moved
          })
        })
      }
    }
    ConflictState.dropPendingSources = []
    ConflictState.dropTargetDir = ""
  }



  // isArchive()/enterArchive()/exitArchive()/refreshArchiveListing()/
  // openFileInArchive() moved to logic/ArchiveBrowser.qml (architectural
  // audit 2026-08-17, P2.3) -- archive browsing never used runAction()/
  // pushUndo()/the native-batch machinery, the one block in this file with
  // a genuinely independent lifecycle. isIso() stays: ISO mounting
  // (logic/MountActions.qml) is a different mechanism entirely, not
  // archive browsing -- it only ever sat next to isArchive() here because
  // both are "can this file be entered like a folder" checks.
  function isIso(entry) {
    return entry.type !== "dir" && Utils.extOf(entry.name) === "iso"
  }

  function runPendingCompress() {
    var p = ConflictState.pendingCompress
    ConflictState.pendingCompress = null
    ConflictState.compressConflictOpen = false
    if (!p) return
    actionEngine.runActionWithProgress(p.cmd, "Compressing to \"" + p.archiveName + "\"…", p.total || 0)
  }

  function cancelPendingCompress() {
    ConflictState.pendingCompress = null
    ConflictState.compressConflictOpen = false
  }

  function runPendingExtract() {
    var p = ConflictState.pendingExtract
    ConflictState.pendingExtract = null
    ConflictState.extractConflictOpen = false
    ConflictState.extractConflictNames = []
    if (!p) return
    actionEngine.runActionWithProgress(p.cmd, "Extracting \"" + p.entry.name + "\"…", p.total || 0, undefined, p.volumes)
  }

  function cancelPendingExtract() {
    ConflictState.pendingExtract = null
    ConflictState.extractConflictOpen = false
    ConflictState.extractConflictNames = []
  }

}

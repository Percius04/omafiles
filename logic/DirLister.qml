import QtQuick
import "../state"
import Omafiles.Backend as Backend

// Lists a directory and exposes the result already sorted -- twenty-third
// component extracted from core. Reused by
// NavigationController (active panel, one instance) and BackgroundPanel (one
// per background tab). Each has its instance: several tabs
// can list different paths at once.
//
// Phase 6.C/6.D (josema): 100% NATIVE listing backend. list-dir.sh
// and list-trash.sh are no longer launched; the listing is done by Omafiles.Backend.
// DirectoryModel (QAbstractListModel over readdir/stat), and the change
// watching is done by its internal QFileSystemWatcher (without forking
// inotifywait). Thin adapter over the model:
//   - normal folder -> dirModel.list(path)
//   - Trash -> trash-roots.sh (discover XDG roots) + dirModel.listMany
//     (merge the content of all) + trash-info.sh (metadata)
// The public API (entries/pathError/loaded/listed/list) does not change, so
// NavigationController and BackgroundPanel stay the same.
Item {
  id: dirLister
  property string trashDir: ""
  property bool showHidden: false

  property var entries: []
  property string pathError: ""
  property bool loaded: false

  // Emitted every time entries is actually resolved (with new
  // or repeated content) -- different from onEntriesChanged, which with QML does not
  // fire if the resulting array is equal (same bug that _apply()
  // avoids by reassigning only if it changed). Whoever needs to react to EACH
  // listing, whether or not the content changed (e.g. _finishListLoad in the active
  // panel: scroll/selection reset), must use this signal.
  signal listed()

  // The content of the watched folder changed (re-forwards dirModel.directoryChanged).
  // NavigationController hooks here for its debounce + refresh.
  signal directoryChanged()

  property string _targetPath: ""
  // Mode of the last scan launched to the model ("dir" or "trash"). Together with
  // the model's internal generation, it discards obsolete results on
  // switching between a normal folder and the Trash (the model serves
  // both): a result whose mode does not match the current path is thrown away.
  property string _dirMode: "dir"
  // Content signature of the last APPLIED listing (DirectoryModel.signature,
  // 64-bit hash computed on the worker). Phase 27 (PERF_AUDIT_RC1): the guard
  // "did the folder change?" goes from an O(n) Utils.entriesEqual —which iterated the
  // 100k entries on the UI thread and forced materializing the whole array
  // (measured: 342 ms/refresh at 100k)— to an O(1) string comparison.
  property string _lastSignature: ""

  function list(path) {
    _targetPath = path
    pathError = ""
    if (path === trashDir) {
      // The Trash aggregates the home root PLUS the .Trash-$UID of any
      // mounted disk (XDG Trash spec). FileOperations.trashRoots()
      // discovers them (native, Phase 16: replaces trash-roots.sh); then the
      // content of all is merged with listMany. It is not a single folder,
      // which is why it does not go through dirModel.list plainly.
      var paths = Backend.FileOperations.trashRoots().map(function (r) { return r + "/files" })
      _dirMode = "trash"
      dirModel.listMany(paths, showHidden)
    } else {
      _dirMode = "dir"
      dirModel.list(path, showHidden)
    }
  }

  // Native watching of the current directory via QFileSystemWatcher.
  function watch(path) {
    return dirModel.watch(path)
  }

  function unwatch() {
    dirModel.unwatch()
  }

  // Reassigns entries ONLY if the content actually changed -- QML/
  // ListView does not compare the content of a model array, only the
  // reference, so reassigning even if the data is identical
  // triggers a full relayout (recreates ALL the rows from scratch,
  // a visible jump reported by josema -- see the history of
  // NavigationController/BackgroundPanel before this extraction).
  function _apply() {
    // Guard "did the folder change?" by SIGNATURE, not by content:
    // DirectoryModel.signature is a content hash computed on the worker
    // thread. Previously it was compared with Utils.entriesEqual, O(n) on
    // the UI thread, which also forced materializing the WHOLE lazy array
    // (dirModel.entries) on walking it. Now dirModel.entries is only
    // read/materialized when the signature actually changed -> the watcher's
    // refreshes over unchanged folders cost a string comparison.
    // The SAME `entries` reference is kept when it did not change, so
    // NavigationController can compare by reference upstream.
    var sig = dirModel.signature
    if (sig !== _lastSignature) {
      _lastSignature = sig
      entries = _sorted(dirModel.entries)
    }
    loaded = true
    listed()
  }

  // Final order: C++ (DirectoryModel) already returns the entries sorted by
  // naturalCompare (folders first) -- the default order the user
  // sees. It only needs re-sorting in JS if the user chose another
  // criterion (size/date/type or descending). Phase 10.A: eliminates the ~31 ms
  // of re-sorting on the UI thread what C++ already sorted.
  function _sorted(raw) {
    return SortState.isDefaultOrder ? raw : SortState.sortEntries(raw)
  }

  // Native listing backend (Phase 6.C/6.D). Serves both normal folders
  // (list) and the Trash (listMany). The dirModel.entries array has the
  // same shape {type,name,size,mtime,link} that Utils.parseEntries produced,
  // and goes through the same sortOps.sortEntries + _apply.
  Backend.DirectoryModel {
    id: dirModel
    // Qualified with the id: dirModel ALSO has a directoryChanged
    // signal, so without qualifying, the model's own one would be re-emitted
    // (name collision) instead of DirLister's.
    onDirectoryChanged: dirLister.directoryChanged()
    onListed: {
      var isTrash = (_targetPath === trashDir)
      // Discards results of a mode that no longer matches the current
      // path (folder<->trash race). The model's internal generation
      // covers folder->folder; this guard covers the mode crossing.
      if (isTrash !== (_dirMode === "trash")) return

      if (isTrash) {
        // listMany does not produce error codes (aggregate); the Trash
        // simply shows whatever is there. NATIVE trash metadata
        // (FileOperations.trashInfo, Phase 16: replaces trash-info.sh):
        // synchronous, so it is filled BEFORE painting -- without the previous
        // async dance (nor flicker). TrashState.trashInfo is shared by
        // the active panel and the background ones; DeleteOps/FileOps use it to
        // know the physical root of each item on restore/delete.
        var arr = Backend.FileOperations.trashInfo()
        var info = {}
        for (var i = 0; i < arr.length; i++)
          info[arr[i].payloadPath] = { origPath: arr[i].origPath, epoch: arr[i].epoch,
                                      trashRoot: arr[i].trashRoot, payloadPath: arr[i].payloadPath }
        TrashState.trashInfo = info
        _apply()
      } else {
        // Normal folder: map the model's error to pathError with the
        // SAME codes that list-dir.sh's exit codes gave.
        var e = dirModel.error
        if (e === 2) pathError = "Permission denied"
        else if (e === 3) pathError = "This folder no longer exists"
        else if (e === 4) pathError = "Not a folder"
        else if (e !== 0) pathError = "Couldn't open this folder"
        _apply()
      }
    }
  }
}

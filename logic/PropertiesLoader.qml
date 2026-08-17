import QtQuick
import "../state"
import Omafiles.Backend as Backend
import "../shared/Utils.js" as Utils

// File metadata loading (permissions and properties) -- eighteenth
// component extracted from core. Bundles startChmod()/showProperties()/
// showPropertiesForSelection() with the three Process that feed them (stat of
// permissions, stat of properties, du), which used to live over a thousand
// lines away from the function that launched them. ChmodPanel.qml/
// PropertiesPanel.qml (already extracted earlier) only paint ChmodState.chmodMode/
// PropertiesState.propertiesSize/etc. -- this component is the one that fills them.
//
// Deliberately does NOT include commitChmod/chmodDigit/chmodBitSet/
// toggleChmodBit (they stay in core) -- those don't touch any
// Process, they only read/write ChmodState.chmodMode and go through runAction() (the
// central action/undo system), so moving them here wouldn't have
// eliminated any duplication nor brought anything closer to what does launch.
Item {
  property Item root: null

  function startChmod(entries) {
    if (ArchiveState.inArchive) return
    if (!entries || entries.length === 0) return
    var basePath = NavState.currentPath
    var paths = entries.map(function (e) { return Utils.entryPath(basePath, e) })
    ChmodState.chmodNames = entries.map(function (e) { return e.name })
    ChmodState.chmodHasDir = entries.some(function (e) { return e.type === "dir" })
    ChmodState.chmodRecursive = false
    // NATIVE octal mode (BUG-03): octalModes instead of a `stat -c%a -- <all
    // the paths>` on a single bash line, which blew ARG_MAX with a huge
    // selection. It returns the mode in the SAME order as the paths ("" if it
    // fails), so the mapping with chmodNames (for undo) stays aligned.
    var modes = Backend.FileOperations.octalModes(paths)
    var valid = modes.filter(function (m) { return m.length > 0 })
    var allSame = valid.length > 0 && valid.every(function (m) { return m === valid[0] })
    ChmodState.chmodMixed = !allSame
    ChmodState.chmodMode = allSame ? valid[0] : ""
    var orig = {}
    for (var i = 0; i < ChmodState.chmodNames.length && i < modes.length; i++)
      if (modes[i].length > 0) orig[ChmodState.chmodNames[i]] = modes[i]
    ChmodState.chmodOriginalModes = orig
    ChmodState.chmodRecords = entries.map(function (e, i) {
      return { name: e.name, path: paths[i], originalMode: modes[i] || "" }
    })
    ChmodState.chmodOpen = true
  }

  function showPropertiesForSelection() {
    // NavState.currentPath is still the real folder containing the
    // file while browsing inside it -- without this guard,
    // Properties would try to stat/du "real-folder/name-inside-
    // the-zip", which does not exist (or, worse, could coincide by chance
    // with a real file of that name in the containing folder and
    // show data of ANOTHER file without the error being noticed).
    if (ArchiveState.inArchive) return
    var entries = SelectionState.selectedEntries()
    if (entries.length === 0) return
    if (entries.length === 1) { showProperties(entries[0]); return }
    PropertiesState.propertiesRequestId += 1
    PropertiesState.propertiesMulti = true
    PropertiesState.propertiesEntry = null
    PropertiesState.propertiesCount = entries.length
    PropertiesState.propertiesSize = ""
    PropertiesState.propertiesSizeLoading = true
    PropertiesState.propertiesPerms = ""
    PropertiesState.propertiesOwner = ""
    PropertiesState.propertiesMtime = ""
    PropertiesState.propertiesOpen = true
    // NATIVE size (BUG-03): totalSize instead of a `du -shc -- <all the
    // paths>` on a single bash line (ARG_MAX with a huge selection). Sum of
    // apparent bytes of the tree, formatted the same; synchronous, no process nor
    // race (that's why the _propertiesDuOwner guard is no longer needed here).
    var bytes = Backend.FileOperations.totalSize(entries.map(function (e) {
      return Utils.joinPath(NavState.currentPath, e.name)
    }))
    PropertiesState.propertiesSize = Utils.formatSize(bytes)
    PropertiesState.propertiesSizeLoading = false
  }

  function showProperties(entry) {
    if (!entry) return
    PropertiesState.propertiesRequestId += 1
    PropertiesState.propertiesMulti = false
    var path = Utils.joinPath(NavState.currentPath, entry.name)
    PropertiesState.propertiesEntry = entry
    PropertiesState.propertiesSize = entry.type === "dir" ? "" : Utils.formatSize(entry.size)
    PropertiesState.propertiesSizeLoading = entry.type === "dir"
    PropertiesState.propertiesPerms = ""
    PropertiesState.propertiesOwner = ""
    PropertiesState.propertiesMtime = ""
    PropertiesState.propertiesOpen = true
    PropertiesState._propertiesStatOwner = PropertiesState.propertiesRequestId
    propertiesStatProc.start(["stat", "-c", "%A %a\t%U:%G\t%y", "--", path])
    // Deliberately does NOT touch propertiesDuProc if entry is not a folder
    // (the size is already known without a process). A previous "du" of a
    // folder may keep running in that case -- that's why the
    // _propertiesDuOwner guard below is essential, not only for
    // when it IS re-launched.
    if (entry.type === "dir") {
      PropertiesState._propertiesDuOwner = PropertiesState.propertiesRequestId
      propertiesDuProc.start(["du", "-sh", "--", path])
    }
  }

  Backend.ProcessRunner {
    id: propertiesStatProc
    onFinished: function (result) {
      // Discards the response if the user already switched to another item
      // while this "stat" was in flight (see propertiesRequestId).
      if (PropertiesState._propertiesStatOwner !== PropertiesState.propertiesRequestId) return
      var parts = String(result.stdout || "").trim().split("\t")
      PropertiesState.propertiesPerms = parts[0] || ""
      PropertiesState.propertiesOwner = parts[1] || ""
      PropertiesState.propertiesMtime = parts[2] || ""
    }
  }

  Backend.ProcessRunner {
    id: propertiesDuProc
    onFinished: function (result) {
      // Same guard as propertiesStatProc -- this is the one that really
      // matters: a "du" of a large folder can take seconds, and
      // without this its late result would overwrite the size of the item the
      // user is looking at now, even though it no longer has anything to do with
      // the folder that was being measured.
      if (PropertiesState._propertiesDuOwner !== PropertiesState.propertiesRequestId) return
      PropertiesState.propertiesSize = String(result.stdout || "").split("\t")[0] || ""
      PropertiesState.propertiesSizeLoading = false
    }
  }
}

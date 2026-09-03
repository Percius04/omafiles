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
    ChmodState.chmodNames = entries.map(function (e) { return e.name })
    ChmodState.chmodHasDir = entries.some(function (e) { return e.type === "dir" })
    ChmodState.chmodRecursive = false
    // NATIVE octal mode (BUG-03): octalModes instead of a `stat -c%a -- <all
    // the paths>` on a single bash line, which blew ARG_MAX with a huge
    // selection. It returns the mode in the SAME order as the paths ("" if it
    // fails), so the mapping with chmodNames (for undo) stays aligned.
    var modes = Backend.FileOperations.octalModes(entries.map(function (e) {
      return Utils.joinPath(NavState.currentPath, e.name)
    }))
    var valid = modes.filter(function (m) { return m.length > 0 })
    var allSame = valid.length > 0 && valid.every(function (m) { return m === valid[0] })
    ChmodState.chmodMixed = !allSame
    ChmodState.chmodMode = allSame ? valid[0] : ""
    var orig = {}
    for (var i = 0; i < ChmodState.chmodNames.length && i < modes.length; i++)
      if (modes[i].length > 0) orig[ChmodState.chmodNames[i]] = modes[i]
    ChmodState.chmodOriginalModes = orig
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

  // Combined "Properties" dialog: opens the permission (chmod) editor AND
  // the read-only property table together (they share one merged
  // PropertiesDialog). Called in one action from both the context menu and
  // the command palette, replacing the two separately-opened dialogs.
  function showDetailsForSelection() {
    if (ArchiveState.inArchive) return
    var entries = SelectionState.selectedEntries()
    if (entries.length === 0) return
    startChmod(entries)
    showPropertiesForSelection()
  }

  function showProperties(entry) {
    if (!entry) return
    PropertiesState.propertiesRequestId += 1
    PropertiesState.propertiesMulti = false
    var path = Utils.joinPath(NavState.currentPath, entry.name)
    PropertiesState.propertiesEntry = entry
    PropertiesState.propertiesSize = entry.type === "dir" ? "" : Utils.formatSize(entry.size)
    PropertiesState.propertiesSizeLoading = entry.type === "dir"
    PropertiesState.propertiesOpen = true

    // NATIVE stat (BUG-03-style): a single lstat + getpwuid/getgrgid
    // instead of shelling out to `stat`. Synchronous -- same cost class as
    // octalModes()/existingPaths(), which this codebase already calls
    // synchronously elsewhere.
    var info = Backend.FileOperations.statInfo(path)
    PropertiesState.propertiesPerms = info.perms || ""
    PropertiesState.propertiesOwner = info.ownerGroup || ""
    PropertiesState.propertiesMtime = info.mtime || ""

    // Deliberately does NOT touch requestDirSize if entry is not a folder
    // (the size is already known without a native call). A previous dir-size
    // request may still be in flight in that case -- that's why the
    // _propertiesDuOwner guard below is essential, not only for
    // when it IS re-launched.
    if (entry.type === "dir") {
      PropertiesState._propertiesDuOwner = PropertiesState.propertiesRequestId
      Backend.FileOperations.requestDirSize(PropertiesState.propertiesRequestId, path)
    }
  }

  Connections {
    target: Backend.FileOperations
    function onDirSizeReady(requestId, bytes) {
      // Same guard the old propertiesDuProc had: a recursive size walk of a
      // large folder can take real time, and without this its late result
      // would overwrite the size of the item the user is looking at now,
      // even though it no longer has anything to do with the folder that
      // was being measured.
      if (PropertiesState._propertiesDuOwner !== requestId) return
      PropertiesState.propertiesSize = Utils.formatSize(bytes)
      PropertiesState.propertiesSizeLoading = false
    }
  }
}

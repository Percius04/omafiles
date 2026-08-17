import QtQuick
import "../state"
import Omafiles.Backend as Backend
import "../shared/Utils.js" as Utils

// Navigation/history of the active panel -- twenty-second component
// extracted from core. currentPath/tabEntriesCache/entries still
// live in root (state/TabsState.qml already documented that they were "too
// central to move" in an earlier attempt; this time the CONTROLLER is
// moved, not the state itself). refresh/navigateTo/enter/goUp/
// navBack/navForward/startDirWatch/stopDirWatch/openWithDefault/
Item {
  id: navCtrl
  property Item root: null
  property Item list: null
  property Item actionEngine: null
  property Item mountOps: null
  property Item propertiesLoader: null

  // ---------- Directory refresh / watching ----------
  function refresh() {
    // Centralized here so that EVERYTHING that already calls refresh() (hidden
    // toggle, the palette's "Refresh", the onExited of the file
    // actions...) reloads the correct thing without having to remember to
    // check inArchive at every site.
    if (ArchiveState.inArchive) { actionEngine.refreshArchiveListing(); return }
    dirLister.list(NavState.currentPath)
  }

  // Reassigns NavState.entries ONLY if the content actually changed --
  // QML/ListView doesn't compare the content of a model array, only the
  // reference, so reassigning even if the data is identical
  // triggers a full relayout (recreates ALL the rows from scratch).
  // With few rows it's not noticeable, but with the trash (aggregates several
  // disks, may have quite a few more rows, with subtitles that sometimes
  // wrap to two lines) that relayout takes long enough to be
  // seen -- NavState.entries was already set instantly from
  // tabEntriesCache in _goToPath, and this listProc "brings a fresh copy
  // behind the scenes" (see the comment there) which with the trash arrives
  // notably later than with a normal folder, so the double
  // paint (cache -> fresh) stops merging into a single frame and looks
  // like a real jump (reported by josema; my three earlier
  // attempts -- shared trashInfo, scroll race, waiting for
  // trashInfo also in the active panel -- attacked real mechanisms
  // but not THIS one, which is the one that actually caused the jump).
  function _applyEntries(parsed) {
    // GLOBAL search active (2+ characters): NavState.entries are the
    // search RESULTS, not the folder listing. A background
    // listProc -- the one _goToPath launches on switching tabs, or the folder's
    // watcher -- must NOT overwrite them, or restoring a per-tab search would
    // lose it right after restoring it. The live filter (<2 chars) DOES
    // use the listing, so it is only ignored with query >= 2.
    if (NavState.searching && NavState.searchQuery.length >= 2) {
      root.loaded = true
      return
    }
    // Cheap content comparison: before these were another two
    // JSON.stringify of the whole array. entriesEqual is O(n) without
    // allocations.
    var changed = !Utils.entriesEqual(parsed, NavState.entries)
    if (changed) NavState.entries = parsed
    _finishListLoad(changed)
  }

  // See listProc.onFinished -- what remains to be done once
  // NavState.entries is already set. resetView: false
  // when _applyEntries() decided the content hadn't really changed
  // -- in that case list.contentY was already fine (nobody touched it) and
  // the reset+scroll-restoration below is not needed.
  function _finishListLoad(resetView) {
    if (resetView) {
      // The array above is a new object, not a mutation of the
      // previous one -- QML/Qt doesn't always re-anchor the internal origin of
      // ListView (originY) well when replacing the whole model like this, especially
      // if the previous list was shorter. `list.contentY = 0` (set
      // BEFORE launching this process, in toggleHidden/navigateTo/etc) doesn't
      // suffice because it runs against the OLD model -- this is what
      // really leaves the gap at the very top. positionViewAtBeginning()
      // is QML's correct way to reset origin+contentY together,
      // right when the new model is already set.
      list.positionViewAtBeginning()
      // TabOps._restoreTabScroll() sets list.contentY to the saved
      // position right AFTER requesting the navigation -- but that same
      // navigation is what triggers this asynchronous listProc, which always
      // ends up resetting it with the positionViewAtBeginning() above. If
      // this Process takes longer than that synchronous restoration (the trash,
      // which aggregates several disks, takes notably longer than a normal
      // folder), it wins the race the other way. root._pendingScrollY is the
      // way for whoever requested the restoration to survive this reset,
      // being applied IN the same tick as positionViewAtBeginning instead of
      // before.
      if (root._pendingScrollIndex >= 0) {
        list.positionAtIndexWithOffset(root._pendingScrollIndex, root._pendingScrollOffset)
      } else if (root._pendingScrollY >= 0) {
        list.contentY = root._pendingScrollY
      }
    }
    root._pendingScrollY = -1
    root._pendingScrollIndex = -1
    root._pendingScrollOffset = 0
    root.loaded = true
    var selectNames = NavState.pendingSelectNames
    var fileManagerAction = NavState.pendingFileManagerAction
    NavState.pendingSelectNames = []
    NavState.pendingFileManagerAction = ""
    var foundIndices = []
    if (selectNames.length > 0) {
      for (var i = 0; i < NavState.visibleEntries.length; i++) {
        if (selectNames.indexOf(NavState.visibleEntries[i].name) >= 0) foundIndices.push(i)
      }
    }
    if (foundIndices.length > 0) {
      // selectOnly() already covered the case of 1 (the usual one: file
      // bookmark, recent, most real ShowItems). Several at
      // once (ShowItems with real multi-selection in the caller, see
      // dbus-filemanager1.py) had no way to be applied before -- they were
      // all highlighted, with the first as "main".
      SelectionState.selectedIndex = foundIndices[0]
      SelectionState.anchorIndex = foundIndices[0]
      SelectionState.selectedIndices = foundIndices
      if (PreviewState.previewOpen && foundIndices.length > 1) PreviewState.previewOpen = false
      if (fileManagerAction === "show-properties" && propertiesLoader)
        propertiesLoader.showPropertiesForSelection()
    } else if (SelectionState.selectedIndex >= NavState.visibleEntries.length) {
      SelectionState.selectedIndex = NavState.visibleEntries.length - 1
    }
  }

  // Live refresh of the ACTIVE panel: starts native QFileSystemWatcher via DirLister.
  function startDirWatch(path) {
    dirLister.watch(path)
  }

  function stopDirWatch() {
    dirLister.unwatch()
  }

  // ---------- Navigation / history ----------
  function navigateTo(path) {
    if (!path) return
    // Normalizes basic trailing/double slashes without depending on an external process.
    path = path.replace(/\/+$/, "") || "/"
    _pushHistory(path)
    _goToPath(path)
  }

  // The real navigation (used by navigateTo AND by back/forward/tab
  // switch, which already decide the correct history entry themselves and
  // don't want it touched again).
  function _goToPath(path) {
    // Any real navigation (bookmark, back/forward, tab
    // switch, editing the path by hand...) exits the "inside an
    // archive" mode -- currentPath never changes while browsing INSIDE
    // the archive (see enter()/goUp()/inArchive), so if this
    // runs it means the user went somewhere else for real.
    if (ArchiveState.inArchive) { ArchiveState.inArchive = false; ArchiveState.archivePath = ""; ArchiveState.archiveSubPath = "" }
    NavState.currentPath = path
    SelectionState.selectOnly(-1)
    EditModeState.renamingIndex = -1
    EditModeState.creatingFolder = false
    EditModeState.creatingFile = false
    EditModeState.editingPath = false
    // list.contentY never corrects itself: if you were scrolled down
    // in the previous folder, that scroll position stays fixed even though
    // the new listing has nothing there -- it looks like an empty gap
    // at the very top instead of the first rows.
    list.contentY = list.originY
    // If this path was already loaded in a background panel (typical when
    // switching tabs by moving the cursor over it), it is painted with that data
    // instantly instead of waiting for listProc to start -- without this a
    // flicker with the previous tab's listing was seen during those
    // milliseconds. refresh() brings a fresh copy behind
    // the scenes soon anyway, replacing it unnoticed.
    if (root.tabEntriesCache[path]) NavState.entries = root.tabEntriesCache[path]
    refresh()
    startDirWatch(path)
  }

  function _pushHistory(path) {
    if (TabsState.navHistory[TabsState.navHistoryIndex] === path) return
    // Truncates any "forward" before adding -- same behavior
    // as any browser's history.
    var h = TabsState.navHistory.slice(0, TabsState.navHistoryIndex + 1)
    h.push(path)
    TabsState.navHistory = h
    TabsState.navHistoryIndex = h.length - 1
  }

  function navBack() {
    if (TabsState.navHistoryIndex <= 0) return
    TabsState.navHistoryIndex -= 1
    _goToPath(TabsState.navHistory[TabsState.navHistoryIndex])
  }

  function navForward() {
    if (TabsState.navHistoryIndex >= TabsState.navHistory.length - 1) return
    TabsState.navHistoryIndex += 1
    _goToPath(TabsState.navHistory[TabsState.navHistoryIndex])
  }

  // Used by BackgroundPanel (double click on a file in a background
      // Detached (real execDetached, without stdout/stderr pipes nor
  // tracking) + gtk-launch, NOT xdg-open nor gio open -- third real
  // attempt in the same session until finding something
  // reliable:
  //  1. xdg-open (Detached): under Hyprland (XDG_CURRENT_DESKTOP=Hyprland,
  //     not recognized as gnome/kde/...) it falls into its "generic" branch, which
  //     executes the .desktop's Exec= by hand IGNORING Terminal=true --
  //     for apps like nvim.desktop that launches nvim without a terminal or TTY,
  //     hung forever without anything being shown.
  //  2. gio open (ProcessRunner, with or without a "bash -c" in between, with or
  //     without setsid): it does respect Terminal=true in manual tests from
  // from an external process.
  //     terminal it opens internally for Terminal=true didn't survive
  //     reliably (sometimes yes, most times no) -- the exact
  //     cause wasn't found, but the usual pattern: ProcessRunner
  //     with StdioCollector is not to be trusted to launch something that in turn
  //     forks a long-running app.
  //  3. gtk-launch via Detached (this one): same mechanism ALREADY verified
  //     reliable in OpenWithOps.launchWith() ("Open with..."), which does
  //     respect Terminal=true. It only remains to first resolve the id of the
  //     default .desktop (gtk-launch needs an id, not a path).
  function openWithDefault(path) {
    Backend.Detached.run(["bash", "-c", 'id=$(xdg-mime query default "$(xdg-mime query filetype "$1")"); [ -n "$id" ] && exec gtk-launch "$id" "$1"', "_", path])
  }

  function enter(entry) {
    if (!entry) return
    // GLOBAL search result (SearchBackend): the entry carries an absolute
    // `path` of any OTHER folder. "Open" here means REVEAL, like
    // in Nautilus/Spotlight: a folder -> enter it; a file -> go to
    // its folder leaving it selected (not launch it blindly from a list
    // that mixes disparate locations). In both cases we exit the searcher.
    if (entry.path) {
      NavState.searching = false
      NavState.searchQuery = ""
      NavState.searchTruncated = false
      if (entry.type === "dir") {
        navigateTo(entry.path)
      } else {
        NavState.pendingSelectNames = [entry.name]
        navigateTo(entry.parent)
      }
      return
    }
    if (ArchiveState.inArchive) {
      if (entry.type === "dir") {
        ArchiveState.archiveSubPath = ArchiveState.archiveSubPath ? ArchiveState.archiveSubPath + "/" + entry.name : entry.name
        actionEngine.refreshArchiveListing()
      } else {
        actionEngine.openFileInArchive(entry)
      }
      return
    }
    if (entry.type === "dir") {
      navigateTo(Utils.joinPath(NavState.currentPath, entry.name))
    } else if (actionEngine.isArchive(entry)) {
      actionEngine.enterArchive(Utils.joinPath(NavState.currentPath, entry.name))
    } else if (actionEngine.isIso(entry)) {
      mountOps.mountIso(entry)
    } else {
      var openPath = Utils.joinPath(NavState.currentPath, entry.name)
      if (PickerState.active) {
        navCtrl.root.pickerSubmitRequested()
      } else {
        openWithDefault(openPath)
        BookmarksState.addRecent(openPath, entry.name)
      }
    }
  }

  function goUp() {
    if (ArchiveState.inArchive) {
      if (ArchiveState.archiveSubPath === "") { actionEngine.exitArchive(); return }
      var slash = ArchiveState.archiveSubPath.lastIndexOf("/")
      ArchiveState.archiveSubPath = slash > 0 ? ArchiveState.archiveSubPath.substring(0, slash) : ""
      actionEngine.refreshArchiveListing()
      return
    }
    if (NavState.currentPath === "/") return
    var idx = NavState.currentPath.lastIndexOf("/")
    navigateTo(idx > 0 ? NavState.currentPath.substring(0, idx) : "/")
  }

  Timer {
    id: dirWatchDebounce
    // Several events almost back to back (copying/moving/deleting several files
    // at once) collapse into a single refresh instead of one per event.
    interval: 400
    // Don't refresh while there is a name half-written -- a
    // refresh in the middle of a rename could reorder the list and leave
    // renamingIndex pointing to the wrong row.
    onTriggered: if (!root.hasPendingEdit) refresh()
  }

  // Owner of the directory listing model -- see logic/DirLister.qml. There is
  // only ONE instance here (the active panel only lists one path at a
  // time); each BackgroundPanel has its own.
  DirLister {
    id: dirLister
    trashDir: Paths.trashDir
    showHidden: NavState.showHidden
    onPathErrorChanged: NavState.currentPathError = dirLister.pathError
    onListed: _applyEntries(dirLister.entries)
    // Native watching: the model's QFileSystemWatcher signals a change -> debounced refresh.
    onDirectoryChanged: dirWatchDebounce.restart()
  }
}

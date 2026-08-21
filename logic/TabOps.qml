import QtQuick
import "../state"

// Tab/panel lifecycle: create, close, switch active,
// navigate/undo-history of a tab that is NOT the active one --
// twenty-fourth component extracted from core. `_goToPath()` (the
// navigation of the ACTIVE tab itself) stays in root -- it's the core
// of the real navigation, too central to move, and these functions
// already call it as `navController._goToPath(...)` without any problem.
Item {
  property Item root: null
  property Item navController: null

  // The main ListView (id "list" in core) -- save/restore
  // scroll when switching tabs.
  property Item list: null
  property Item archiveBrowser: null
  property Item previewLoader: null

  // Navigate WITHIN a panel that is not the active one -- it doesn't touch
  // NavState.currentPath/NavState.entries (those belong only to the active panel), only the
  // tab's own object. It keeps its history just like
  // navigateTo keeps that of the active tab.
  function navigateTabTo(index, path) {
    if (!path || index < 0 || index >= TabsState.tabs.length) return
    path = path.replace(/\/+$/, "") || "/"
    if (index === TabsState.activeTabIndex) { navController.navigateTo(path); return }
    var next = TabsState.tabs.slice()
    var tab = next[index]
    if (path === tab.path) return
    var h = (tab.history || [tab.path]).slice(0, (tab.historyIndex !== undefined ? tab.historyIndex : 0) + 1)
    h.push(path)
    // Object.assign, NOT a fresh object: rebuilding the tab from scratch
    // silently dropped every other saved field (scroll, search, preview,
    // archive state...) the moment a background panel navigated.
    next[index] = Object.assign({}, tab, { path: path, history: h, historyIndex: h.length - 1 })
    TabsState.tabs = next
  }

  // Back/forward for a panel that is not the active one -- same concept as
  // navBack/navForward, but reading/writing the history saved in
  // that particular tab object instead of TabsState.navHistory (which is
  // only the active one's).
  function navTabBack(index) {
    if (index === TabsState.activeTabIndex) { navController.navBack(); return }
    if (index < 0 || index >= TabsState.tabs.length) return
    var tab = TabsState.tabs[index]
    var hIdx = tab.historyIndex !== undefined ? tab.historyIndex : 0
    if (hIdx <= 0) return
    var hist = tab.history || [tab.path]
    var next = TabsState.tabs.slice()
    next[index] = Object.assign({}, tab, { path: hist[hIdx - 1], history: hist, historyIndex: hIdx - 1 })
    TabsState.tabs = next
  }

  function navTabForward(index) {
    if (index === TabsState.activeTabIndex) { navController.navForward(); return }
    if (index < 0 || index >= TabsState.tabs.length) return
    var tab = TabsState.tabs[index]
    var hist = tab.history || [tab.path]
    var hIdx = tab.historyIndex !== undefined ? tab.historyIndex : 0
    if (hIdx >= hist.length - 1) return
    var next = TabsState.tabs.slice()
    next[index] = Object.assign({}, tab, { path: hist[hIdx + 1], history: hist, historyIndex: hIdx + 1 })
    TabsState.tabs = next
  }

  function saveActiveTab() {
    var next = TabsState.tabs.slice()
    next[TabsState.activeTabIndex] = {
      path: NavState.currentPath, history: TabsState.navHistory, historyIndex: TabsState.navHistoryIndex,
      previewOpen: PreviewState.previewOpen, previewEntry: PreviewContentState.previewEntry, scrollY: list.contentY,
      inArchive: ArchiveState.inArchive, archivePath: ArchiveState.archivePath, archiveSubPath: ArchiveState.archiveSubPath,
      // Index of the first visible row (besides the scrollY in pixels): the
      // background panel restores it with positionViewAtIndex, which is IMMUNE to the
      // ListView's contentHeight being computed lazily (by pixel, the
      // background scroll ended up clamped/shifted relative to the active one).
      scrollIndex: list.firstVisibleIndex(),
      scrollOffset: list.firstVisibleOffset(),
      // The folder content RAW (what the active panel sees now). The
      // background panel adopts it SYNCHRONOUSLY when moving to the background, so its list
      // is not empty nor populated async -> positionViewAtIndex hits the mark
      // instantly and the scroll stays frozen with no jump. It is a reference to the
      // array, cheap. (With search open, the background panel uses searchEntries,
      // not this.)
      entries: NavState.entries,
      // The search (magnifier) belongs to the active panel, not global: without saving it here
      // it "leaked" to the tab you switched to (searching/searchQuery live
      // in NavState, singleton). The RESULTS are saved too, to
      // restore them instantly without re-launching the search. See _restoreTabSearch.
      searching: NavState.searching, searchQuery: NavState.searchQuery,
      searchTruncated: NavState.searchTruncated,
      searchEntries: NavState.searching ? NavState.entries : undefined
    }
    TabsState.tabs = next
  }

  // Restores `tab`'s own back/forward history as the "current" one
  // -- used by switchToTab/closeTab when landing on a tab that is not
  // the one just created (that one already carries its own history from scratch).
  function _restoreTabHistory(tab) {
    TabsState.navHistory = tab.history || [tab.path]
    TabsState.navHistoryIndex = tab.historyIndex !== undefined ? tab.historyIndex : 0
  }

  // The preview (photo/video/text) belongs to the active panel, and _goToPath
  // always closes it (selectOnly(-1) on navigating) -- without this, switching
  // tabs looked as if the preview was lost even though the original tab
  // still had it open. It is called AFTER _goToPath,
  // which already left currentPath ready so loadPreview reads the
  // correct file if it is text.
  // Real bug: navigating WITHIN an archive (inArchive/archivePath/
  // archiveSubPath) was not part of the state saved per tab -- when
  // switching tabs with the mouse and coming back, _goToPath() had already
  // exited the archive mode without anything restoring it, so the
  // tab landed on the real folder containing the .zip instead of
  // on the inner path where it was browsing. Called AFTER
  // _goToPath (which is the one that clears inArchive), same pattern as
  // _restoreTabPreview/_restoreTabScroll.
  function _restoreTabArchive(tab) {
    if (tab.inArchive && tab.archivePath) {
      archiveBrowser.restore(tab.archivePath, tab.archiveSubPath)
    }
  }

  function _restoreTabPreview(tab) {
    if (tab.previewOpen && tab.previewEntry) {
      previewLoader.loadPreview(tab.previewEntry)
    } else {
      PreviewState.previewOpen = false
    }
  }

  // _goToPath() always leaves list.contentY = list.originY (all the way
  // up) on navigating -- without this, returning to a tab where you had
  // scrolled down the list always landed on row 0, losing the
  // position even though the folder itself hadn't changed. It is called
  // AFTER _goToPath, same reason as _restoreTabPreview: by
  // then the model (NavState.visibleEntries) is already updated and
  // contentHeight already reflects the correct listing.
  // This is only the IMMEDIATE restoration (while the listProc that
  // _goToPath just launched is still running) -- root._pendingScrollY
  // keeps the same position so listProc reapplies it
  // itself right after its own positionViewAtBeginning() when it
  // finishes, which would otherwise overwrite it (see the long comment there, it was the
  // real origin of the flicker when switching from background panel to active with
  // the trash).
  function _restoreTabScroll(tab) {
    // By INDEX (positionViewAtIndex), like the background panel, so the
    // position matches EXACTLY when going and coming back (mixing pixel/index
    // drifted ~1 row per round trip). _pendingScrollIndex reapplies it after
    // _goToPath's async listProc (which resets with positionViewAtBeginning).
    if (tab.scrollIndex !== undefined && tab.scrollIndex >= 0) {
      list.positionAtIndexWithOffset(tab.scrollIndex, tab.scrollOffset || 0)
      root._pendingScrollIndex = tab.scrollIndex
      root._pendingScrollOffset = tab.scrollOffset || 0
      root._pendingScrollY = -1
    } else {
      var y = tab.scrollY || list.originY
      list.contentY = y
      root._pendingScrollY = y
      root._pendingScrollIndex = -1
    }
  }

  // Restores (or clears) `tab`'s own search mode. It is called AFTER
  // _goToPath, which already repopulated NavState.entries with the folder's normal
  // listing -- if this tab was searching, we give it back its
  // saved results on top. If it was NOT searching, the global flag must be
  // turned off anyway: the tab we left could be in search mode and that
  // state, being NavState (singleton), would have stayed active here. Same
  // pattern as _restoreTabArchive/_restoreTabPreview.
  function _restoreTabSearch(tab) {
    if (tab.searching) {
      NavState.searching = true
      NavState.searchQuery = tab.searchQuery || ""
      NavState.searchTruncated = tab.searchTruncated || false
      if (tab.searchEntries !== undefined) NavState.entries = tab.searchEntries
    } else {
      NavState.searching = false
      NavState.searchQuery = ""
      NavState.searchTruncated = false
    }
  }

  function switchToTab(index) {
    if (index < 0 || index >= TabsState.tabs.length || index === TabsState.activeTabIndex) return
    if (root.hasBlockingOverlay) return
    // The magnifier must NOT animate its expand/collapse due to a tab change: when
    // adopting the search state of the new tab, `searching` changes and the
    // bar would do the minimize/expand animation on the tab you arrive at
    // (it looks bad). It is suppressed during the whole switch; snap instead of animation.
    NavState.suppressSearchAnim = true
    saveActiveTab()
    TabsState.activeTabIndex = index
    _restoreTabHistory(TabsState.tabs[index])
    // The active panel adopts the listing of the tab that was already in
    // view as a background panel -- without fade (see root.suppressListFade), or
    // moving the cursor over a panel would produce a redundant flicker. It is
    // cleared right after: the only model change that triggers the fade is
    // done by _goToPath synchronously (it paints from tabEntriesCache), so
    // by the time it returns it was already consumed.
    root.suppressListFade = true
    navController._goToPath(TabsState.tabs[index].path)
    root.suppressListFade = false
    _restoreTabArchive(TabsState.tabs[index])
    _restoreTabPreview(TabsState.tabs[index])
    _restoreTabSearch(TabsState.tabs[index])
    _restoreTabScroll(TabsState.tabs[index])
    NavState.suppressSearchAnim = false
  }

  function newTab() {
    saveActiveTab()
    TabsState.tabs = TabsState.tabs.concat([{ path: NavState.currentPath, history: [NavState.currentPath], historyIndex: 0 }])
    TabsState.activeTabIndex = TabsState.tabs.length - 1
    TabsState.navHistory = [NavState.currentPath]
    TabsState.navHistoryIndex = 0
  }

  // For whoever doesn't use Ctrl+T -- a new tab already pointing to `path` (a
  // folder row, a bookmark, a drive), not the current folder.
  function openInNewTab(path) {
    if (!path) return
    saveActiveTab()
    TabsState.tabs = TabsState.tabs.concat([{ path: path, history: [path], historyIndex: 0 }])
    TabsState.activeTabIndex = TabsState.tabs.length - 1
    TabsState.navHistory = [path]
    TabsState.navHistoryIndex = 0
    navController._goToPath(path)
  }

  function closeTab() {
    if (TabsState.tabs.length <= 1) { root.requestClose(); return }
    NavState.suppressSearchAnim = true
    var next = TabsState.tabs.slice()
    next.splice(TabsState.activeTabIndex, 1)
    TabsState.tabs = next
    var newIndex = Math.min(TabsState.activeTabIndex, next.length - 1)
    TabsState.activeTabIndex = newIndex
    _restoreTabHistory(TabsState.tabs[newIndex])
    // Same as switchToTab: the remaining tab was already in view as a
    // background panel, so it is adopted without fade (avoids the flicker).
    root.suppressListFade = true
    navController._goToPath(TabsState.tabs[newIndex].path)
    root.suppressListFade = false
    _restoreTabArchive(TabsState.tabs[newIndex])
    _restoreTabPreview(TabsState.tabs[newIndex])
    _restoreTabSearch(TabsState.tabs[newIndex])
    _restoreTabScroll(TabsState.tabs[newIndex])
    NavState.suppressSearchAnim = false
  }

  function nextTab() {
    switchToTab((TabsState.activeTabIndex + 1) % TabsState.tabs.length)
  }
}

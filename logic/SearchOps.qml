import QtQuick
import "../state"

// Search (live filter + deep search in subfolders), hidden files,
// edit path by hand, go all the way up/down -- twentieth component
// extracted from core.
Item {
  property Item root: null
  property bool _published: false
  property bool _bound: false
  property int _originTab: -1
  property string _originRoot: ""
  property string _originQuery: ""

  function cancelSearch() {
    if (!_bound) return
    _bound = false
    searchBackend.cancel()
    NavState.searchBusy = false
  }

  function _matchesOrigin() {
    return _bound && NavState.searching && TabsState.activeTabIndex === _originTab
        && NavState.currentPath === _originRoot && NavState.searchQuery === _originQuery
  }

  // Invalidate at the transition, not just by equality at delivery: navigating
  // away and back to an identical root/query must not resurrect an old search.
  Connections {
    target: NavState
    function onCurrentPathChanged() { cancelSearch() }
    function onSearchQueryChanged() { cancelSearch() }
    function onSearchingChanged() { cancelSearch() }
    function onShowHiddenChanged() { cancelSearch() }
    function onNavigationStarted() { cancelSearch() }
  }
  Connections {
    target: TabsState
    function onActiveTabIndexChanged() { cancelSearch() }
  }
  property Item navController: null

  // The main ListView (id "list" in core) -- these actions
  // reset its scroll just like refresh()/navigateTo() with a normal
  // folder.
  property Item list: null

  function toggleHidden() {
    NavState.showHidden = !NavState.showHidden
    list.setContentY(list.originY)
    navController.refresh()
    NavState.refreshTick += 1
  }

  function startEditPath() {
    EditModeState.editingPath = true
  }

  function startSearch() {
    if (ArchiveState.inArchive) return
    EditModeState.creatingFolder = false
    EditModeState.creatingFile = false
    NavState.searching = true
    NavState.searchQuery = ""
    NavState.searchTruncated = false
    list.setContentY(list.originY)
  }

  function exitSearch() {
    cancelSearch()
    NavState.searching = false
    NavState.searchQuery = ""
    NavState.searchTruncated = false
    list.setContentY(list.originY)
    navController.refresh()
    SelectionState.selectOnly(-1)
  }

  function runDeepSearch() {
    // Phase 19: incremental search only starts with 2+ characters; with
    // 0-1 the searcher shows the normal listing (see restoreListing, called
    // by the SearchBar debounce).
    if (NavState.searchQuery.length < 2) return
    cancelSearch()
    _originTab = TabsState.activeTabIndex
    _originRoot = NavState.currentPath
    _originQuery = NavState.searchQuery
    _bound = true
    _published = false
    NavState.searchBusy = true
    list.setContentY(list.originY)
    // Hybrid search: live current-folder matches plus the global index.
    // Either may publish first; snapshots are merged, scoped and deduplicated.
    // A new query invalidates both sources without blocking the UI.
    searchBackend.search(NavState.searchQuery, NavState.showHidden, NavState.currentPath)
  }

  // Returns to the normal listing of currentPath without closing the searcher:
  // called by the SearchBar debounce when the query drops below 2 characters.
  function restoreListing() {
    cancelSearch()
    NavState.searchBusy = false
    NavState.searchTruncated = false
    list.setContentY(list.originY)
    navController.refresh()
  }

  function goTop() {
    if (NavState.visibleEntries.length === 0) return
    SelectionState.selectOnly(0)
    list.positionViewAtBeginning()
  }

  function goBottom() {
    if (NavState.visibleEntries.length === 0) return
    var last = NavState.visibleEntries.length - 1
    SelectionState.selectOnly(last)
    list.positionViewAtIndex(last, ListView.Contain)
  }

  // SearchBackend trims to 200 and marks truncated=true if there were more --
  // same contract SearchWorker/the script gave; the incomplete-list notice is
  // painted by the status bar. The entries ALREADY come sorted by relevance
  // (they are not passed through sortOps: that would break that order).
  SearchBackend {
    id: searchBackend
    indexScript: Paths.resourceDir + "/scripts/runtime/search-index.sh"
    onResults: function (entries, truncated, complete) {
      if (!_matchesOrigin()) return
      NavState.searchBusy = !complete
      NavState.searchTruncated = truncated
      // Result ranks can change as either source arrives. Capture identity, not
      // indices: Enter must never target a different file after a late snapshot.
      var old = NavState.visibleEntries
      var selected = SelectionState.selectedIndices.map(function(i) { return old[i] ? old[i].path : "" })
      var primary = old[SelectionState.selectedIndex] ? old[SelectionState.selectedIndex].path : ""
      var anchor = old[SelectionState.anchorIndex] ? old[SelectionState.anchorIndex].path : ""
      var scrollY = list.contentY
      NavState.entries = entries
      if (!_published) {
        // Empty progress must not consume initial selection; once selected,
        // later snapshots preserve even deliberate deselection.
        _published = NavState.visibleEntries.length > 0
        list.positionViewAtBeginning()
        SelectionState.selectOnly(NavState.visibleEntries.length > 0 ? 0 : -1)
      } else {
        var paths = NavState.visibleEntries.map(function(e) { return e.path })
        SelectionState.selectedIndices = selected.map(function(p) { return paths.indexOf(p) }).filter(function(i) { return i >= 0 })
        SelectionState.selectedIndex = primary ? paths.indexOf(primary) : -1
        SelectionState.anchorIndex = anchor ? paths.indexOf(anchor) : -1
        list.setContentY(scrollY)
      }
    }
  }
}

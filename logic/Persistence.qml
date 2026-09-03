import QtQuick
import "../state"
import Omafiles.Backend as Backend

// On-disk persistence -- sixteenth component extracted from core, and the
// first that takes a group of Process out of the main file. Owns the
// initial load() for each JSON file (bookmarks, recents, tab session,
// bulk-rename history, network profiles) plus saveBookmarks()/saveSession()
// (the two cases that need a full-array/object rewrite from outside a
// single mutator). Recents/bulk-rename-history/network-profiles no longer
// route their SAVES through here (cleanup pass, corrected comment): their
// add/remove mutators live directly on state/BookmarksState.qml and write
// to Backend.JsonStore themselves for atomicity with the in-memory update
// -- this file used to also expose saveRecent()/saveBulkRenameHistory()
// wrappers for that, but nothing called them once BookmarksState.qml took
// over (removed, see git history if the old shape is ever needed again).
//
// Phase 6.A (josema): the I/O no longer launches shell processes. Previously each
// read was a `cat` (ProcessRunner→QProcess) and each write a
// `bash -c 'mkdir -p ... && printf > ...'` (Detached); now everything goes
// through Omafiles.Services.JsonStore, a thin adapter over the C++ backend
// (QFile/QSaveFile/QJsonDocument). The parsing is in C++, the write is
// atomic and there are no forks. The observable contract is the same: read() is still
// async (loaded arrives on the next cycle). loadSession() was removed with
// the always-single-"$HOME"-panel startup, so the session restore branch no
// longer exists either.
Item {
  property Item root: null

  property Item tabOps: null

  // Fire-and-forget write of a JSON to disk -- JsonStore.write creates the
  // folder ~/.local/state/omafiles/ if needed and writes
  // atomically. None of the 4 calls below needs to know when
  // it finishes, so the return value and the saved signal are ignored.
  function _saveJson(path, data) {
    Backend.JsonStore.write(path, data)
  }

  function loadBookmarks() {
    Backend.JsonStore.read(Paths.bookmarksFile)
  }

  function saveBookmarks() {
    _saveJson(Paths.bookmarksFile, BookmarksState.bookmarks)
  }

  function loadRecent() {
    Backend.JsonStore.read(Paths.recentFile)
  }

  // Only saves the path of each tab -- not history/preview/scroll,
  // that is "hot" session (it already survives close/reopen without leaving
  // session persistence across restarts.
  // restoring it after a real restart of the shell.
  // Written for compatibility only -- startup never restores it (a plain
  // launch always opens a single "$HOME" panel, see OmafilesContent.open()).
  function saveSession() {
    tabOps.saveActiveTab()
    var snapshot = TabsState.tabs.map(function (t) { return { path: t.path } })
    _saveJson(Paths.sessionFile, { tabs: snapshot, activeTabIndex: TabsState.activeTabIndex })
  }

  function loadBulkRenameHistory() {
    Backend.JsonStore.read(Paths.bulkRenameHistoryFile)
  }

  function loadNetworkProfiles() {
    Backend.JsonStore.read(Paths.networkProfilesFile)
  }

  function loadUiPrefs() {
    Backend.JsonStore.read(Paths.uiPrefsFile)
  }

  function saveUiPrefs() {
    _saveJson(Paths.uiPrefsFile, { viewMode: ViewState.mode, cellWidth: ViewState.cellWidth })
  }

  // A single delivery point for the four reads: JsonStore is a
  // singleton, so loaded() is dispatched by `path`. `data` already comes
  // parsed from C++ (JS object/array) or undefined if the file does not
  // exist or the JSON was invalid -- it is normalized to null to keep the
  // same "valid or default value" logic that the four
  // separate ProcessRunner had.
  Connections {
    target: Backend.JsonStore

    function onLoaded(path, data, ok) {
      var parsed = ok ? data : null

      if (path === Paths.bookmarksFile) {
        BookmarksState.bookmarksLoaded = true
        if (Array.isArray(parsed) && parsed.length > 0) {
          BookmarksState.bookmarks = parsed
        } else {
          BookmarksState.bookmarks = Paths.defaultBookmarks
          saveBookmarks()
        }
      } else if (path === Paths.recentFile) {
        BookmarksState.recentLoaded = true
        BookmarksState.recentFiles = Array.isArray(parsed) ? parsed : []
      } else if (path === Paths.bulkRenameHistoryFile) {
        BookmarksState.bulkRenameHistoryLoaded = true
        BookmarksState.bulkRenameHistory = Array.isArray(parsed) ? parsed : []
      } else if (path === Paths.networkProfilesFile) {
        BookmarksState.networkProfilesLoaded = true
        BookmarksState.networkProfiles = Array.isArray(parsed) ? parsed : []
      } else if (path === Paths.uiPrefsFile) {
        if (parsed && (parsed.viewMode === "grid" || parsed.viewMode === "list"))
          ViewState.mode = parsed.viewMode
        if (parsed && typeof parsed.cellWidth === "number") ViewState.setCellWidth(parsed.cellWidth)
        ViewState.loaded = true
      }
    }
  }

  // Saves any time the mode or cell size changes after the restored value
  // has been delivered (the `loaded` guard keeps ViewState's own defaults
  // from overwriting ui-prefs.json before loadUiPrefs()'s async read
  // arrives). Centralized here rather than at each call site (keyboard
  // shortcut / command palette / nav-bar button / Ctrl+scroll) so those
  // all stay plain ViewState.toggleMode()/setCellWidth() one-liners.
  Connections {
    target: ViewState
    function onModeChanged() { if (ViewState.loaded) saveUiPrefs() }
    // Debounced (unlike mode, a rare toggle): Ctrl+scroll can fire this
    // many times a second while the user is actively resizing, and each
    // save is a synchronous disk write.
    function onCellWidthChanged() { if (ViewState.loaded) _cellWidthSaveDebounce.restart() }
  }

  Timer {
    id: _cellWidthSaveDebounce
    interval: 400
    onTriggered: saveUiPrefs()
  }
}

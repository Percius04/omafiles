import QtQuick
import qs.Commons
import qs.Ui
import "../dialogs"
import "../panels"
import "../logic"
import "../shared"
import "../state"

// OmafilesContent -- the complete visual tree + all the wiring of
// Omafiles (Phase 3, josema: separate the composition root from the
// Quickshell frontend). It contains EVERYTHING that used to live directly in Omafiles.qml
// except the host-specific bits: no FloatingWindow, no HostBridge, no
// the `shell` property. Omafiles.qml (now a thin bootstrap of the
// Quickshell frontend) instantiates this inside a HostBridge and connects
// open()/close()/opened/closeRequested() from outside -- see that file
// for the Quickshell side of the contract.
Item {
  id: root

  // homeDir/pluginDir/trashDir/thumbCacheDir, the state *.json and
  // defaultBookmarks now live in state/Paths.qml (Phase 14.B): paths and
  // configuration derived from $HOME, not composition-root state.
  // currentPath/entries/showHidden/searchQuery/visibleEntries live in
  // state/NavState.qml (Phase 11.A) and NavState is their SOLE source of truth
  // (Phase 14.A). The runtime nav/search state (searching/searchTruncated/
  // currentPathError/pendingSelectNames/refreshTick) was also moved to
  // NavState (Phase 14.C). tabs/activeTabIndex/navHistory/
  // navHistoryIndex live in state/TabsState.qml.
  // Cache of listings by path, fed by the background panels every
  // time they refresh -- see _goToPath(). It stays here (view cache, not
  // structural data; its unification is separate work).
  property var tabEntriesCache: ({})
  property bool opened: false
  property bool loaded: false

  // Suppresses the list's fade micro-transition (Phase 22) for the
  // NEXT repaint of the active panel. TabOps activates it on switching/closing
  // a tab: there the listing the active panel adopts was already in view
  // (it was a background panel), so fading it in when activated is a
  // redundant flash on hover. Real navigation (entering a folder,
  // back/forward, operations) does NOT activate it, so it keeps its fade.
  property bool suppressListFade: false

  // Scroll position pending restoration AS SOON AS the
  // next listProc finishes -- see the long comment next to
  // positionViewAtBeginning() in listProc, which consumes it. -1 = nothing
  // pending (sentinel, since 0 is a valid scroll position in
  // itself). Purely view state: it stays in the composition root.
  property real _pendingScrollY: -1
  // Same as _pendingScrollY but by INDEX (positionViewAtIndex): the active
  // panel restores scroll by index, not by pixel, so it matches
  // EXACTLY the background panel (which also uses index). If they mixed
  // pixel/index, the conversion between them drifted ~1 row per round trip.
  property int _pendingScrollIndex: -1
  // Sub-row offset accompanying _pendingScrollIndex (pixels within the
  // top row), to reproduce the EXACT scroll, not row-aligned.
  property real _pendingScrollOffset: 0

  // undoStack/redoStack now live in state/UndoState.qml (singleton) --
  // third slice of the state/ layer. Logic unchanged in
  // logic/ActionEngine.qml.

  // undoLast/redoLast remain as thin wrappers because the visual layer
  // (menus/palette) calls them via the root facade. pushUndo no longer: its
  // logic/ callers receive actionEngine injected (Phase 14.D).
  function undoLast() {
    registry.actionEngine.undoLast()
  }

  function redoLast() {
    registry.actionEngine.redoLast()
  }

  // selectedIndex/selectedIndices/anchorIndex/marquee* now live in
  // state/SelectionState.qml (singleton, pragma Singleton) -- first
  // pilot of the state/ layer (see [[project_omafiles_architecture_rules]]),
  // instead of loose properties here passed by prop-drilling. The logic
  // that manipulates them stays in logic/SelectionOps.qml unchanged.
  // Real measured height of a row (all equal, see updateMarqueeSelection).
  // Used to compute the footer height without going through
  // list.contentHeight -- which in this version of Qt includes the footer
  // itself, and using it there would be a property that depends on itself
  // (confirmed live: "Binding loop detected for property height").
  property real measuredRowHeight: 0

  // sortKey/sortDesc + sortKeys/sortKeyLabels now live in
  // state/SortState.qml (these last two moved in Phase 14.B, closes O3);
  // completes logic/SortOps.qml.

  // renamingIndex/creatingFolder/creatingFile/editingPath now live in
  // state/EditModeState.qml -- eighteenth slice of the state/ layer.
  // There is an unconfirmed edit in the active panel (name half-
  // written) -- used to avoid discarding it on the fly on a simple hover over
  // another panel (see bgPanel's HoverHandler further down).
  readonly property bool hasPendingEdit: EditModeState.renamingIndex >= 0 || EditModeState.creatingFolder || EditModeState.creatingFile || EditModeState.editingPath

  // Real bug (audit 2026-08-05): any dialog with a
  // "confirm" step that re-reads NavState.currentPath/registry.selectionOps.selectedEntries() AT THE
  // MOMENT OF THE CLICK (not on opening) can end up acting on the
  // wrong folder if the active tab changes while the dialog
  // stays open -- and nothing prevented it from changing, because the hover-to-
  // activate-panel was only blocked for hasPendingEdit/contextMenuOpen,
  // not for the rest of the dialogs (chmod, open-with, conflicts on paste/
  // extract/compress/bulk rename/drop, confirm delete,
  // palette, connect to server, properties). Instead of capturing the
  // path by hand at each site, a single blocking point in
  // switchToTab() covers all cases at once: while any of
  // these is open, the active tab (and its currentPath) cannot
  // move out from under the dialog.
  readonly property bool hasBlockingOverlay: root.hasPendingEdit || ContextMenuState.contextMenuOpen
    || root.pendingDeleteNames.length > 0 || ConflictState.renameConflictOpen || ConflictState.pasteConflictOpen
    || ConflictState.extractConflictOpen || ConflictState.compressConflictOpen || ConflictState.bulkRenameConflictOpen
    || ConflictState.dropConflictOpen || ConflictState.newFileConflictOpen || ConflictState.newFolderConflictOpen
    || PaletteState.paletteOpen || PreviewState.openWithOpen || DialogsState.bulkRenameOpen
    || ChmodState.chmodOpen || PropertiesState.propertiesOpen || DialogsState.connectServerOpen

  // actionBusy/actionLabel/actionProgressPct/_actionOnSuccess now live in
  // state/ActionState.qml -- twelfth slice of the state/ layer, completes
  // the migration of logic/ActionEngine.qml (undoStack/redoStack were already
  // in state/UndoState.qml). actionBusyDots stays here -- purely
  // visual animation, see the Timer further down.
  property string actionBusyDots: ""

  // clipboardPaths/clipboardMode now live in state/ClipboardState.qml
  // (singleton) -- second slice of the state/ layer, same pattern as
  // SelectionState. Logic unchanged in logic/ClipboardOps.qml.

  property var pendingDeleteNames: []

  // pendingRename/renameConflictOpen, pasteConflictNames/pasteConflictOpen,
  // pendingExtract/extractConflictNames/extractConflictOpen,
  // pendingCompress/compressConflictOpen, pendingBulkRename/
  // bulkRenameInternalDupes/bulkRenameConflictCount/bulkRenameConflictOpen,
  // dropPendingSources/dropTargetDir/dropIsMove/dropConflictNames/
  // dropConflictOpen now live in state/ConflictState.qml (singleton) --
  // fourth slice of the state/ layer. Logic unchanged in
  // logic/ConflictActions.qml and others.

  // dropHoverIndex/dropHoverPath now live in state/DropHoverState.qml --
  // seventeenth slice of the state/ layer.

  // contextMenuOpen/X/Y/Actions now live in state/ContextMenuState.qml,
  // paletteOpen/Query/Index in state/PaletteState.qml, and previewOpen/
  // openWithOpen/openWithApps/openWithEntry in state/PreviewState.qml --
  // fifth, sixth and seventh slice of the state/ layer.

  property bool gPending: false

  // bulkRenameOpen/Pattern, shortcutsHelpOpen and connectServerOpen/Uri/
  // Error/networkConnecting now live in state/DialogsState.qml --
  // eleventh slice of the state/ layer.

  // chmodOpen/Names/Mixed/Mode/HasDir/Recursive/OriginalModes now live
  // in state/ChmodState.qml -- eighth slice of the state/ layer.

  // propertiesOpen/Entry/Size/SizeLoading/Perms/Owner/Mtime/RequestId/
  // _propertiesStatOwner/_propertiesDuOwner/Multi/Count now live in
  // state/PropertiesState.qml -- ninth slice of the state/ layer.

  // previewEntry/Text/IsText/Highlighted/PdfImage/AudioInfo/RequestId/
  // _previewTextOwner/_previewHighlightOwner/_previewPdfOwner/
  // _previewAudioOwner now live in state/PreviewContentState.qml --
  // tenth slice of the state/ layer.

  // trashInfo now lives in state/TrashState.qml -- nineteenth slice
  // of the state/ layer.
  // mounts/networkMounts now live in state/MountsState.qml --
  // fifteenth slice of the state/ layer.

  // Browse inside a .zip/.7z/.rar/.tar without extracting it -- NavState.currentPath
  // NEVER changes while this is active (it remains the real folder
  // containing the archive); root.entries comes from list-archive.sh
  // instead of list-dir.sh. Deliberately read-only: no multiple
  // selection/context menu/rename/delete/chmod/drag -- see the
  // "if (ArchiveState.inArchive) return" guards in each action that mutates
  // disk. inArchive/archivePath/archiveSubPath now live in
  // state/ArchiveState.qml -- twentieth slice of the state/ layer.

  // defaultBookmarks and the four state *.json (bookmarksFile/recentFile/
  // sessionFile/bulkRenameHistoryFile) now live in state/Paths.qml (Phase
  // 14.B). bookmarks/recentFiles/recentLoaded/bulkRenameHistory/
  // bulkRenameHistoryLoaded/bookmarksLoaded live in state/BookmarksState.qml.

  // The extension lists (imageExt/videoExt/audioExt/archiveExt/codeExt/
  // tarExt) now live in state/FileTypeConfig.qml (Phase 14.B).

  // ---------- File type (extension/icon) ----------
  // iconFor/isImage/isVideo/isAudio/isPdf remain as thin wrappers because
  // the visual layer (delegates/panels) calls them via the root facade.
  // extOf no longer: its logic/ callers receive fileTypeUtils injected
  // (Phase 14.D). The real controller is logic/FileTypeUtils.qml.
  function iconFor(entry) { return registry.fileTypeUtils.iconFor(entry) }
  function isImage(entry) { return registry.fileTypeUtils.isImage(entry) }
  function isVideo(entry) { return registry.fileTypeUtils.isVideo(entry) }
  function isAudio(entry) { return registry.fileTypeUtils.isAudio(entry) }
  function isPdf(entry) { return registry.fileTypeUtils.isPdf(entry) }

  // ---------- Video thumbnails (ffmpegthumbnailer, queued 1 at a time) ----------
  // thumbCacheDir now lives in state/Paths.qml (Phase 14.B).
  // videoThumbReady/thumbQueue/thumbBusy now live in
  // state/VideoThumbState.qml -- fourteenth slice of the state/ layer.

  // thumbKeyFor (in-memory key of the thumbnail dict) lives in Utils.js.
  // The cache file-name hash is unique and lives in the backend
  // (ThumbnailProvider.cacheKey, SHA-1) since Phase B1.

  // ---------- Selection (individual + lasso) ----------

  // ---------- Directory refresh / watching ----------
  // The real logic lives in logic/NavigationController.qml (navController
  // further down) -- these are thin wrappers because refresh/startDirWatch/
  // stopDirWatch are called by ~10 different files (KeyboardShortcuts,
  // MountActions, Persistence, ArchiveActions, ActionEngine...) and it's not
  // worth the risk of touching all those call sites.
  function refresh() { registry.navController.refresh() }
  function startDirWatch(path) { registry.navController.startDirWatch(path) }
  function stopDirWatch() { registry.navController.stopDirWatch() }


  // addRecent/removeRecent/clearRecent/addBulkRenameHistory,
  // removeBookmark/addBookmark/iconForBookmark/isBookmarked,
  // iconForMount/iconForNetworkMount/networkMountActions now live in
  // logic/BookmarkOps.qml.
  // parseMounts/parseNetworkMounts: moved to Utils.js (pure functions).


  // ---------- Trash ----------
  function emptyTrash() {
    // "gio trash --empty" only empties the home trash -- now that
    // the view aggregates that of any mounted disk (see
    // trash-roots.sh), emptying has to cover the same or the button
    // would leave things orphaned while claiming to have emptied everything.
    registry.actionEngine.runAction("bash " + Util.shellQuote(Paths.resourceDir + "/empty-trash.sh"), "Emptying trash…")
  }

  // parseEntries: moved to Utils.js (pure function, the full comment
  // about the NUL-delimited protocol is there now).

  // naturalCompare: moved to Utils.js (pure function).

  // ---------- List order ----------
  // compareEntries/sortEntries/sortLabel/setSort/cycleSort/reverseSort
  // now live in logic/SortOps.qml.

  // ---------- Navigation / history / tabs ----------
  // joinPath moved to Utils.js (pure function, Phase 14.D): logic/ and the
  // visual layer call it as Utils.joinPath, no longer via the root facade.

  // The real navigation/history logic lives in
  // logic/NavigationController.qml (navController further down) -- thin
  // wrappers for the same reason as refresh()/startDirWatch() above
  // (called from KeyboardShortcuts, MountActions, BookmarkOps,
  // ArchiveActions, TabOps, FileListRow, BackgroundPanel...). _goToPath
  // is also exposed like this -- TabOps already calls it as root._goToPath(...).
  function navigateTo(path) { registry.navController.navigateTo(path) }
  function _goToPath(path) { registry.navController._goToPath(path) }
  function navBack() { registry.navController.navBack() }
  function navForward() { registry.navController.navForward() }
  function openWithDefault(path) { registry.navController.openWithDefault(path) }
  function enter(entry) { registry.navController.enter(entry) }
  function goUp() { registry.navController.goUp() }

  // ---------- Lifecycle (open/close the host window) ----------
  // Host-initiated open/close (`shell toggle`/`shell summon`/`shell hide`).
  // `payload` is "<path>" or "<path>\n<name-to-select>" in plain
  // text (or "" / "{}" if there is none) -- sent by `scripts/open-path.sh`
  // (xdg-open/.desktop, no selection) or `scripts/dbus-filemanager1.py`
  // (org.freedesktop.FileManager1 interface, with selection for ShowItems).
  function open(payload) {
    root.opened = true

    var nlIdx = payload ? payload.indexOf("\n") : -1
    var folderPart = nlIdx >= 0 ? payload.substring(0, nlIdx) : payload
    // Several names to select at once are separated with \x1f (ASCII
    // Unit Separator) -- a single name without \x1f still works the same
    // as before (array of 1). See dbus-filemanager1.py, which now groups
    // several URIs of the same folder into a single summon() with all the
    // names, instead of one summon (and one tab) per URI.
    var selectPart = nlIdx >= 0 ? payload.substring(nlIdx + 1) : ""
    var selectNames = selectPart ? selectPart.split("\x1f") : []

    if (selectPart.indexOf("picker:") === 0) {
      var parts = selectPart.split(":")
      if (parts.length >= 4) {
        PickerState.active = true
        PickerState.requestId = parts[1]
        PickerState.mode = parts[2]
        PickerState.multiple = (parts[3] === "true")
        PickerState.suggestedName = parts.slice(4).join(":")
      }
      selectNames = []
    } else {
      PickerState.active = false
      PickerState.requestId = ""
      PickerState.mode = "open-file"
      PickerState.multiple = false
      PickerState.suggestedName = ""
    }

    var targetPath = (folderPart && folderPart.charAt(0) === "/") ? folderPart : ""

    if (targetPath) NavState.pendingSelectNames = selectNames

    var restoringSession = false
    if (!root.loaded) {
      if (targetPath) {
        NavState.currentPath = targetPath
        TabsState.tabs = [{ path: targetPath, history: [targetPath], historyIndex: 0 }]
        TabsState.navHistory = [targetPath]
        TabsState.navHistoryIndex = 0
        root.refresh()
      } else {
        // First open of this Quickshell session without a path
        // requested by the host -- tries to restore folder/tabs from the
        // previous session (session.json) instead of always opening in
        // homeDir. loadSession() triggers refresh()/startDirWatch on its
        // own as soon as it knows the real path (reading the file is async), so
        // it's not done here -- avoids listing homeDir extra only to discard it
        // right away if there was indeed a saved session.
        restoringSession = true
        registry.persistence.loadSession()
      }
    } else if (targetPath) {
      // It was already loaded before (previous normal use): opens in a new
      // tab so as not to lose the location the user was already in.
      registry.tabOps.newTab()
      root.navigateTo(targetPath)
      registry.tabOps.saveActiveTab()
    }

    if (!BookmarksState.bookmarksLoaded) registry.persistence.loadBookmarks()
    if (!BookmarksState.recentLoaded) registry.persistence.loadRecent()
    if (!BookmarksState.bulkRenameHistoryLoaded) registry.persistence.loadBulkRenameHistory()
    registry.mountOps.refreshMounts()
    registry.mountOps.refreshNetworkMounts()
    // Covers the two remaining cases: first load with target (currentPath
    // just set, above) and reopening pointing to a target (navigateTo already
    // started it inside _goToPath, this only reaffirms it over the same final
    // path) or reopening WITHOUT target (the window was closed -> close()
    // stopped the watcher -> without this it would reopen showing an unwatched
    // folder). The remaining case (restoringSession) is already covered by
    // Persistence.loadSession() on its own.
    if (!restoringSession && !ArchiveState.inArchive) root.startDirWatch(NavState.currentPath)
  }

  function cancelPicker() {
    if (PickerState.active && PickerState.requestId) {
      var reqId = PickerState.requestId
      PickerState.active = false
      PickerState.requestId = ""
      Detached.run([
        "dbus-send",
        "--session",
        "--type=method_call",
        "--dest=org.freedesktop.impl.portal.desktop.omafiles",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.impl.portal.desktop.omafiles.SubmitResponse",
        "string:" + reqId,
        "uint32:1",
        "string:[]"
      ])
    }
    root.close()
    root.requestClose()
  }

  function close() {
    if (PickerState.active && PickerState.requestId) {
      var reqId = PickerState.requestId
      PickerState.active = false
      PickerState.requestId = ""
      Detached.run([
        "dbus-send",
        "--session",
        "--type=method_call",
        "--dest=org.freedesktop.impl.portal.desktop.omafiles",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.impl.portal.desktop.omafiles.SubmitResponse",
        "string:" + reqId,
        "uint32:1",
        "string:[]"
      ])
    }
    if (!PickerState.active) {
      registry.persistence.saveSession()
    }
    root.opened = false
    root.stopDirWatch()
    EditModeState.renamingIndex = -1
    EditModeState.creatingFolder = false
    EditModeState.creatingFile = false
    EditModeState.editingPath = false
    root.pendingDeleteNames = []
    ContextMenuState.contextMenuOpen = false
    // keepLoaded:true keeps the component alive between closes -- without
    // resetting this, the next time the window is opened the same
    // dialog/panel from the previous session would appear still open.
    PropertiesState.propertiesOpen = false
    DialogsState.shortcutsHelpOpen = false
    ChmodState.chmodOpen = false
    PreviewState.openWithOpen = false
    DialogsState.bulkRenameOpen = false
    PreviewState.previewOpen = false
    NavState.searching = false
    PaletteState.paletteOpen = false
    ConflictState.renameConflictOpen = false
    ConflictState.pasteConflictOpen = false
    ConflictState.dropConflictOpen = false
    ConflictState.extractConflictOpen = false
    ConflictState.pendingExtract = null
    ConflictState.compressConflictOpen = false
    ConflictState.pendingCompress = null
    ConflictState.bulkRenameConflictOpen = false
    ConflictState.pendingBulkRename = null
    DialogsState.connectServerOpen = false
    PickerState.active = false
    PickerState.requestId = ""
  }

  // User-initiated close (Esc, closing the last tab, the window's close
  // button). Before it talked to the host directly (root.shell.hide());
  // now it only emits closeRequested() -- Omafiles.qml (the Quickshell
  // frontend bootstrap) decides whether that means notifying the host or closing
  // directly, without this file knowing anything about Quickshell.
  signal closeRequested()
  signal pickerSubmitRequested()

  function requestClose() {
    root.closeRequested()
  }


  // runAction/chainCmds/startCopyProgress and the native runners (copyFiles/
  // moveFiles/removeFiles/trashFiles/restoreFiles) were thin wrappers to
  // registry.actionEngine.*; their logic/ callers now receive
  // actionEngine injected (Phase 14.D), so they were removed. cancelAction
  // stays: the visual layer (cancel button) calls it via the root
  // facade.
  function cancelAction() {
    registry.actionEngine.cancelAction()
  }

  function openTerminalHere() {
    // ProcessRunner, not Detached -- same reason as openWithDefault().
    registry.openProc.start(["xdg-terminal-exec", "--dir=" + NavState.currentPath])
  }

  // ---------- Operational facade (delegated to core/CommandFacade.qml) ----------
  // Phase 11.C: the bodies of these builders live in CommandFacade; here
  // remain thin delegates so panels/dialogs/KeyboardShortcuts keep
  // calling root.X()/hostRoot.X() unchanged.
  function paletteCommands() { return commandFacade.paletteCommands() }
  function filteredPaletteCommands() { return commandFacade.filteredPaletteCommands() }
  function openPalette() { commandFacade.openPalette() }
  function closePalette() { commandFacade.closePalette() }
  function runPaletteCommand(index) { commandFacade.runPaletteCommand(index) }
  function openContextMenu(x, y, actions) { commandFacade.openContextMenu(x, y, actions) }
  function itemActions() { return commandFacade.itemActions() }
  function emptyAreaActions() { return commandFacade.emptyAreaActions() }
  function openBookmark(bookmark) { commandFacade.openBookmark(bookmark) }
  function openRecent(item) { commandFacade.openRecent(item) }
  function launchRecent(item) { commandFacade.launchRecent(item) }
  function bookmarkActions(bookmark) { return commandFacade.bookmarkActions(bookmark) }
  function mountActions(mount) { return commandFacade.mountActions(mount) }
  function pathSegments() { return commandFacade.pathSegments() }
  function pathSegmentsFor(targetPath) { return commandFacade.pathSegmentsFor(targetPath) }

  // Self-registration as the system file manager (MimeType inode/
  // directory + org.freedesktop.FileManager1) -- launched once on
  // loading the plugin, without waiting for the user to open the window nor
  // having to run anything by hand. The script is idempotent (see
  // scripts/install-integrations.sh), so calling it on every shell
  // startup is cheap and safe.

  // dirWatchProc/dirWatchDebounce/listProc/trashInfoProc now live in
  // logic/NavigationController.qml (navController further down), along with
  // the rest of the navigation/listing controller.

  // Disks/network have no easy event to watch here (one would have to
  // subscribe to UDisks2/GVfs D-Bus signals) -- modest polling
  // is the honest option given the scope: plugging in a USB or a network
  // location going down is noticed in a few seconds instead of never
  // (before) or having to set up D-Bus infrastructure (later,
  // maybe). "running: root.opened" so it doesn't keep running in the background
  // with the window closed.

  // ---------- Controllers (logic/) ----------
  // Phase 11.C: OmafilesContent no longer instantiates the controllers. Their SOLE
  // owner is core/ControllerRegistry.qml (single ownership from the
  // 2026-08-09 audit). Here the registry is instantiated and its
  // controllers are exposed as aliases so the operational facade and the visual layer
  // reference them by the same name, without a god object nor rewriting each
  // call site.
  ControllerRegistry {
    id: registry
    root: root
    list: mainLayout.list
  }

  // Action engine exposed as a reference (not wrapper): MainLayout
  // injects it into KeyboardShortcuts and the --selfcheck harness exercises its
  // native runners directly, the SAME path the app uses after
  // dependency injection (Phase 14.D). It's an explicit seam, not the
  // generic god-object facade.
  readonly property alias actionEngine: registry.actionEngine

  // Operational facade (menu/command/breadcrumb builders). Phase 11.C.
  CommandFacade {
    id: commandFacade
    root: root
    archiveActions: registry.archiveActions
    bookmarkOps: registry.bookmarkOps
    clipboardOps: registry.clipboardOps
    conflictActions: registry.conflictActions
    deleteOps: registry.deleteOps
    fileOps: registry.fileOps
    mountOps: registry.mountOps
    openWithOps: registry.openWithOps
    propertiesLoader: registry.propertiesLoader
    renameOps: registry.renameOps
    searchOps: registry.searchOps
    selectionOps: registry.selectionOps
    sortOps: registry.sortOps
    tabOps: registry.tabOps
    customActions: registry.customActions
  }

  // Lifecycle and timer wiring. Phase 11.C.
  AppBindings {
    id: appBindings
    root: root
    mountOps: registry.mountOps
  }



  MainLayout {
    id: mainLayout
    anchors.fill: parent
    root: root
    actionEngine: registry.actionEngine
    navController: registry.navController
    bookmarkOps: registry.bookmarkOps
    mountOps: registry.mountOps
    dragDropOps: registry.dragDropOps
    videoThumbs: registry.videoThumbs
    fileMeta: registry.fileMeta
    tabOps: registry.tabOps
    sortOps: registry.sortOps
    searchOps: registry.searchOps
    selectionOps: registry.selectionOps
    conflictActions: registry.conflictActions
    previewLoader: registry.previewLoader
    fileOps: registry.fileOps
    renameOps: registry.renameOps
    clipboardOps: registry.clipboardOps
    deleteOps: registry.deleteOps
    gTimer: appBindings.gTimer
    deleteConfirm: dialogLayer.deleteConfirm
    renameConflictConfirm: dialogLayer.renameConflictConfirm
    extractConflictConfirm: dialogLayer.extractConflictConfirm
    compressConflictConfirm: dialogLayer.compressConflictConfirm
    bulkRenameConflictConfirm: dialogLayer.bulkRenameConflictConfirm
    newFileConflictConfirm: dialogLayer.newFileConflictConfirm
    newFolderConflictConfirm: dialogLayer.newFolderConflictConfirm
  }

  // ---------- Dialog/overlay layer (Phase 11.B) ----------
  // Sibling of MainLayout (both anchors.fill: parent) -- before a child of the
  // card; geometrically identical (the card fills root). The seven
  // ConfirmDialog are exposed by DialogLayer and MainLayout receives them for its
  // ActiveFileList.
  DialogLayer {
    id: dialogLayer
    anchors.fill: parent
    root: root
    list: mainLayout.list
    conflictActions: registry.conflictActions
    mountOps: registry.mountOps
    fileOps: registry.fileOps
    openWithOps: registry.openWithOps
    deleteOps: registry.deleteOps
    renameOps: registry.renameOps
    archiveActions: registry.archiveActions
    clipboardOps: registry.clipboardOps
    dragDropOps: registry.dragDropOps
  }
}

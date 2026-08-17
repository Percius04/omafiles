import QtQuick
import Omafiles.Backend as Backend
import qs.Commons
import qs.Ui
import "../dialogs"
import "../panels"
import "../logic"
import "../shared"
import "../state"

// OmafilesContent -- composition root of the Omafiles window.
Item {
  id: root

  // --- Properties & State ---
  property var tabEntriesCache: ({})
  property bool opened: false
  property bool loaded: false
  property bool suppressListFade: false
  property real _pendingScrollY: -1
  property int _pendingScrollIndex: -1
  property real _pendingScrollOffset: 0
  property real measuredRowHeight: 0
  property string actionBusyDots: ""
  property var pendingDeleteNames: []
  property var pendingDeleteEntries: []
  property bool gPending: false

  readonly property bool hasPendingEdit: EditModeState.renamingIndex >= 0 || EditModeState.creatingFolder || EditModeState.creatingFile || EditModeState.editingPath

  readonly property bool hasBlockingOverlay: root.hasPendingEdit || ContextMenuState.contextMenuOpen
    || root.pendingDeleteNames.length > 0 || ConflictState.pasteConflictOpen
    || ConflictState.extractConflictOpen || ConflictState.compressConflictOpen || ConflictState.bulkRenameConflictOpen
    || ConflictState.dropConflictOpen || ConflictState.newFileConflictOpen || ConflictState.newFolderConflictOpen
    || PaletteState.paletteOpen || PreviewState.openWithOpen || DialogsState.bulkRenameOpen
    || ChmodState.chmodOpen || PropertiesState.propertiesOpen || DialogsState.connectServerOpen

  // ---------- Lifecycle (open/close the host window) ----------
  function open(payload) {
    root.opened = true

    var nlIdx = payload ? payload.indexOf("\n") : -1
    var folderPart = nlIdx >= 0 ? payload.substring(0, nlIdx) : payload
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
        registry.navController.refresh()
      } else {
        restoringSession = true
        registry.persistence.loadSession()
      }
    } else if (targetPath) {
      registry.tabOps.newTab()
      registry.navController.navigateTo(targetPath)
      registry.tabOps.saveActiveTab()
    }

    if (!BookmarksState.bookmarksLoaded) registry.persistence.loadBookmarks()
    if (!BookmarksState.recentLoaded) registry.persistence.loadRecent()
    if (!BookmarksState.bulkRenameHistoryLoaded) registry.persistence.loadBulkRenameHistory()
    registry.mountOps.refreshMounts()
    registry.mountOps.refreshNetworkMounts()
    if (!restoringSession && !ArchiveState.inArchive) registry.navController.startDirWatch(NavState.currentPath)
  }

  function cancelPicker() {
    if (PickerState.active && PickerState.requestId) {
      var reqId = PickerState.requestId
      PickerState.active = false
      PickerState.requestId = ""
      Backend.Detached.run([
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
      Backend.Detached.run([
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
    registry.navController.stopDirWatch()
    EditModeState.renamingIndex = -1
    EditModeState.creatingFolder = false
    EditModeState.creatingFile = false
    EditModeState.editingPath = false
    root.pendingDeleteNames = []
    root.pendingDeleteEntries = []
    ContextMenuState.contextMenuOpen = false
    PropertiesState.propertiesOpen = false
    DialogsState.shortcutsHelpOpen = false
    ChmodState.chmodOpen = false
    PreviewState.openWithOpen = false
    DialogsState.bulkRenameOpen = false
    PreviewState.previewOpen = false
    NavState.searching = false
    PaletteState.paletteOpen = false
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

  signal closeRequested()
  signal pickerSubmitRequested()

  function requestClose() {
    root.closeRequested()
  }

  function undoLast() {
    registry.actionEngine.undoLast()
  }

  function redoLast() {
    registry.actionEngine.redoLast()
  }

  // ---------- Controllers & Facades ----------
  ControllerRegistry {
    id: registry
    root: root
    list: mainLayout.list
  }

  readonly property alias controllers: registry
  readonly property alias actionEngine: registry.actionEngine
  readonly property alias navController: registry.navController
  readonly property alias commandFacade: commandFacade

  CommandFacade {
    id: commandFacade
    root: root
    mountOps: registry.mountOps
    propertiesLoader: registry.propertiesLoader
    searchOps: registry.searchOps
    tabOps: registry.tabOps
    customActions: registry.customActions
    navController: registry.navController
    actionEngine: registry.actionEngine
    openProc: registry.openProc
  }

  AppBindings {
    id: appBindings
    root: root
    mountOps: registry.mountOps
  }

  // --- UI Components & Dialogs ---
  MainLayout {
    id: mainLayout
    anchors.fill: parent
    root: root
    controllers: registry
    commandFacade: commandFacade
    dialogs: dialogLayer
    gTimer: appBindings.gTimer
  }

  DialogLayer {
    id: dialogLayer
    anchors.fill: parent
    root: root
    list: mainLayout.list
    controllers: registry
    commandFacade: commandFacade
  }
}

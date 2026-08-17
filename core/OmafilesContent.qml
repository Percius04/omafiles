import QtQuick
import Omafiles.Backend as Backend
import qs.Commons
import qs.Ui
import "../dialogs"
import "../panels"
import "../logic"
import "../shared"
import "../shared/Utils.js" as Utils
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

    var pickerPayload = null
    var fileManagerPayload = null
    if (payload && payload.charAt(0) === "{") {
      try {
        var decoded = JSON.parse(payload)
        if (decoded.kind === "picker") pickerPayload = decoded
        else if (decoded.kind === "file-manager") fileManagerPayload = decoded
      } catch (e) {
        pickerPayload = null
        fileManagerPayload = null
      }
    }

    var structuredPayload = pickerPayload || fileManagerPayload
    var nlIdx = !structuredPayload && payload ? payload.indexOf("\n") : -1
    var folderPart = structuredPayload ? String(structuredPayload.folder || "")
      : (nlIdx >= 0 ? payload.substring(0, nlIdx) : payload)
    var selectPart = !structuredPayload && nlIdx >= 0 ? payload.substring(nlIdx + 1) : ""
    var selectNames = fileManagerPayload ? fileManagerPayload.basenames.slice()
      : (selectPart ? selectPart.split("\x1f") : [])

    if (pickerPayload) {
      var modes = ["open-file", "open-dir", "save-file", "save-files"]
      var files = Array.isArray(pickerPayload.files) ? pickerPayload.files : []
      var validFiles = []
      for (var fileIndex = 0; fileIndex < files.length; fileIndex++) {
        if (Utils.validBasename(files[fileIndex])) validFiles.push(String(files[fileIndex]))
      }
      var schema = ["files", "folder", "kind", "mode", "multiple", "requestId", "suggestedName"]
      PickerState.active = Object.keys(pickerPayload).sort().join(",") === schema.join(",")
        && modes.indexOf(pickerPayload.mode) >= 0
        && String(pickerPayload.requestId || "").length > 0
        && typeof pickerPayload.multiple === "boolean"
        && PickerResponder.ready
        && (pickerPayload.mode !== "save-files"
            || validFiles.length === files.length && files.length > 0)
      PickerState.sessionActive = PickerState.active
      PickerState.mode = PickerState.active ? String(pickerPayload.mode) : "open-file"
      PickerState.multiple = PickerState.active && pickerPayload.multiple === true
      PickerState.suggestedName = PickerState.active ? String(pickerPayload.suggestedName || "") : ""
      PickerState.saveFiles = PickerState.active ? validFiles : []
    } else {
      PickerState.active = false
      PickerState.sessionActive = false
      PickerState.mode = "open-file"
      PickerState.multiple = false
      PickerState.suggestedName = ""
      PickerState.saveFiles = []
    }

    var targetPath = (folderPart && folderPart.charAt(0) === "/") ? folderPart : ""

    NavState.pendingFileManagerAction = fileManagerPayload
      ? String(fileManagerPayload.action || "") : ""
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
    if (PickerState.active && !PickerResponder.submit(1, [])) return false
    PickerState.active = false
    if (!root.close()) return false
    root.requestClose()
    return true
  }

  function close() {
    if (PickerState.active && !PickerResponder.submit(1, [])) return false
    PickerState.active = false
    if (!PickerState.sessionActive) registry.persistence.saveSession()
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
    PickerState.saveFiles = []
    return true
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

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
  Connections {
    target: ViewState
    function onViewModeChanged() { root.measuredRowHeight = 0 }
  }
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

  function _exactKeys(object, keys) {
    return object && typeof object === "object" && !Array.isArray(object)
      && Object.keys(object).sort().join(",") === keys.slice().sort().join(",")
  }

  function _validText(value, allowEmpty) {
    return typeof value === "string" && (allowEmpty || value.length > 0)
      && value.indexOf("\0") < 0
  }

  function _validPickerContract(payload) {
    if (!_exactKeys(payload, ["choices", "currentFilter", "files", "filters", "folder",
                                      "kind", "mode", "multiple", "requestId", "suggestedName"])
        || !Array.isArray(payload.filters) || !Array.isArray(payload.choices)
        || typeof payload.currentFilter !== "number"
        || Math.floor(payload.currentFilter) !== payload.currentFilter) return false
    for (var filterIndex = 0; filterIndex < payload.filters.length; filterIndex++) {
      var filter = payload.filters[filterIndex]
      if (!_exactKeys(filter, ["name", "rules"]) || !_validText(filter.name, false)
          || !Array.isArray(filter.rules) || filter.rules.length === 0) return false
      for (var ruleIndex = 0; ruleIndex < filter.rules.length; ruleIndex++) {
        var rule = filter.rules[ruleIndex]
        if (!_exactKeys(rule, ["type", "value"]) || (rule.type !== 0 && rule.type !== 1)
            || !_validText(rule.value, false)) return false
      }
    }
    if ((payload.filters.length === 0 && payload.currentFilter !== -1)
        || (payload.filters.length > 0
            && (payload.currentFilter < 0 || payload.currentFilter >= payload.filters.length))) return false
    var choiceIds = ({})
    for (var choiceIndex = 0; choiceIndex < payload.choices.length; choiceIndex++) {
      var choice = payload.choices[choiceIndex]
      if (!_exactKeys(choice, ["id", "label", "options", "selected"])
          || !_validText(choice.id, false) || !_validText(choice.label, false)
          || !_validText(choice.selected, false) || !Array.isArray(choice.options)
          || choiceIds[choice.id] === true) return false
      choiceIds[choice.id] = true
      var optionIds = ({})
      for (var optionIndex = 0; optionIndex < choice.options.length; optionIndex++) {
        var option = choice.options[optionIndex]
        if (!_exactKeys(option, ["id", "label"]) || !_validText(option.id, false)
            || !_validText(option.label, false) || optionIds[option.id] === true) return false
        optionIds[option.id] = true
      }
      if ((choice.options.length > 0 && optionIds[choice.selected] !== true)
          || (choice.options.length === 0
              && choice.selected !== "true" && choice.selected !== "false")) return false
    }
    return true
  }

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
      PickerState.active = root._validPickerContract(pickerPayload)
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
      if (PickerState.active)
        PickerState.configureContract(pickerPayload.filters, pickerPayload.currentFilter,
                                      pickerPayload.choices)
      else
        PickerState.resetContract()
    } else {
      PickerState.active = false
      PickerState.sessionActive = false
      PickerState.mode = "open-file"
      PickerState.multiple = false
      PickerState.suggestedName = ""
      PickerState.saveFiles = []
      PickerState.resetContract()
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
    if (PickerState.active && !PickerResponder.submit(1, PickerState.resultMap([]))) return false
    PickerState.active = false
    if (!root.close()) return false
    root.requestClose()
    return true
  }

  function close() {
    if (PickerState.active && !PickerResponder.submit(1, PickerState.resultMap([]))) return false
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
    PickerState.resetContract()
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

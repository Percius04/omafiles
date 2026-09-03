import QtQuick
import qs.Commons
import qs.Ui
import "../dialogs"
import "../state"
import Omafiles.Backend as Backend

// DialogLayer -- modal dialog/overlay layer of Omafiles (Phase 11.B,
// josema: decompose the god object core/OmafilesContent.qml by
// responsibility). It contains EVERYTHING that used to be the last ~315
// lines of OmafilesContent: bulk rename, connect to server,
// permissions, properties, shortcuts help, copy/move-in-progress card,
// open-with, context menu, the seven ConfirmDialog, the two
// ConflictResolveDialog and the command palette.
//
// Dependencies INJECTED explicitly (same pattern as ActiveFileList,
// not via root.* -- see ARCHITECTURE.md: dialogs receive data via
// props/callbacks). root/list for the facade and returning focus; the ops
// from logic/ that each dialog confirms. The seven ConfirmDialog are exposed
// as aliases because ActiveFileList references them back (opens/closes
// according to the listing result).
Item {
  id: dialogLayer
  anchors.fill: parent

  property Item root
  property Item list
  property var controllers
  property var commandFacade

  property alias deleteConfirm: deleteConfirm
  property alias renameConflictConfirm: renameConflictConfirm
  property alias newFileConflictConfirm: newFileConflictConfirm
  property alias newFolderConflictConfirm: newFolderConflictConfirm
  property alias extractConflictConfirm: extractConflictConfirm
  property alias compressConflictConfirm: compressConflictConfirm
  property alias bulkRenameConflictConfirm: bulkRenameConflictConfirm
  property alias connectServer: connectServerDialog

  // ---------- Bulk rename ----------
  BulkRenamePanel {
    anchors.fill: parent
    open: DialogsState.bulkRenameOpen
    entries: SelectionState.selectedEntries()
    pattern: DialogsState.bulkRenamePattern
    find: DialogsState.bulkRenameFind
    replace: DialogsState.bulkRenameReplace
    history: BookmarksState.bulkRenameHistory
    onCloseRequested: DialogsState.bulkRenameOpen = false
    onRenameRequested: function (pattern, find, replace) {
      DialogsState.bulkRenamePattern = pattern
      DialogsState.bulkRenameFind = find
      DialogsState.bulkRenameReplace = replace
      if (controllers && controllers.actionEngine) controllers.actionEngine.commitBulkRename()
    }
    onFocusReturnRequested: list.forceActiveFocus()
  }

  // ---------- Find duplicates ----------
  DuplicateFinderPanel {
    anchors.fill: parent
    open: DialogsState.duplicateFinderOpen
    scanning: DuplicatesState.scanning
    filesScanned: DuplicatesState.filesScanned
    groups: DuplicatesState.groups
    selected: DuplicatesState.selected
    selectedCount: DuplicatesState.selectedCount
    onCloseRequested: if (controllers && controllers.actionEngine) controllers.actionEngine.cancelDuplicateFinder()
    onCancelRequested: if (controllers && controllers.actionEngine) controllers.actionEngine.cancelDuplicateFinder()
    onToggleRequested: function (path) { DuplicatesState.toggle(path) }
    onSelectAllButFirstRequested: DuplicatesState.selectAllButFirstPerGroup()
    onTrashRequested: if (controllers && controllers.actionEngine) controllers.actionEngine.commitDuplicateTrash()
  }

  // ---------- Connect to server ----------
  ConnectServer {
    id: connectServerDialog
    anchors.fill: parent
    open: DialogsState.connectServerOpen
    connecting: DialogsState.networkConnecting
    uri: DialogsState.connectServerUri
    errorText: DialogsState.connectServerError

    authRequested: DialogsState.networkAuthRequested
    authMessage: DialogsState.networkAuthMessage
    authUser: DialogsState.networkAuthUser
    profiles: BookmarksState.networkProfiles

    onConnectRequested: function (uri) {
      DialogsState.connectServerUri = uri
      if (controllers && controllers.mountOps) controllers.mountOps.commitConnectToServer()
    }

    onProfileRemoveRequested: function (uri) { BookmarksState.removeNetworkProfile(uri) }

    onAuthSubmitted: function (user, password, remember) {
      DialogsState.networkConnecting = true
      Backend.NetworkResolver.submitAuth(user, password, remember)
    }

    onCancelConnectingRequested: if (controllers && controllers.mountOps) controllers.mountOps.cancelNetworkConnect()
    onCloseRequested: if (controllers && controllers.mountOps) controllers.mountOps.cancelConnectToServer()
    onFocusReturnRequested: list.forceActiveFocus()
  }

  // ---------- Properties + Permissions (merged) ----------
  PropertiesDialog {
    anchors.fill: parent
    open: ChmodState.chmodOpen || PropertiesState.propertiesOpen
    multi: PropertiesState.propertiesMulti
    count: PropertiesState.propertiesCount
    entry: PropertiesState.propertiesEntry
    sizeLoading: PropertiesState.propertiesSizeLoading
    size: PropertiesState.propertiesSize
    perms: PropertiesState.propertiesPerms
    owner: PropertiesState.propertiesOwner
    mtime: PropertiesState.propertiesMtime
    names: ChmodState.chmodNames
    mixed: ChmodState.chmodMixed
    mode: ChmodState.chmodMode
    hasDir: ChmodState.chmodHasDir
    recursive: ChmodState.chmodRecursive
    onCloseRequested: {
      PropertiesState.propertiesOpen = false
      ChmodState.chmodOpen = false
    }
    onBitToggled: function (ownerIdx, bit) { if (controllers && controllers.actionEngine) controllers.actionEngine.toggleChmodBit(ownerIdx, bit) }
    onRecursiveToggled: ChmodState.chmodRecursive = !ChmodState.chmodRecursive
    onApplyRequested: function (mode) { if (controllers && controllers.actionEngine) controllers.actionEngine.commitChmod(mode) }
  }

  // ---------- Keyboard shortcuts help ----------
  ShortcutsHelp {
    anchors.fill: parent
    open: DialogsState.shortcutsHelpOpen
    bindings: controllers && controllers.keybindingResolver ? controllers.keybindingResolver.effectiveBindingsList() : []
    onRequestClose: DialogsState.shortcutsHelpOpen = false
  }

  // ---------- Recent notifications (V1.1) ----------
  NotificationHistory {
    anchors.fill: parent
    open: DialogsState.notificationHistoryOpen
    onRequestClose: DialogsState.notificationHistoryOpen = false
  }

  // ---------- Copy/move in progress + queued transfers (V1.1) ----------
  // One compact row per queued transfer/archive job (logic/ActionEngine.qml
  // _transferQueue), stacked above the active card so a queued paste/
  // extract is visible as "Pending" instead of only the "Queued: ..."
  // notification shown at the moment it was deferred (easy to miss/scroll
  // past). No per-item cancel yet -- first increment, see ARCHITECTURE.md.
  Column {
    id: actionBusyStack
    visible: ActionState.actionBusy
    width: Math.min(parent.width - 80, 420)
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.spacing.lg
    spacing: Style.spacing.xs
    z: 25

    Repeater {
      model: controllers && controllers.actionEngine ? controllers.actionEngine._transferQueue : []
      delegate: BorderSurface {
        width: actionBusyStack.width
        height: pendingLabel.implicitHeight + contentTopInset + contentBottomInset
        radius: Style.cornerRadius
        color: Color.menu.background
        borderSpec: Border.flat(Color.menu.border, Style.normalBorderWidth)
        padding: Style.spacing.sm
        opacity: 0.7

        Row {
          anchors.fill: parent
          anchors.topMargin: parent.contentTopInset
          anchors.rightMargin: parent.contentRightInset
          anchors.bottomMargin: parent.contentBottomInset
          anchors.leftMargin: parent.contentLeftInset
          spacing: Style.spacing.sm

          Text {
            id: pendingLabel
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - pendingTag.width - cancelQueuedButton.width - 2 * parent.spacing
            text: modelData.label
            font.pixelSize: Style.font.subtitle
            font.family: Style.font.family
            color: Color.menu.text
            elide: Text.ElideMiddle
          }

          Text {
            id: pendingTag
            anchors.verticalCenter: parent.verticalCenter
            text: "Pending"
            font.pixelSize: Style.font.subtitle
            font.family: Style.font.family
            color: Qt.darker(Color.menu.text, 2)
          }

          Button {
            id: cancelQueuedButton
            text: "Cancel"
            bordered: true
            anchors.verticalCenter: parent.verticalCenter
            Accessible.role: Accessible.Button
            Accessible.name: "Cancel queued: " + modelData.label
            onClicked: if (controllers && controllers.actionEngine) controllers.actionEngine.cancelQueuedJob(index)
          }
        }
      }
    }

    BorderSurface {
      id: actionBusyCard
      width: parent.width
      height: actionBusyColumn.implicitHeight + contentTopInset + contentBottomInset
      radius: Style.cornerRadius
      color: Color.menu.background
      borderSpec: Border.flat(Color.menu.border, Style.normalBorderWidth)
      padding: Style.spacing.sm

      Column {
        id: actionBusyColumn
        anchors.fill: parent
        anchors.topMargin: actionBusyCard.contentTopInset
        anchors.rightMargin: actionBusyCard.contentRightInset
        anchors.bottomMargin: actionBusyCard.contentBottomInset
        anchors.leftMargin: actionBusyCard.contentLeftInset
        spacing: Style.spacing.xs

        Row {
          id: actionBusyRow
          width: parent.width
          spacing: Style.spacing.sm

          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - cancelActionButton.width - parent.spacing
            text: ActionState.actionLabel + (ActionState.actionProgressPct >= 0 ? " " + Math.round(ActionState.actionProgressPct) + "%" : (root ? root.actionBusyDots : ""))
            font.pixelSize: Style.font.subtitle
            font.family: Style.font.family
            color: Color.menu.text
            // Middle-elide, not right-elide: a long/garbled filename (scene-
            // release names, multi-part archives) loses its extension and
            // any distinguishing tail entirely when cut from the right --
            // the middle keeps both ends readable.
            elide: Text.ElideMiddle
          }

          Button {
            id: cancelActionButton
            text: "Cancel"
            bordered: true
            anchors.verticalCenter: parent.verticalCenter
            Accessible.role: Accessible.Button
            Accessible.name: text
            onClicked: if (controllers && controllers.actionEngine) controllers.actionEngine.cancelAction()
          }
        }

        Rectangle {
          visible: ActionState.actionProgressPct >= 0
          width: parent.width
          // Thicker (was 3px) and darkened much further (2.5x -> 7x) so the
          // track reads as genuinely dark regardless of theme -- at 2.5x a
          // light menu.text lands on a MID gray, which can end up close in
          // perceived brightness to some accent colors. Distinguishing by
          // hue alone doesn't work for every viewer (reported: not visibly
          // moving, colorblind) -- contrast needs to hold on luminance too,
          // not just color.
          height: 6
          radius: height / 2
          color: Qt.darker(Color.menu.text, 7)
          border.width: 1
          border.color: Qt.darker(Color.menu.text, 4)

          Rectangle {
            // Math.max(height, ...): a rounded nub is visible from the very
            // first tick instead of an invisible sliver at low percentages.
            width: Math.max(parent.height, parent.width * (ActionState.actionProgressPct / 100))
            height: parent.height
            radius: height / 2
            color: Color.accent
            Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
          }
        }
      }
    }
  }

  Timer {
    running: ActionState.actionBusy
    repeat: true
    interval: 400
    onTriggered: {
      if (root) root.actionBusyDots = root.actionBusyDots.length >= 3 ? "" : root.actionBusyDots + "."
    }
  }

  // ---------- Open with... ----------
  OpenWithPanel {
    anchors.fill: parent
    open: PreviewState.openWithOpen
    entry: PreviewState.openWithEntry
    apps: PreviewState.openWithApps
    onCloseRequested: PreviewState.openWithOpen = false
    onAppSelected: function (appId) { if (commandFacade) commandFacade.launchWith(appId) }
  }

  // ---------- Context menu ----------
  ContextMenuPanel {
    anchors.fill: parent
    open: ContextMenuState.contextMenuOpen
    menuX: ContextMenuState.contextMenuX
    menuY: ContextMenuState.contextMenuY
    actions: ContextMenuState.contextMenuActions
    onCloseRequested: ContextMenuState.contextMenuOpen = false
  }

  ConfirmDialog {
    id: deleteConfirm
    anchors.fill: parent
    z: 10
    opened: ActionState.pendingDeleteNames.length > 0
    message: NavState.currentPath === Paths.trashDir
      ? (ActionState.pendingDeleteNames.length === 1
        ? "Delete \"" + ActionState.pendingDeleteNames[0] + "\" PERMANENTLY? This cannot be undone."
        : "Delete " + ActionState.pendingDeleteNames.length + " items PERMANENTLY? This cannot be undone.")
      : (ActionState.pendingDeleteNames.length === 1
        ? "Send \"" + ActionState.pendingDeleteNames[0] + "\" to trash?"
        : "Send " + ActionState.pendingDeleteNames.length + " items to trash?")
    confirmText: "Delete"
    cancelText: "Cancel"
    background: Color.menu.background
    foreground: Color.menu.text
    onCanceled: ActionState.pendingDeleteNames = []
    onConfirmed: if (controllers && controllers.actionEngine) controllers.actionEngine.confirmDelete()
  }

  ConfirmDialog {
    id: renameConflictConfirm
    anchors.fill: parent
    z: 10
    opened: ConflictState.renameConflictOpen
    message: ConflictState.pendingRename
      ? "\"" + ConflictState.pendingRename.newPath.substring(ConflictState.pendingRename.newPath.lastIndexOf("/") + 1) + "\" already exists here. Overwrite?"
      : ""
    confirmText: "Overwrite"
    cancelText: "Cancel"
    background: Color.menu.background
    foreground: Color.menu.text
    onCanceled: if (controllers && controllers.actionEngine) controllers.actionEngine.cancelPendingRename()
    onConfirmed: if (controllers && controllers.actionEngine) controllers.actionEngine.runPendingRename(true)
  }

  ConfirmDialog {
    id: newFileConflictConfirm
    anchors.fill: parent
    z: 10
    opened: ConflictState.newFileConflictOpen
    message: ConflictState.pendingNewFile
      ? "\"" + ConflictState.pendingNewFile.name + "\" already exists here. Overwrite?"
      : ""
    confirmText: "Overwrite"
    cancelText: "Cancel"
    background: Color.menu.background
    foreground: Color.menu.text
    onCanceled: if (controllers && controllers.actionEngine) controllers.actionEngine.cancelPendingNewFile()
    onConfirmed: if (controllers && controllers.actionEngine) controllers.actionEngine.runPendingNewFile(true)
  }

  ConfirmDialog {
    id: newFolderConflictConfirm
    anchors.fill: parent
    z: 10
    opened: ConflictState.newFolderConflictOpen
    message: ConflictState.pendingNewFolder
      ? "\"" + ConflictState.pendingNewFolder.name + "\" already exists here. Overwrite?"
      : ""
    confirmText: "Overwrite"
    cancelText: "Cancel"
    background: Color.menu.background
    foreground: Color.menu.text
    onCanceled: if (controllers && controllers.actionEngine) controllers.actionEngine.cancelPendingNewFolder()
    onConfirmed: if (controllers && controllers.actionEngine) controllers.actionEngine.runPendingNewFolder(true)
  }

  ConfirmDialog {
    id: extractConflictConfirm
    anchors.fill: parent
    z: 10
    opened: ConflictState.extractConflictOpen
    message: ConflictState.extractConflictNames.length === 1
      ? "\"" + ConflictState.extractConflictNames[0] + "\" already exists here and will be overwritten."
      : ConflictState.extractConflictNames.length + " items already exist here and will be overwritten."
    confirmText: "Overwrite"
    cancelText: "Cancel"
    background: Color.menu.background
    foreground: Color.menu.text
    onCanceled: if (controllers && controllers.actionEngine) controllers.actionEngine.cancelPendingExtract()
    onConfirmed: if (controllers && controllers.actionEngine) controllers.actionEngine.runPendingExtract()
  }

  ConfirmDialog {
    id: compressConflictConfirm
    anchors.fill: parent
    z: 10
    opened: ConflictState.compressConflictOpen
    message: ConflictState.pendingCompress ? "\"" + ConflictState.pendingCompress.archiveName + "\" already exists. Overwrite it?" : ""
    confirmText: "Overwrite"
    cancelText: "Cancel"
    background: Color.menu.background
    foreground: Color.menu.text
    onCanceled: if (controllers && controllers.actionEngine) controllers.actionEngine.cancelPendingCompress()
    onConfirmed: if (controllers && controllers.actionEngine) controllers.actionEngine.runPendingCompress()
  }

  ConfirmDialog {
    id: bulkRenameConflictConfirm
    anchors.fill: parent
    z: 10
    opened: ConflictState.bulkRenameConflictOpen
    message: ConflictState.bulkRenameConflictCount === 1
      ? "1 rename would collide with an existing name and will be skipped. Rename the rest?"
      : ConflictState.bulkRenameConflictCount + " renames would collide with existing or duplicate names and will be skipped. Rename the rest?"
    confirmText: "Continue"
    cancelText: "Cancel"
    background: Color.menu.background
    foreground: Color.menu.text
    onCanceled: if (controllers && controllers.actionEngine) controllers.actionEngine.cancelPendingBulkRename()
    onConfirmed: if (controllers && controllers.actionEngine) controllers.actionEngine.runPendingBulkRename()
  }

  // ---------- Paste conflict ----------
  ConflictResolveDialog {
    anchors.fill: parent
    open: ConflictState.pasteConflictOpen
    names: ConflictState.pasteConflictNames
    onOverwriteRequested: if (controllers && controllers.actionEngine) controllers.actionEngine.runPaste("overwrite")
    onSkipRequested: if (controllers && controllers.actionEngine) controllers.actionEngine.runPaste("skip")
    onCancelRequested: if (controllers && controllers.actionEngine) controllers.actionEngine.cancelPasteConflict()
  }

  // ---------- Drop conflict (drag & drop) ----------
  ConflictResolveDialog {
    anchors.fill: parent
    open: ConflictState.dropConflictOpen
    names: ConflictState.dropConflictNames
    onOverwriteRequested: if (controllers && controllers.actionEngine) controllers.actionEngine.runDrop("overwrite")
    onSkipRequested: if (controllers && controllers.actionEngine) controllers.actionEngine.runDrop("skip")
    onCancelRequested: if (controllers && controllers.actionEngine) controllers.actionEngine.cancelDropConflict()
  }

  // ---------- Command palette (: or Ctrl+P) ----------
  CommandPalettePanel {
    anchors.fill: parent
    open: PaletteState.paletteOpen
    query: PaletteState.paletteQuery
    index: PaletteState.paletteIndex
    commands: PaletteState.paletteOpen && commandFacade ? commandFacade.filteredPaletteCommands() : []
    onQueryEdited: function (text) { PaletteState.paletteQuery = text; PaletteState.paletteIndex = 0 }
    onCloseRequested: if (commandFacade) commandFacade.closePalette()
    onIndexRequested: function (idx) { PaletteState.paletteIndex = idx }
    onCommandActivated: function (idx) { if (commandFacade) commandFacade.runPaletteCommand(idx) }
    onFocusReturnRequested: list.forceActiveFocus()
  }
}

import QtQuick
import qs.Commons
import qs.Ui
import "../dialogs"
import "../state"

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
  property alias newFileConflictConfirm: newFileConflictConfirm
  property alias newFolderConflictConfirm: newFolderConflictConfirm
  property alias extractConflictConfirm: extractConflictConfirm
  property alias compressConflictConfirm: compressConflictConfirm
  property alias bulkRenameConflictConfirm: bulkRenameConflictConfirm

  // ---------- Bulk rename ----------
  BulkRenamePanel {
    anchors.fill: parent
    open: DialogsState.bulkRenameOpen
    selectedCount: SelectionState.selectedIndices.length
    pattern: DialogsState.bulkRenamePattern
    history: BookmarksState.bulkRenameHistory
    onCloseRequested: DialogsState.bulkRenameOpen = false
    onRenameRequested: function (pattern) {
      DialogsState.bulkRenamePattern = pattern
      if (controllers && controllers.actionEngine) controllers.actionEngine.commitBulkRename()
    }
    onFocusReturnRequested: list.forceActiveFocus()
  }

  // ---------- Connect to server ----------
  ConnectServer {
    anchors.fill: parent
    open: DialogsState.connectServerOpen
    connecting: DialogsState.networkConnecting
    uri: DialogsState.connectServerUri
    errorText: DialogsState.connectServerError

    authRequested: DialogsState.networkAuthRequested
    authMessage: DialogsState.networkAuthMessage
    authUser: DialogsState.networkAuthUser

    onConnectRequested: function (uri) {
      DialogsState.connectServerUri = uri
      if (controllers && controllers.mountOps) controllers.mountOps.commitConnectToServer()
    }

    onAuthSubmitted: function (user, password, remember) {
      DialogsState.networkConnecting = true
      Backend.NetworkResolver.submitAuth(user, password, remember)
    }

    onCancelConnectingRequested: if (controllers && controllers.mountOps) controllers.mountOps.cancelNetworkConnect()
    onCloseRequested: if (controllers && controllers.mountOps) controllers.mountOps.cancelConnectToServer()
    onFocusReturnRequested: list.forceActiveFocus()
  }

  // ---------- Permissions (chmod) ----------
  ChmodPanel {
    anchors.fill: parent
    open: ChmodState.chmodOpen
    names: ChmodState.chmodNames
    mixed: ChmodState.chmodMixed
    mode: ChmodState.chmodMode
    hasDir: ChmodState.chmodHasDir
    recursive: ChmodState.chmodRecursive
    onCloseRequested: ChmodState.chmodOpen = false
    onBitToggled: function (ownerIdx, bit) { if (controllers && controllers.actionEngine) controllers.actionEngine.toggleChmodBit(ownerIdx, bit) }
    onRecursiveToggled: ChmodState.chmodRecursive = !ChmodState.chmodRecursive
    onApplyRequested: function (mode) { if (controllers && controllers.actionEngine) controllers.actionEngine.commitChmod(mode) }
  }

  // ---------- Properties ----------
  PropertiesPanel {
    anchors.fill: parent
    open: PropertiesState.propertiesOpen
    multi: PropertiesState.propertiesMulti
    count: PropertiesState.propertiesCount
    entry: PropertiesState.propertiesEntry
    sizeLoading: PropertiesState.propertiesSizeLoading
    size: PropertiesState.propertiesSize
    perms: PropertiesState.propertiesPerms
    owner: PropertiesState.propertiesOwner
    mtime: PropertiesState.propertiesMtime
    onCloseRequested: PropertiesState.propertiesOpen = false
  }

  // ---------- Keyboard shortcuts help ----------
  ShortcutsHelp {
    anchors.fill: parent
    open: DialogsState.shortcutsHelpOpen
    onRequestClose: DialogsState.shortcutsHelpOpen = false
  }

  // ---------- Copy/move in progress ----------
  BorderSurface {
    id: actionBusyCard
    visible: ActionState.actionBusy
    width: Math.min(parent.width - 80, 420)
    height: actionBusyColumn.implicitHeight + contentTopInset + contentBottomInset
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.spacing.lg
    radius: Style.cornerRadius
    color: Color.menu.background
    borderSpec: Border.flat(Color.menu.border, Style.normalBorderWidth)
    padding: Style.spacing.sm
    z: 25

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
          elide: Text.ElideRight
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
        height: 3
        radius: height / 2
        color: Qt.darker(Color.menu.text, 2.5)

        Rectangle {
          width: parent.width * (ActionState.actionProgressPct / 100)
          height: parent.height
          radius: height / 2
          color: Color.accent
          Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
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
    opened: root && root.pendingDeleteNames && root.pendingDeleteNames.length > 0
    // The action uses the location captured when Delete was requested. Navigation
    // while this dialog is open must not change a reversible warning into a
    // permanent deletion (or the reverse).
    message: controllers && controllers.actionEngine && controllers.actionEngine.pendingDeletePermanent
      ? (root && root.pendingDeleteNames && root.pendingDeleteNames.length === 1
        ? "Delete \"" + root.pendingDeleteNames[0] + "\" PERMANENTLY? This cannot be undone."
        : "Delete " + (root && root.pendingDeleteNames ? root.pendingDeleteNames.length : 0) + " items PERMANENTLY? This cannot be undone.")
      : (root && root.pendingDeleteNames && root.pendingDeleteNames.length === 1
        ? "Send \"" + root.pendingDeleteNames[0] + "\" to trash?"
        : "Send " + (root && root.pendingDeleteNames ? root.pendingDeleteNames.length : 0) + " items to trash?")
    confirmText: "Delete"
    cancelText: "Cancel"
    background: Color.menu.background
    foreground: Color.menu.text
    onCanceled: if (root) { root.pendingDeleteNames = []; root.pendingDeleteEntries = [] }
    onConfirmed: if (controllers && controllers.actionEngine) controllers.actionEngine.confirmDelete()
  }

  ConfirmDialog {
    id: newFileConflictConfirm
    anchors.fill: parent
    z: 10
    opened: ConflictState.newFileConflictOpen
    message: ConflictState.pendingNewFile
      ? "\"" + ConflictState.pendingNewFile.name + "\" already exists. A new file cannot replace it."
      : ""
    confirmText: "Close"
    cancelText: "Cancel"
    background: Color.menu.background
    foreground: Color.menu.text
    onCanceled: if (controllers && controllers.actionEngine) controllers.actionEngine.cancelPendingNewFile()
    onConfirmed: if (controllers && controllers.actionEngine) controllers.actionEngine.cancelPendingNewFile()
  }

  ConfirmDialog {
    id: newFolderConflictConfirm
    anchors.fill: parent
    z: 10
    opened: ConflictState.newFolderConflictOpen
    message: ConflictState.pendingNewFolder
      ? "\"" + ConflictState.pendingNewFolder.name + "\" already exists. A new folder cannot replace it."
      : ""
    confirmText: "Close"
    cancelText: "Cancel"
    background: Color.menu.background
    foreground: Color.menu.text
    onCanceled: if (controllers && controllers.actionEngine) controllers.actionEngine.cancelPendingNewFolder()
    onConfirmed: if (controllers && controllers.actionEngine) controllers.actionEngine.cancelPendingNewFolder()
  }

  ConfirmDialog {
    id: extractConflictConfirm
    anchors.fill: parent
    z: 10
    opened: ConflictState.extractConflictOpen
    message: ConflictState.extractConflictNames.length === 1
      ? "\"" + ConflictState.extractConflictNames[0] + "\" already exists and will be skipped. Extract the rest?"
      : ConflictState.extractConflictNames.length + " items already exist and will be skipped. Extract the rest?"
    confirmText: "Skip existing"
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
    message: ConflictState.pendingCompress ? "\"" + ConflictState.pendingCompress.archiveName + "\" already exists. Compression cannot replace it." : ""
    confirmText: "Close"
    cancelText: "Cancel"
    background: Color.menu.background
    foreground: Color.menu.text
    onCanceled: if (controllers && controllers.actionEngine) controllers.actionEngine.cancelPendingCompress()
    onConfirmed: if (controllers && controllers.actionEngine) controllers.actionEngine.cancelPendingCompress()
  }

  ConfirmDialog {
    id: bulkRenameConflictConfirm
    anchors.fill: parent
    z: 10
    opened: ConflictState.bulkRenameConflictOpen
    message: ConflictState.bulkRenameConflictCount === 1
      ? "1 rename has an existing or duplicate destination and will be skipped. Rename the eligible items?"
      : ConflictState.bulkRenameConflictCount + " renames have existing or duplicate destinations and will be skipped. Rename the eligible items?"
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

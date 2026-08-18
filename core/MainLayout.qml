import QtQuick
import qs.Commons
import qs.Ui
import "../panels"
import "../shared"
import "../state"

// MainLayout -- main visual tree of Omafiles.
Item {
  id: mainLayout

  property Item root
  property var controllers
  property var commandFacade
  property var dialogs
  property Timer gTimer

  property alias list: list
  BorderSurface {
    id: card
    anchors.fill: parent
    color: Color.menu.background
    borderSpec: Border.none()
    radius: Style.cornerRadius
    padding: Style.spacing.panelPadding

    Row {
      id: cardRow
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
      spacing: Style.spacing.panelGap

      // ---------- Sidebar: pinned shortcuts ----------
      Sidebar {
        id: sidebar
        width: 170
        height: parent.height
        bookmarks: BookmarksState.bookmarks
        recentFiles: BookmarksState.recentFiles
        mounts: MountsState.mounts
        networkMounts: MountsState.networkMounts
        currentPath: NavState.currentPath
        dropHoverPath: DropHoverState.dropHoverPath
        ejectingDevice: MountsState.ejectingDevice
        positionRelativeTo: card
        iconForBookmark: BookmarksState.iconForBookmark
        iconForMount: BookmarksState.iconForMount
        iconForNetworkMount: BookmarksState.iconForNetworkMount
        openContextMenu: commandFacade ? commandFacade.openContextMenu : null
        bookmarkActionsFor: commandFacade ? commandFacade.bookmarkActions : null
        mountActionsFor: commandFacade ? commandFacade.mountActions : null
        networkMountActionsFor: commandFacade ? commandFacade.networkMountActions : null
        onBookmarkOpened: function (bookmark) { if (commandFacade) commandFacade.openBookmark(bookmark) }
        onRecentOpened: function (item) { if (commandFacade) commandFacade.openRecent(item) }
        onRecentLaunched: function (item) { if (commandFacade) commandFacade.launchRecent(item) }
        onRecentRemoveRequested: function (path) { BookmarksState.removeRecent(path) }
        onRecentClearRequested: BookmarksState.clearRecent()
        onMountActivated: function (mount) {
          if (!mount.mounted) { if (controllers) controllers.mountOps.mountDevice(mount) }
          else { if (controllers) controllers.navController.navigateTo(mount.path) }
        }
        onMountEjectRequested: function (mount) { if (controllers) controllers.mountOps.ejectMount(mount) }
        onNetworkMountOpened: function (mount) { if (controllers) controllers.navController.navigateTo(mount.path) }
        onConnectRequested: if (controllers) controllers.mountOps.startConnectToServer()
        onFilesDropped: function (drop, destPath) { if (controllers) controllers.actionEngine.handleFilesDropped(drop, destPath) }
        onDropHoverChanged: function (path) { DropHoverState.dropHoverPath = path }
      }

      Rectangle {
        width: Style.spacing.hairline
        height: parent.height
        color: Color.menu.border
        opacity: 0.15
      }

      // ---------- Main content ----------
      Column {
        id: mainColumn
        width: parent.width - sidebar.width - 1 - parent.spacing * 2
        height: parent.height
        spacing: Style.spacing.rowGap

        Item {
          id: panelsRow
          width: parent.width
          height: parent.height
          readonly property int panelCount: TabsState.tabs.length
          readonly property real interPanelGap: 2 * Style.spacing.panelGap + Style.spacing.hairline
          readonly property real slotWidth: (panelsRow.width - (panelCount - 1) * interPanelGap) / panelCount
          function slotX(i) { return i * (panelsRow.slotWidth + panelsRow.interPanelGap) }

          // ---------- Dividers between panels ----------
          Repeater {
            model: Math.max(0, TabsState.tabs.length - 1)
            delegate: Rectangle {
              required property int index
              x: panelsRow.slotX(index) + panelsRow.slotWidth + Style.spacing.panelGap
              y: 0
              width: Style.spacing.hairline
              height: panelsRow.height
              color: Color.menu.border
              opacity: 0.15
            }
          }

          // ---------- Background panels (all tabs except the active one) ----------
          Repeater {
            model: TabsState.tabs

            BackgroundPanel {
              hostRoot: root
              hostPanelsRow: panelsRow
              hostNavController: controllers ? controllers.navController : null
              hostCommandFacade: commandFacade
              hostVideoThumbs: controllers ? controllers.videoThumbs : null
              hostDragDropOps: controllers ? controllers.actionEngine : null
              hostFileMeta: controllers ? controllers.fileMeta : null
              hostTabOps: controllers ? controllers.tabOps : null
            }
          }

          // ---------- Active panel ----------
          Item {
            id: activePanel
            x: panelsRow.slotX(TabsState.activeTabIndex)
            y: 0
            width: panelsRow.slotWidth
            height: panelsRow.height

        Column {
          id: activeTop
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: Style.spacing.rowGap

        Row {
          id: navRow
          width: parent.width
          height: Style.spacing.controlHeight
          spacing: Style.spacing.controlGap

          PanelNavButtons {
            id: navButtons
            anchors.verticalCenter: parent.verticalCenter
            canGoBack: TabsState.navHistoryIndex > 0
            canGoForward: TabsState.navHistoryIndex < TabsState.navHistory.length - 1
            canGoUp: NavState.currentPath !== "/"
            onBackRequested: if (controllers) controllers.navController.navBack()
            onForwardRequested: if (controllers) controllers.navController.navForward()
            onUpRequested: if (controllers) controllers.navController.goUp()
          }

          Item {
            id: pathArea
            readonly property int minPathW: 120
            width: Math.max(minPathW, parent.width - navButtons.width - searchBar.width - 2 * Style.spacing.controlGap)
            height: parent.height

            MouseArea {
              anchors.fill: parent
              visible: !EditModeState.editingPath
              cursorShape: Qt.IBeamCursor
              onClicked: if (controllers) controllers.searchOps.startEditPath()
            }

            BreadcrumbSegments {
              id: breadcrumbRow
              visible: !EditModeState.editingPath
              anchors.fill: parent
              segments: commandFacade ? commandFacade.pathSegments() : []
              activePath: NavState.currentPath
            }

            PathCompletionField {
              id: pathField
              visible: EditModeState.editingPath
              anchors.fill: parent
              root: mainLayout.root
              navController: controllers ? controllers.navController : null
              list: list
            }
          }

          SearchBar {
            id: searchBar
            anchors.verticalCenter: parent.verticalCenter
            maxWidth: navRow.width - navButtons.width - pathArea.minPathW - 2 * Style.spacing.controlGap
            list: list
            searchOps: controllers ? controllers.searchOps : null
            navController: controllers ? controllers.navController : null
          }
        }

        ActivePanelInputRows {
          id: activeInputRows
          root: mainLayout.root
          list: list
          conflictActions: controllers ? controllers.actionEngine : null
        }

        Item {
          id: listContainer
          width: parent.width
          height: activePanel.height - navRow.height
            - (EditModeState.creatingFolder || EditModeState.creatingFile ? activeInputRows.height + mainColumn.spacing : 0)
            - (PickerState.active ? pickerBar.height : statusText.height) - mainColumn.spacing * (2 + (EditModeState.creatingFolder || EditModeState.creatingFile ? 1 : 0))

          ActiveFileList {
            id: list
            anchors.fill: parent
            root: mainLayout.root
            card: card
            controllers: mainLayout.controllers
            commandFacade: mainLayout.commandFacade
            dialogs: mainLayout.dialogs
            gTimer: mainLayout.gTimer
          }

        }
        } // end activeTop (Column)

            Text {
              id: statusText
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              visible: !PickerState.active
              text: NavState.visibleEntries.length + (NavState.visibleEntries.length === 1 ? " item" : " items")
                + (NavState.searchQuery ? " of " + NavState.entries.length : "")
                + (NavState.searchTruncated ? " · showing first 200" : "")
                + (!NavState.searchQuery && NavState.entries.length > 5000 ? " · large folder, may be slow" : "")
                + (SelectionState.selectedIndices.length > 1 ? " · " + SelectionState.selectedIndices.length + " selected" : "")
                + (ClipboardState.clipboardPaths.length > 0 ? " · clipboard: " + ClipboardState.clipboardPaths.length + (ClipboardState.clipboardPaths.length === 1 ? " item" : " items") + (ClipboardState.clipboardMode === "cut" ? " (cut)" : " (copied)") : "")
                + " · sort: " + SortState.sortLabel()
                + " · view: " + ViewState.viewLabel()
              font.pixelSize: Style.font.subtitle
              font.family: Style.font.family
              color: Color.menu.text
              opacity: Style.emphasis.secondary
            }

            FilePickerBar {
              id: pickerBar
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              visible: PickerState.active
              onResponseSubmitted: {
                root.close()
                root.requestClose()
              }
            }
          } // end activePanel (Item)
        } // end panelsRow (Item)
      }
    }

    MouseArea {
      x: cardRow.x + sidebar.width
      y: cardRow.y
      width: 2 * Style.spacing.panelGap + 1
      height: cardRow.height
      acceptedButtons: Qt.LeftButton
      onPressed: function (mouse) {
        var p = mapToItem(list.contentItem, mouse.x, mouse.y)
        var vp = mapToItem(list, mouse.x, mouse.y)
        SelectionState.startMarquee(p.x, p.y, vp.y, (mouse.modifiers & Qt.ControlModifier) !== 0)
      }
      onPositionChanged: function (mouse) {
        var p = mapToItem(list.contentItem, mouse.x, mouse.y)
        var vp = mapToItem(list, mouse.x, mouse.y)
        SelectionState.moveMarquee(p.x, p.y, vp.y, root.measuredRowHeight)
      }
      onReleased: SelectionState.endMarquee()
      onCanceled: SelectionState.endMarquee()
    }
  }

  Connections {
    target: mainLayout.root
    function onPickerSubmitRequested() {
      if (PickerState.active) {
        pickerBar.submit()
      }
    }
  }
}

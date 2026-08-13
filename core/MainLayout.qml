import QtQuick
import qs.Commons
import qs.Ui
import "../panels"
import "../shared"
import "../state"
import "../services"

// MainLayout -- main visual tree of Omafiles (Phase 11.B, josema:
// decompose the god object core/OmafilesContent.qml). The card
// (BorderSurface), the sidebar, the panel row (background + active with
// its navigation/breadcrumbs/inputs/list) and the MouseArea of the selection
// lasso that starts in the sidebar↔content gap. Deps injected
// explicitly (ActiveFileList pattern, not root.*). It exposes `list` as an
// alias because the controllers (NavigationController, SearchOps, TabOps,
// ArchiveActions) and DialogLayer reference it back.
Item {
  id: mainLayout

  property Item root
  property var actionEngine
  property var navController
  property var bookmarkOps
  property var mountOps
  property var dragDropOps
  property var videoThumbs
  property var fileMeta
  property var tabOps
  property var sortOps
  property var searchOps
  property var selectionOps
  property var conflictActions
  property var previewLoader
  property var fileOps
  property var renameOps
  property var clipboardOps
  property var deleteOps
  property var gTimer
  property var deleteConfirm
  property var renameConflictConfirm
  property var extractConflictConfirm
  property var compressConflictConfirm
  property var bulkRenameConflictConfirm
  property var newFileConflictConfirm
  property var newFolderConflictConfirm

  property alias list: list
  BorderSurface {
    id: card
    anchors.fill: parent
    color: Color.menu.background
    // No border of its own: Hyprland already draws the active/
    // inactive window border around the whole window (as in the rest of the
    // system's apps) -- a BorderSurface here would draw a second border, with
    // its own color, right next to Hyprland's. That IS needed in the real
    // Omarchy popups (audio, network...) because they are layer-shell and
    // Hyprland never decorates them; Omafiles is already a normal window.
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
        // A bit wider (Phase 20, josema): more space for the device
        // names (an ISO like "Mafia The Old" fits before truncating) and
        // room for the future eject button on the right.
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
        iconForBookmark: bookmarkOps.iconForBookmark
        iconFor: root.iconFor
        iconForMount: bookmarkOps.iconForMount
        iconForNetworkMount: bookmarkOps.iconForNetworkMount
        openContextMenu: root.openContextMenu
        bookmarkActionsFor: root.bookmarkActions
        mountActionsFor: root.mountActions
        networkMountActionsFor: bookmarkOps.networkMountActions
        onBookmarkOpened: function (bookmark) { root.openBookmark(bookmark) }
        onRecentOpened: function (item) { root.openRecent(item) }
        onRecentLaunched: function (item) { root.launchRecent(item) }
        onRecentRemoveRequested: function (path) { bookmarkOps.removeRecent(path) }
        onRecentClearRequested: bookmarkOps.clearRecent()
        onMountActivated: function (mount) {
          if (!mount.mounted) mountOps.mountDevice(mount)
          else root.navigateTo(mount.path)
        }
        onMountEjectRequested: function (mount) { mountOps.ejectMount(mount) }
        onNetworkMountOpened: function (mount) { root.navigateTo(mount.path) }
        onConnectRequested: mountOps.startConnectToServer()
        onFilesDropped: function (drop, destPath) { dragDropOps.handleFilesDropped(drop, destPath) }
        onDropHoverChanged: function (path) { DropHoverState.dropHoverPath = path }
      }

      Rectangle {
        width: Style.spacing.hairline
        height: parent.height
        color: Color.menu.border
        // Lowered from 0.3 to 0.15 -- same alpha that PanelSeparator
        // (Omarchy's real horizontal separator) uses for the same
        // conceptual role of "discreet dividing line". There is no real
        // vertical component to compare with, but there is no
        // reason for this line to be twice as strong as the
        // horizontal ones in the same file.
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
          // The gap between two panels carries panelGap ON EACH SIDE of the
          // divider (not panelGap split between the two) -- so that the
          // "inner" margin of a panel (toward the divider) is as wide
          // as the "outer" one (toward the sidebar or the window
          // edge), instead of half.
          readonly property real interPanelGap: 2 * Style.spacing.panelGap + Style.spacing.hairline
          readonly property real slotWidth: (panelsRow.width - (panelCount - 1) * interPanelGap) / panelCount
          function slotX(i) { return i * (panelsRow.slotWidth + panelsRow.interPanelGap) }

          // ---------- Dividers between panels ----------
          // A simple line, not a box with its own border -- same
          // style already used by the divider between the sidebar and the
          // content (Color.menu.border, opacity 0.15, Style.spacing.hairline).
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

          // ---------- Simple panels (all tabs except the active one) ----------
          // Generalization of what used to be a single fixed "split
          // view" panel -- now there is one per tab that is not the
          // active one, each with its own listing (its own Process,
          // child of the delegate). Deliberately simple: no selection
          // lasso nor its own context menu, only navigate with double
          // click and drag -- that's what it's for, the active panel (further
          // down) already has everything else.
          Repeater {
            model: TabsState.tabs

            BackgroundPanel {
              hostRoot: root
              hostPanelsRow: panelsRow
              hostVideoThumbs: videoThumbs
              hostDragDropOps: dragDropOps
              hostFileMeta: fileMeta
              hostTabOps: tabOps
              hostSortOps: sortOps
            }
          }

          // ---------- Active panel ----------
          // Everything that already existed (navigation bar, new
          // folder/file/search fields, the full list with selection
          // lasso/context menu/drag&drop/etc.) without touching its internal
          // logic -- only moved to its own slot within the panel
          // row, at the position of the active tab.
          Item {
            id: activePanel
            x: panelsRow.slotX(TabsState.activeTabIndex)
            y: 0
            width: panelsRow.slotWidth
            height: panelsRow.height

        // No background tint of its own in the active panel -- a wall-to-wall
        // Rectangle of Util.alpha(Color.accent, 0.08) was tried,
        // but josema found it ugly on hover (a color smear
        // over the whole panel). bgPanel's dimmed opacity:0.8 already
        // suffices by itself to tell which one is active, without
        // adding color on top.

        // navRow/listContainer/etc. go in their own inner Column instead
        // of directly in activePanel -- so statusText, outside of
        // it, can be anchored to parent.bottom (like bgStatusText)
        // and land on the exact same pixel in both types of panel.
        // Before, being the last child of the Column, its position came from
        // summing navRow+listContainer+margins -- a chain of real
        // numbers that didn't always match pixel by pixel the bottom:
        // parent.bottom of the background panels (a simple subtraction).
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
            onBackRequested: root.navBack()
            onForwardRequested: root.navForward()
            onUpRequested: root.goUp()
          }

          Item {
            id: pathArea
            // Shrinks when expanding the search, but never below a minimum:
            // the path/breadcrumb is ALWAYS visible (truncated), never
            // hidden. searchBar stays fixed to the right because it's the last
            // child of the Row and pathArea absorbs the width change.
            readonly property int minPathW: 120
            width: Math.max(minPathW, parent.width - navButtons.width - searchBar.width - 2 * Style.spacing.controlGap)
            height: parent.height

            MouseArea {
              // Behind the breadcrumbs: click on empty space -> edit path by hand.
              anchors.fill: parent
              visible: !EditModeState.editingPath
              cursorShape: Qt.IBeamCursor
              onClicked: searchOps.startEditPath()
            }

            BreadcrumbSegments {
              id: breadcrumbRow
              visible: !EditModeState.editingPath
              anchors.fill: parent
              segments: root.pathSegments()
              activePath: NavState.currentPath
            }

            PathCompletionField {
              id: pathField
              visible: EditModeState.editingPath
              anchors.fill: parent
              root: mainLayout.root
              list: list
            }
          }

          // Expandable search magnifier (Phase 19): last child of navRow,
          // stuck to the right edge. maxWidth = what's left after reserving the
          // breadcrumb's minimum, so the path never disappears.
          SearchBar {
            id: searchBar
            anchors.verticalCenter: parent.verticalCenter
            maxWidth: navRow.width - navButtons.width - pathArea.minPathW - 2 * Style.spacing.controlGap
            list: list
            searchOps: mainLayout.searchOps
            navController: mainLayout.navController
            selectionOps: mainLayout.selectionOps
          }
        }

        ActivePanelInputRows {
          id: activeInputRows
          // RHS qualified with mainLayout.* (Phase 11.B): these deps are
          // properties of MainLayout, not ids -- without qualifying, `root: root`
          // self-references the root property of ActivePanelInputRows
          // itself (binding loop -> null). `list` is an id.
          root: mainLayout.root
          list: list
          conflictActions: mainLayout.conflictActions
        }

        Item {
          id: listContainer
          width: parent.width
          // Without the "- Style.spacing.hairline" it used to have: that
          // single extra pixel made list.height end up 1px below
          // bgList.height (same formula, but bgList derives it
          // from real anchors, without that fudge). In a list with
          // rows it wasn't noticeable (it only changes the margin under the last
          // row), but the empty state, centered in the total height,
          // amplified that single pixel into a visible mismatch when
          // switching between active/background panel.
          // The three rows of activeInputRows are mutually exclusive
          // (see the component's own comment) -- their height already IS
          // that of the single visible row, or 0 if none is, so
          // a single term suffices instead of summing the three separately.
          height: activePanel.height - navRow.height
            - (EditModeState.creatingFolder || EditModeState.creatingFile ? activeInputRows.height + mainColumn.spacing : 0)
            - (PickerState.active ? pickerBar.height : statusText.height) - mainColumn.spacing * (2 + (EditModeState.creatingFolder || EditModeState.creatingFile ? 1 : 0))

          ActiveFileList {
            id: list
            anchors.fill: parent
            // RHS qualified with mainLayout.* (Phase 11.B): they are properties of
            // MainLayout, not ids -- without qualifying each `X: X`
            // self-references the homonymous property of ActiveFileList itself
            // (binding loop -> null). `card` and `list` are ids. The seven
            // ConfirmDialog are received by MainLayout from root (before they pointed to
            // `dialogLayer`, which doesn't exist in this scope).
            root: mainLayout.root
            card: card
            actionEngine: mainLayout.actionEngine
            navController: mainLayout.navController
            gTimer: mainLayout.gTimer
            previewLoader: mainLayout.previewLoader
            conflictActions: mainLayout.conflictActions
            mountOps: mainLayout.mountOps
            fileOps: mainLayout.fileOps
            videoThumbs: mainLayout.videoThumbs
            renameOps: mainLayout.renameOps
            clipboardOps: mainLayout.clipboardOps
            dragDropOps: mainLayout.dragDropOps
            searchOps: mainLayout.searchOps
            fileMeta: mainLayout.fileMeta
            deleteOps: mainLayout.deleteOps
            tabOps: mainLayout.tabOps
            selectionOps: mainLayout.selectionOps
            sortOps: mainLayout.sortOps
            deleteConfirm: mainLayout.deleteConfirm
            renameConflictConfirm: mainLayout.renameConflictConfirm
            extractConflictConfirm: mainLayout.extractConflictConfirm
            compressConflictConfirm: mainLayout.compressConflictConfirm
            bulkRenameConflictConfirm: mainLayout.bulkRenameConflictConfirm
            newFileConflictConfirm: mainLayout.newFileConflictConfirm
            newFolderConflictConfirm: mainLayout.newFolderConflictConfirm
          }

        }
        } // end activeTop (Column)
            // ---------- Status bar ----------
            // Inside the active panel, not as a global sibling of
            // panelsRow -- before it always ended up below the left
            // column even though the information was of the right
            // tab, something josema noticed as misaligned. Outside
            // activeTop and anchored to activePanel.bottom (like
            // bgStatusText) so it lands on the exact same pixel.
            Text {
              id: statusText
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              visible: !PickerState.active
              text: NavState.visibleEntries.length + (NavState.visibleEntries.length === 1 ? " item" : " items")
                + (NavState.searchQuery ? " of " + NavState.entries.length : "")
                + (NavState.searchTruncated ? " · showing first 200" : "")
                // No cap on the folder itself (unlike the
                // search) -- cutting a normal listing to the first N
                // would break real file management for large
                // folders (node_modules, package caches...). Only an
                // informative notice that it may be slow, not a limit.
                + (!NavState.searchQuery && NavState.entries.length > 5000 ? " · large folder, may be slow" : "")
                + (SelectionState.selectedIndices.length > 1 ? " · " + SelectionState.selectedIndices.length + " selected" : "")
                + (ClipboardState.clipboardPaths.length > 0 ? " · clipboard: " + ClipboardState.clipboardPaths.length + (ClipboardState.clipboardPaths.length === 1 ? " item" : " items") + (ClipboardState.clipboardMode === "cut" ? " (cut)" : " (copied)") : "")
                + " · sort: " + sortOps.sortLabel()
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
              selectionOps: mainLayout.selectionOps
              onResponseSubmitted: function(requestId, responseCode, results) {
                var resultsJson = JSON.stringify(results)
                Detached.run([
                  "dbus-send",
                  "--session",
                  "--type=method_call",
                  "--dest=org.freedesktop.impl.portal.desktop.omafiles",
                  "/org/freedesktop/portal/desktop",
                  "org.freedesktop.impl.portal.desktop.omafiles.SubmitResponse",
                  "string:" + requestId,
                  "uint32:" + responseCode,
                  "string:" + resultsJson
                ])
                root.close()
                root.requestClose()
              }
            }
          } // end activePanel (Item)
        } // end panelsRow (Item)
      }
    }

    // The selection lasso must also be able to start in the gap between
    // the sidebar and the content -- `cardRow` is a Row with
    // `spacing: Style.spacing.panelGap` on each side of the vertical
    // separator, and that spacing belongs to no child (neither sidebar nor
    // mainColumn cover it), so no MouseArea inside
    // `listContainer` reaches there no matter how the z-order is adjusted.
    // `mapToItem` instead of manual arithmetic with list.y/contentY --
    // we've already gotten those calculations wrong by hand before.
    MouseArea {
      x: cardRow.x + sidebar.width
      y: cardRow.y
      width: 2 * Style.spacing.panelGap + 1
      height: cardRow.height
      acceptedButtons: Qt.LeftButton
      onPressed: function (mouse) {
        var p = mapToItem(list.contentItem, mouse.x, mouse.y)
        var vp = mapToItem(list, mouse.x, mouse.y)
        selectionOps.startMarquee(p.x, p.y, vp.y, (mouse.modifiers & Qt.ControlModifier) !== 0)
      }
      onPositionChanged: function (mouse) {
        var p = mapToItem(list.contentItem, mouse.x, mouse.y)
        var vp = mapToItem(list, mouse.x, mouse.y)
        selectionOps.moveMarquee(p.x, p.y, vp.y)
      }
      onReleased: selectionOps.endMarquee()
      onCanceled: selectionOps.endMarquee()
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

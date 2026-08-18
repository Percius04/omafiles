import QtQuick
import qs.Commons
import qs.Ui
import "../shared"
import "../logic"
import "../state"
import "../shared/Utils.js" as Utils

// The main ListView of the active panel (lasso selection, drag and
// drop, keyboard shortcuts, inline rename, per-row context menu) +
// everything around it within listContainer (separator, mouse wheel,
// lasso gutters, empty state, visual lasso rectangle, preview)
// -- twenty-first component extracted from core, and the
// largest so far. listContainer stays in core with its height
// calculation (pixel-tuned, see its own comments) intact; this
// component only paints its content with anchors.fill: parent.
//
// The inner ListView was renamed from "list" to "listView" (with id: list
// there would be no way to give the SAME id "list" to the instance of this
// component without colliding) -- but dozens of sites in core
// (root functions, other dialogs with onFocusReturnRequested, the
// MouseArea of the side gap between sidebar and mainColumn) still
// write `list.contentY`/`list.forceActiveFocus()`/etc. by direct
// id, and changing all those call sites would have been much more
// risky than resolving it here: the instance of this component is still
// called "list" in core (same id as always), and these aliases +
// shadow functions re-expose exactly the subset of the ListView API that
// is used from outside (contentY/originY/contentHeight/contentItem,
// forceActiveFocus()/positionViewAtBeginning()) -- nothing more, it's not a
// generic ListView wrapper.
Item {
  property Item root: null
  property Item card: null
  property var controllers: null
  property var commandFacade: null
  property var dialogs: null
  property Timer gTimer: null

  property alias contentY: listView.contentY
  property alias originY: listView.originY
  property alias contentHeight: listView.contentHeight
  property alias contentItem: listView.contentItem
  function forceActiveFocus() { listView.forceActiveFocus() }
  function positionViewAtBeginning() { listView.positionViewAtBeginning() }
  function positionViewAtIndex(index, mode) { listView.positionViewAtIndex(index, mode) }
  // Index of the first visible row (to save/restore scroll by
  // index when switching tabs). x=4 hits the first cell in icon
  // view and still sits on the row in list/table.
  function firstVisibleIndex() { return listView.indexAt(4, listView.contentY + 4) }
  // SUB-ROW offset: how many pixels the top row is shifted up
  // relative to the viewport edge.
  function firstVisibleOffset() {
    var idx = firstVisibleIndex()
    if (idx < 0) return 0
    var it = listView.itemAtIndex(idx)
    return it ? (listView.contentY - it.y) : 0
  }
  // Positions row `idx` reproducing the EXACT sub-row offset.
  function positionAtIndexWithOffset(idx, offset) {
    listView.forceLayout()
    listView.positionViewAtIndex(idx, GridView.Beginning)
    var it = listView.itemAtIndex(idx)
    if (it) listView.contentY = it.y + offset
  }

  FontMetrics { id: listNameFM; font.family: Style.font.family; font.pixelSize: Style.font.title; font.weight: Font.Medium }
  FontMetrics { id: listMetaFM; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
  readonly property int listRowInnerH: Math.max(Style.spacing.controlHeight,
    Math.ceil(listNameFM.height) + Style.spacing.xs + Math.ceil(listMetaFM.height))
  readonly property int tableRowInnerH: Math.max(Style.spacing.controlHeight, Math.ceil(listNameFM.height))
  readonly property int listCellH: listRowInnerH + Style.spacing.md * 2
  readonly property int tableCellH: tableRowInnerH + Style.spacing.sm * 2
  readonly property int gridIconS: Style.space(ViewState.gridIconPx)
  readonly property int gridCellH: gridIconS + Style.spacing.sm + Math.ceil(listNameFM.height) * 2 + Style.spacing.md * 2
  readonly property int gridMinCellW: Style.space(ViewState.gridCellWidthPx)
  readonly property int gridCols: ViewState.columnsForWidth(listView.width, gridMinCellW)
  readonly property int gridCellW: ViewState.cellWidthFor(listView.width, gridMinCellW)
  onGridColsChanged: ViewState.gridColumns = gridCols
  onGridCellWChanged: ViewState.gridCellWidth = gridCellW
  onGridCellHChanged: ViewState.gridCellHeight = gridCellH

  KeyboardShortcuts {
    id: keyboardShortcuts
    hostRoot: root
    hostControllers: controllers
    hostCommandFacade: commandFacade
    hostDialogs: dialogs
    hostListView: listView
    hostGTimer: gTimer
  }

            // Same line that separates header and list in the background
            // panels (bgHeaderSep) -- it goes in here, not as a sibling in the
            // Column, so the gap between separator and list is the
            // same Style.spacing.sm as there and not the mainColumn.spacing
            // (wider) that the Column puts between ANY pair of children.
            PanelSeparator {
              id: listSep
              anchors.top: parent.top
              foreground: Color.menu.text
              strength: 0.15
            }

            FileTableHeader {
              id: tableHeader
              visible: ViewState.isTable
              anchors.top: listSep.bottom
              anchors.left: parent.left
              width: listView.width
              height: visible ? implicitHeight : 0
            }

            MouseArea {
              // Behind the list: right click on empty space -> general context menu.
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              width: PreviewState.previewOpen ? parent.width * 0.55 : parent.width
              acceptedButtons: Qt.RightButton
              onClicked: function (mouse) {
                var pos = mapToItem(card, mouse.x, mouse.y)
                if (commandFacade) commandFacade.openContextMenu(pos.x, pos.y, commandFacade.emptyAreaActions())
              }
            }

            // Behind the list: dropping here (from another app, or an internal
            // drag onto empty space instead of over a row) puts
            // the files in the folder open right now.
            DropArea {
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              width: PreviewState.previewOpen ? parent.width * 0.55 : parent.width
              keys: ["text/uri-list"]
              onEntered: function (drag) { drag.accepted = true }
              onDropped: function (drop) {
                if (controllers && controllers.actionEngine) controllers.actionEngine.handleFilesDropped(drop, NavState.currentPath)
              }
            }

            // Mouse wheel: with `listView.interactive` false (so that
            // dragging never scrolls, only draws the lasso), Flickable
            // stops processing the wheel too -- it's reimplemented here by
            // hand.
            MouseArea {
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              width: PreviewState.previewOpen ? parent.width * 0.55 : parent.width
              property real wheelAccumulator: 0
              onWheel: function (wheel) {
                var step = Util.wheelSteps(wheelAccumulator, wheel.angleDelta.y)
                wheelAccumulator = step.remainder
                if (step.steps === 0) return
                var minY = listView.originY
                var maxY = minY + Math.max(0, listView.contentHeight - listView.height)
                listView.contentY = Math.max(minY, Math.min(maxY, listView.contentY - step.steps * 60))
              }
            }

            // Behind the ListView, top gap marquee catcher
            MarqueeCatcher {
              id: marqueeArea
              anchors.top: parent.top
              height: listView.y
              anchors.left: parent.left
              width: PreviewState.previewOpen ? parent.width * 0.55 : parent.width
              catcherListView: listView
              measuredRowHeight: root.measuredRowHeight
            }

            GridView {
              id: listView
              anchors.top: tableHeader.bottom
              anchors.topMargin: ViewState.isTable ? Style.spacing.xs : Style.spacing.md
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              width: PreviewState.previewOpen ? parent.width * 0.55 : parent.width
              clip: true
              model: NavState.visibleEntries
              focus: root && root.opened && !NavState.searching
              cellWidth: ViewState.isGrid ? gridCellW : Math.max(1, width)
              cellHeight: ViewState.isGrid ? gridCellH : (ViewState.isTable ? tableCellH : listCellH)
              flow: GridView.LeftToRight
              keyNavigationEnabled: false
              highlightFollowsCurrentItem: false
              onModelChanged: {
                if (root && root.suppressListFade) return
                listRepopulateFade.restart()
              }
              NumberAnimation {
                id: listRepopulateFade
                target: listView
                property: "opacity"
                from: 0
                to: 1
                duration: 140
                easing.type: Easing.OutCubic
              }
              interactive: false
              boundsBehavior: Flickable.StopAtBounds

              footer: Item {
                id: listFooter
                width: listView.width
                height: 400

                MarqueeCatcher {
                  anchors.fill: parent
                  catcherListView: listView
                  measuredRowHeight: root.measuredRowHeight
                }
              }

              Timer {
                interval: 16
                repeat: true
                running: SelectionState.marqueeActive && listView.contentHeight > listView.height
                  && (SelectionState.marqueeViewportY < 32 || SelectionState.marqueeViewportY > listView.height - 32)
                onTriggered: {
                  var minY = listView.originY
                  var maxY = minY + Math.max(0, listView.contentHeight - listView.height)
                  var step = 18
                  if (SelectionState.marqueeViewportY < 32) {
                    listView.contentY = Math.max(minY, listView.contentY - step)
                    SelectionState.marqueeCurrentY = listView.contentY
                  } else {
                    listView.contentY = Math.min(maxY, listView.contentY + step)
                    SelectionState.marqueeCurrentY = listView.contentY + listView.height
                  }
                  if (true) SelectionState.updateMarqueeSelection(SelectionState.marqueeAdditive, SelectionState.marqueeBaseSelection)
                }
              }

              Keys.onPressed: function (event) { keyboardShortcuts.handlePress(event) }

              delegate: FileListRow {
                hostRoot: root
                hostListView: listView
                hostCard: card
                hostNavController: controllers ? controllers.navController : null
                hostCommandFacade: commandFacade
                hostDragDropOps: controllers ? controllers.actionEngine : null
                hostVideoThumbs: controllers ? controllers.videoThumbs : null
                hostFileMeta: controllers ? controllers.fileMeta : null
                hostConflictActions: controllers ? controllers.actionEngine : null
              }
            }

            // Notice when list-dir.sh could not list currentPath --
            // before this looked just like a truly empty folder, without
            // any hint that the problem was permissions.
            Text {
              // Same anchor and margin as the background panel's error notice
              // (bgErrorText): right under the header separator, at
              // Style.spacing.md -- where the first row would start. Before
              // this one went to parent.top + lg and the background one to separator + sm, so
              // the same error appeared in two different places depending on the panel
              // (Visual Sprint 3, C-05).
              visible: NavState.currentPathError !== ""
              anchors.top: tableHeader.visible ? tableHeader.bottom : listSep.bottom
              anchors.topMargin: Style.spacing.md
              // No leftMargin: it aligns with the ICON COLUMN (the glyph
              // starts at the content edge), not with the names one -- the
              // notice has no glyph, so it takes its place.
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.rowPaddingX
              // It occupies the icon's height (controlHeight) and centers the text
              // vertically, to stay at the HEIGHT of the glyph (which is
              // controlHeight and is centered in the row) instead of stuck to the
              // top, with the same top spacing as the rest.
              height: Style.spacing.controlHeight
              verticalAlignment: Text.AlignVCenter
              text: NavState.currentPathError
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
              color: Color.urgent
            }
            EmptyState {
              visible: root.loaded && NavState.currentPathError === "" && NavState.visibleEntries.length === 0
              centerOn: listView
              message: NavState.searchQuery
                ? "No results for “" + NavState.searchQuery + "”"
                : (NavState.currentPath === Paths.trashDir ? "Trash is empty" : "Folder is empty")
              subMessage: NavState.searchQuery
                ? "Try a broader search or check spelling"
                : (NavState.currentPath === Paths.trashDir ? "Deleted items will appear here" : "Drop files here to add them")
            }

            // Visual lasso rectangle -- after the ListView in the
            // file to stay on top when painting (visible even
            // when the lasso grows over already-drawn rows).
            Rectangle {
              visible: SelectionState.marqueeActive
              x: Math.min(SelectionState.marqueeStartX, SelectionState.marqueeCurrentX)
              y: Math.min(SelectionState.marqueeStartY, SelectionState.marqueeCurrentY) - listView.contentY + listView.y
              width: Math.abs(SelectionState.marqueeCurrentX - SelectionState.marqueeStartX)
              height: Math.abs(SelectionState.marqueeCurrentY - SelectionState.marqueeStartY)
              color: Util.alpha(Color.accent, 0.12)
              border.color: Color.accent
              border.width: 1
              z: 5
            }

            // ---------- Preview (Space) ----------
            PreviewPanel {
              anchors.fill: parent
              open: PreviewState.previewOpen
              entryName: PreviewContentState.previewEntry ? PreviewContentState.previewEntry.name : ""
              hasEntry: !!PreviewContentState.previewEntry
              isImageEntry: PreviewContentState.previewEntry ? Utils.isImage(PreviewContentState.previewEntry) : false
              isVideoEntry: PreviewContentState.previewEntry ? Utils.isVideo(PreviewContentState.previewEntry) : false
              isTextEntry: !!PreviewContentState.previewEntry && !Utils.isImage(PreviewContentState.previewEntry) && PreviewContentState.previewIsText
              isPdfEntry: PreviewContentState.previewEntry ? Utils.isPdf(PreviewContentState.previewEntry) : false
              isAudioEntry: PreviewContentState.previewEntry ? Utils.isAudio(PreviewContentState.previewEntry) : false
              imageSource: PreviewContentState.previewImage ? Util.fileUrl(PreviewContentState.previewImage) : ""
              videoThumbSource: {
                if (!PreviewContentState.previewEntry || !Utils.isVideo(PreviewContentState.previewEntry)) return ""
                var p = VideoThumbState.videoThumbReady[Utils.thumbKeyFor(PreviewContentState.previewEntry, NavState.currentPath)] || ""
                return p ? Util.fileUrl(p) : ""
              }
              highlightedText: PreviewContentState.previewHighlighted
              plainText: PreviewContentState.previewText
              pdfImageSource: PreviewContentState.previewPdfImage ? Util.fileUrl(PreviewContentState.previewPdfImage) : ""
              audioInfo: PreviewContentState.previewAudioInfo
              fallbackSizeText: PreviewContentState.previewEntry ? Utils.formatSize(PreviewContentState.previewEntry.size) : ""
            }
}

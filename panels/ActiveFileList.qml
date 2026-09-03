import QtQuick
import QtQuick.Controls
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

  // Whichever view is live for ViewState.mode -- every reference below
  // that used to hardcode `listView` for geometry/positioning now goes
  // through this instead, so the surrounding chrome (marquee, wheel
  // scroll, empty state, preview) works unchanged in both modes.
  readonly property Item activeView: ViewState.mode === "grid" ? fileGrid : listModeWrapper

  // contentY can't stay a `property alias` (an alias needs a FIXED
  // target, and activeView's target changes with ViewState.mode) but IS
  // written from outside (TabOps.qml/NavigationController.qml/SearchOps.qml/
  // ArchiveBrowser.qml all do `list.contentY = ...`) -- so it's a
  // read-only forwarding property for reads, and setContentY() is the
  // write path those call sites use instead. originY/contentHeight/
  // contentItem are never written externally (confirmed by grep), so a
  // plain forwarding property is enough for those three.
  readonly property real contentY: activeView.contentY
  readonly property real originY: activeView.originY
  readonly property real contentHeight: activeView.contentHeight
  readonly property Item contentItem: activeView.contentItem
  property alias keyboardShortcuts: keyboardShortcuts
  function setContentY(y) { activeView.contentY = y }
  function forceActiveFocus() { activeView.forceActiveFocus() }
  function positionViewAtBeginning() { activeView.positionViewAtBeginning() }
  function positionViewAtIndex(index, mode) { activeView.positionViewAtIndex(index, mode) }
  // Index of the first visible row (to save/restore scroll by
  // index when switching tabs).
  function firstVisibleIndex() { return activeView.indexAt(activeView.width / 2, activeView.contentY + 4) }
  // SUB-ROW offset: how many pixels the top row is shifted up
  // relative to the viewport edge.
  function firstVisibleOffset() {
    var idx = firstVisibleIndex()
    if (idx < 0) return 0
    var it = activeView.itemAtIndex(idx)
    return it ? (activeView.contentY - it.y) : 0
  }
  // Positions row `idx` reproducing the EXACT sub-row offset.
  function positionAtIndexWithOffset(idx, offset) {
    activeView.forceLayout()
    activeView.positionViewAtIndex(idx, ListView.Beginning)
    var it = activeView.itemAtIndex(idx)
    if (it) activeView.contentY = it.y + offset
  }

  KeyboardShortcuts {
    id: keyboardShortcuts
    hostRoot: root
    hostControllers: controllers
    hostCommandFacade: commandFacade
    hostDialogs: dialogs
    hostListView: activeView
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
              onEntered: function (drag) { if (!drag.hasUrls) drag.accepted = false }
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
              // Sits ABOVE the list (declared later in this parent) so
              // its onWheel reliably receives wheel events; no buttons so
              // it never swallows clicks/drags on the rows.
              acceptedButtons: Qt.NoButton
              z: 1
              property real wheelAccumulator: 0
              property real zoomAccumulator: 0
              onWheel: function (wheel) {
                // Ctrl+scroll resizes grid cells (Nautilus/Finder-style
                // icon zoom) instead of scrolling -- grid view only, plain
                // scroll is unaffected and unchanged in list mode.
                if ((wheel.modifiers & Qt.ControlModifier) && ViewState.mode === "grid") {
                  var zoomStep = Util.wheelSteps(zoomAccumulator, wheel.angleDelta.y)
                  zoomAccumulator = zoomStep.remainder
                  if (zoomStep.steps !== 0) ViewState.setCellWidth(ViewState.cellWidth + zoomStep.steps * 8)
                  return
                }
                var step = Util.wheelSteps(wheelAccumulator, wheel.angleDelta.y)
                wheelAccumulator = step.remainder
                if (step.steps === 0) return
                var minY = activeView.originY
                var maxY = minY + Math.max(0, activeView.contentHeight - activeView.height)
                activeView.contentY = Math.max(minY, Math.min(maxY, activeView.contentY - step.steps * 60))
              }
            }

            // Behind the ListView/GridView, top gap marquee catcher
            MarqueeCatcher {
              id: marqueeArea
              anchors.top: parent.top
              height: activeView.y
              anchors.left: parent.left
              width: PreviewState.previewOpen ? parent.width * 0.55 : parent.width
              catcherListView: activeView
              measuredRowHeight: root.measuredRowHeight
              marqueeTarget: SelectionState
            }

            // Marquee/wheel auto-scroll during a lasso drag near the top/
            // bottom edge -- a sibling of both views (not nested in
            // listView like before ViewState existed) so the SAME timer
            // drives auto-scroll for whichever view is active instead of
            // needing a duplicate inside ActiveFileGrid.qml too.
            Timer {
              interval: 16
              repeat: true
              running: SelectionState.marqueeActive && activeView.contentHeight > activeView.height
                && (SelectionState.marqueeViewportY < 32 || SelectionState.marqueeViewportY > activeView.height - 32)
              onTriggered: {
                var minY = activeView.originY
                var maxY = minY + Math.max(0, activeView.contentHeight - activeView.height)
                var step = 18
                if (SelectionState.marqueeViewportY < 32) {
                  activeView.contentY = Math.max(minY, activeView.contentY - step)
                  SelectionState.marqueeCurrentY = activeView.contentY
                } else {
                  activeView.contentY = Math.min(maxY, activeView.contentY + step)
                  SelectionState.marqueeCurrentY = activeView.contentY + activeView.height
                }
                SelectionState.updateMarqueeSelection(SelectionState.marqueeAdditive, SelectionState.marqueeBaseSelection)
              }
            }

            // Owns ONLY the list/grid mode crossfade (Ctrl+G) as a
            // separate opacity from listView's own -- listView already
            // animates ITS OWN opacity for listRepopulateFade below
            // (content changed, not mode), and an imperative
            // NumberAnimation targeting a property that also carries a
            // declarative `opacity: ... ; Behavior on opacity` binding
            // breaks that binding when it runs (QML property-assignment
            // semantics), so the two fought over the same property and
            // flickered. Splitting them onto two different Items removes
            // the conflict instead of trying to reconcile it in one.
            Item {
              id: listModeWrapper
              anchors.top: listSep.bottom
              anchors.topMargin: Style.spacing.md
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              width: PreviewState.previewOpen ? parent.width * 0.55 : parent.width
              // visible stays tied to opacity so the fading-out view stops
              // taking hover/clicks partway through instead of sitting
              // fully interactive-but-invisible underneath.
              opacity: ViewState.mode !== "grid" ? 1 : 0
              visible: opacity > 0
              Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

              // Same forwarding surface as ActiveFileGrid.qml's root, same
              // reason: `activeView` (above) treats this wrapper and
              // ActiveFileGrid interchangeably, so both need to answer the
              // same geometry/positioning calls. Fixed target (listView),
              // so plain aliases are safe here (no conditional-alias
              // problem -- that only applies to ActiveFileList's OWN
              // contentY/etc, which alternate between this wrapper and
              // fileGrid).
              property alias contentY: listView.contentY
              property alias originY: listView.originY
              property alias contentHeight: listView.contentHeight
              property alias contentItem: listView.contentItem
              function forceActiveFocus() { listView.forceActiveFocus() }
              function positionViewAtBeginning() { listView.positionViewAtBeginning() }
              function positionViewAtIndex(index, mode) { listView.positionViewAtIndex(index, mode) }
              function forceLayout() { listView.forceLayout() }
              function indexAt(x, y) { return listView.indexAt(x, y) }
              function itemAtIndex(index) { return listView.itemAtIndex(index) }

              ListView {
                id: listView
                anchors.fill: parent
                clip: true
                model: NavState.visibleEntries
                focus: root && root.opened && !NavState.searching && ViewState.mode !== "grid"
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

                ScrollBar.vertical: ScrollBar {
                  policy: listView.contentHeight > listView.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                  width: Style.space(8)
                  anchors.right: parent.right

                  contentItem: Rectangle {
                    implicitWidth: parent.width
                    implicitHeight: Math.max(26, parent.height * (listView.height / listView.contentHeight))
                    radius: parent.width / 2
                    color: Util.alpha(Color.foreground, 0.28)
                  }
                }

                footer: Item {
                  id: listFooter
                  width: listView.width
                  height: 400

                  MarqueeCatcher {
                    anchors.fill: parent
                    catcherListView: listView
                    measuredRowHeight: root.measuredRowHeight
                    marqueeTarget: SelectionState
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
            }

            ActiveFileGrid {
              id: fileGrid
              anchors.top: listSep.bottom
              anchors.topMargin: Style.spacing.md
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              width: PreviewState.previewOpen ? parent.width * 0.55 : parent.width
              opacity: ViewState.mode === "grid" ? 1 : 0
              visible: opacity > 0
              Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
              hostRoot: root
              hostCard: card
              hostControllers: controllers
              hostCommandFacade: commandFacade
              hostKeyboardShortcuts: keyboardShortcuts
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
              anchors.top: listSep.bottom
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
              centerOn: activeView
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
              // activeView.xOffset only exists on ActiveFileGrid.qml (its
              // GridView is centered, narrower than the panel) -- 0 for
              // listView, which has no such property, so list mode is
              // unaffected.
              x: Math.min(SelectionState.marqueeStartX, SelectionState.marqueeCurrentX) + (activeView.xOffset || 0)
              y: Math.min(SelectionState.marqueeStartY, SelectionState.marqueeCurrentY) - activeView.contentY + activeView.y
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
              // Real file path (not the thumbnail) fed straight to
              // QtMultimedia's MediaPlayer for inline playback (V1.1).
              videoSource: PreviewContentState.previewEntry && Utils.isVideo(PreviewContentState.previewEntry)
                ? Util.fileUrl(Utils.entryPath(NavState.currentPath, PreviewContentState.previewEntry)) : ""
              audioSource: PreviewContentState.previewEntry && Utils.isAudio(PreviewContentState.previewEntry)
                ? Util.fileUrl(Utils.entryPath(NavState.currentPath, PreviewContentState.previewEntry)) : ""
              highlightedText: PreviewContentState.previewHighlighted
              plainText: PreviewContentState.previewText
              pdfImageSource: PreviewContentState.previewPdfImage ? Util.fileUrl(PreviewContentState.previewPdfImage) : ""
              audioInfo: PreviewContentState.previewAudioInfo
              fallbackSizeText: PreviewContentState.previewEntry ? Utils.formatSize(PreviewContentState.previewEntry.size) : ""
            }
}

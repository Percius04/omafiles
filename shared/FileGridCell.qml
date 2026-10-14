import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import Omafiles.Backend as Backend
import "../shared"
import "../state"
import "../shared/Utils.js" as Utils
import "GitStatusColors.js" as GitStatusColors

// Grid-view delegate (icon/thumbnail on top, name below) -- the grid
// counterpart of panels/FileListRow.qml. Not a variant of FileRowVisual
// (that component's horizontal icon+2-line-text layout doesn't fit a
// vertical icon-over-name cell) and not a shared component with
// FileListRow itself, per this codebase's own established precedent:
// FileRowVisual is the one piece actually shared between the active and
// background panels; everything interaction-specific (drag/drop/lasso/
// rename) is duplicated per delegate by design (see FileListRow.qml's own
// header comment). host* prefix on every external property for the same
// reason as FileListRow.qml: a name matching an id in the instantiating
// file (root/hostGridView/card/...) would self-bind instead of taking the
// passed value.
CursorSurface {
  id: cellSurface
  required property var modelData
  required property int index

  property Item hostRoot: null
  property Item hostGridView: null
  property Item hostCard: null
  property Item hostNavController: null
  property Item hostCommandFacade: null
  property Item hostDragDropOps: null
  property Item hostVideoThumbs: null
  property Item hostFileMeta: null
  property Item hostConflictActions: null

  readonly property bool isDir: modelData.type === "dir"
  readonly property bool isBroken: modelData.link === "broken"

  // Thumbnail/icon slot scales with the cell (Ctrl+scroll, ActiveFileList.qml)
  // instead of a fixed 80px -- same proportions as the original 112-wide
  // default (80/112 slot, 96/112 sourceSize headroom, 44/112 glyph size).
  // Backend.ThumbnailProvider's cache tops out at 256px (requested below),
  // so sourceSize is capped there -- past that point the already-cached
  // asset is just displayed larger, not re-decoded at a bigger size.
  readonly property real thumbSlotSize: ViewState.cellWidth * (80 / 112)
  readonly property real thumbSourceSize: Math.min(256, ViewState.cellWidth * (96 / 112))
  readonly property real thumbGlyphSize: ViewState.cellWidth * (44 / 112)

  width: ViewState.cellWidth
  height: ViewState.cellHeight
  Accessible.role: Accessible.ListItem
  Accessible.name: modelData.name + (isDir ? ", folder" : ", file")
  Accessible.selected: SelectionState.isSelected(index)
  foreground: Commons.Color.menu.text
  accent: Commons.Color.accent
  hasCursor: mouseArea.containsMouse
  current: SelectionState.isSelected(index) || DropHoverState.dropHoverIndex === index

  DropArea {
    anchors.fill: parent
    enabled: isDir
    keys: ["text/uri-list"]
    onEntered: function (drag) {
      if (!drag.hasUrls) { drag.accepted = false; return }
      DropHoverState.dropHoverIndex = index
    }
    onExited: if (DropHoverState.dropHoverIndex === index) DropHoverState.dropHoverIndex = -1
    onDropped: function (drop) {
      DropHoverState.dropHoverIndex = -1
      hostDragDropOps.handleFilesDropped(drop, Utils.entryPath(NavState.currentPath, modelData))
    }
  }

  Item {
    id: cellContent
    anchors.fill: parent
    anchors.margins: Style.spacing.xs

    readonly property bool isVid: Utils.isVideo(modelData)
    readonly property string vidKey: isVid ? Utils.thumbKeyFor(modelData, NavState.currentPath) : ""
    readonly property string vidThumb: vidKey ? (VideoThumbState.videoThumbReady[vidKey] || "") : ""

    // Same 256px-cached-asset call as FileListRow.qml -- only the
    // displayed sourceSize differs (96 here vs 32 there), same
    // Backend.ThumbnailProvider cache, zero backend changes.
    readonly property string myPath: Utils.entryPath(NavState.currentPath, modelData)
    readonly property string gitStatus: cellSurface.isDir
      ? GitStatusState.statusForFolder(myPath) : GitStatusState.statusFor(myPath)
    readonly property bool wantsThumb: Utils.isImage(modelData) || Utils.isPdf(modelData)
      || modelData.name.toLowerCase().slice(-4) === ".svg"
    property string imgThumb: ""
    onMyPathChanged: {
      imgThumb = wantsThumb ? Backend.ThumbnailProvider.request(myPath, 256) : ""
      _requestCount(false)
    }
    Component.onCompleted: {
      if (isVid) hostVideoThumbs.requestVideoThumb(modelData)
      if (wantsThumb) imgThumb = Backend.ThumbnailProvider.request(myPath, 256)
      _requestCount(false)
    }

    readonly property bool _isDir: cellSurface.isDir
    function _requestCount(force) {
      if (!_isDir) return
      if (!force && !FolderCountState.needsRequest(myPath)) return
      FolderCountState.markPending(myPath)
      Backend.FolderCounter.request(myPath, NavState.showHidden)
    }

    Connections {
      target: Backend.ThumbnailProvider
      function onReady(path, thumbPath) {
        if (path === cellContent.myPath) cellContent.imgThumb = thumbPath
      }
    }

    Connections {
      target: NavState
      function onRefreshTickChanged() { cellContent._requestCount(true) }
    }

    Item {
      id: thumbSlot
      anchors.top: parent.top
      anchors.horizontalCenter: parent.horizontalCenter
      width: cellSurface.thumbSlotSize
      height: cellSurface.thumbSlotSize
      clip: true

      Image {
        id: thumbImage
        anchors.fill: parent
        visible: status === Image.Ready
        source: (cellContent.imgThumb ? Util.fileUrl(cellContent.imgThumb)
          : (cellContent.vidThumb ? Util.fileUrl(cellContent.vidThumb) : ""))
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        sourceSize.width: cellSurface.thumbSourceSize
        sourceSize.height: cellSurface.thumbSourceSize
      }

      OpticalGlyph {
        anchors.fill: parent
        visible: cellSurface.isDir && !cellSurface.isBroken
        text: "󰉋"
        fontFamily: Style.font.family
        fontSize: cellSurface.thumbGlyphSize
        color: cellSurface.current ? Commons.Color.menu.selectedText : Commons.Color.menu.text
      }

      OpticalGlyph {
        anchors.fill: parent
        visible: !cellSurface.isDir && !thumbImage.visible && !cellSurface.isBroken
        text: Utils.iconFor(modelData)
        fontFamily: Style.font.family
        fontSize: cellSurface.thumbGlyphSize
        color: cellSurface.current ? Commons.Color.menu.selectedText : Commons.Color.menu.text
      }

      // Same broken-symlink glyph as FileRowVisual.qml, already verified
      // against the icon font's cmap there.
      OpticalGlyph {
        anchors.fill: parent
        visible: cellSurface.isBroken
        text: "\u{F033A}"
        fontFamily: Style.font.family
        fontSize: cellSurface.thumbGlyphSize
        color: Commons.Color.urgent
      }

      // Same badge as FileRowVisual.qml (shared/GitStatusColors.js), scaled
      // slightly with the cell so it stays legible at larger Ctrl+scroll sizes.
      Rectangle {
        visible: cellContent.gitStatus.length > 0
        width: Math.max(8, cellSurface.thumbSlotSize * 0.12)
        height: width
        radius: width / 2
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        border.width: 1
        border.color: Commons.Color.background
        color: GitStatusColors.colorFor(cellContent.gitStatus, Commons.Color.urgent, Commons.Color.muted)
      }
    }

    Text {
      id: nameText
      visible: EditModeState.renamingIndex !== index
      anchors.top: thumbSlot.bottom
      anchors.topMargin: Style.spacing.xs
      anchors.left: parent.left
      anchors.right: parent.right
      horizontalAlignment: Text.AlignHCenter
      text: modelData.name + (cellSurface.isDir ? "/" : "")
      font.pixelSize: Style.font.bodySmall
      font.family: Style.font.family
      maximumLineCount: 2
      wrapMode: Text.Wrap
      elide: Text.ElideRight
      color: cellSurface.isBroken ? Commons.Color.urgent
        : (ClipboardState.clipboardMode === "cut" && ClipboardState.clipboardPaths.indexOf(cellContent.myPath) >= 0) ? Qt.darker(Commons.Color.menu.text, 1.6)
        : (cellSurface.current ? Commons.Color.menu.selectedText : Commons.Color.menu.text)
    }

    TextField {
      id: renameField
      visible: EditModeState.renamingIndex === index
      Accessible.role: Accessible.EditableText
      Accessible.name: "Rename"
      anchors.top: thumbSlot.bottom
      anchors.topMargin: Style.spacing.xs
      anchors.left: parent.left
      anchors.right: parent.right
      verticalPadding: 2
      horizontalAlignment: Text.AlignHCenter
      onVisibleChanged: if (visible) { text = modelData.name; forceActiveFocus(); selectAll() } else hostGridView.forceActiveFocus()
      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          hostConflictActions.commitRename(text)
          event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
          EditModeState.renamingIndex = -1
          event.accepted = true
        }
      }
    }
  }

  MouseArea {
    id: mouseArea
    // Inset on all 4 sides (not just left/right like FileListRow's row
    // strip) so the natural gap between grid cells stays lasso-catchable
    // without needing dedicated gutter MarqueeCatcher items per cell.
    anchors.fill: parent
    anchors.margins: 6
    hoverEnabled: true
    visible: EditModeState.renamingIndex !== index
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    drag.target: dragProxy
    drag.axis: Drag.XAndYAxis
    onPressed: function (mouse) {
      if (mouse.button === Qt.LeftButton && mouse.modifiers === Qt.NoModifier && !SelectionState.isSelected(index)) {
        SelectionState.selectOnly(index)
      }
      if (mouse.button === Qt.LeftButton) {
        cellContent.grabToImage(function (result) { dragProxy.Drag.imageSource = result.url })
      }
    }
    onClicked: function (mouse) {
      if (mouse.button === Qt.RightButton) {
        if (!SelectionState.isSelected(index)) SelectionState.selectOnly(index)
        var pos = mapToItem(hostCard, mouse.x, mouse.y)
        if (hostCommandFacade) hostCommandFacade.openContextMenu(pos.x, pos.y, hostCommandFacade.itemActions())
        return
      }
      if (mouse.modifiers & Qt.ControlModifier) SelectionState.toggleSelect(index)
      else if (mouse.modifiers & Qt.ShiftModifier) SelectionState.selectRange(index)
      else SelectionState.selectOnly(index)
    }
    onDoubleClicked: if ((!hostRoot || !hostRoot.hasPendingEdit) && hostNavController) hostNavController.enter(modelData)
  }

  Item {
    id: dragProxy
    width: 1
    height: 1
    Drag.active: mouseArea.drag.active
    Drag.dragType: Drag.Automatic
    Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
    Drag.proposedAction: Qt.MoveAction
    Drag.mimeData: hostDragDropOps.dragMimeDataFor(index)
  }
}

import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import Omafiles.Backend as Backend
import "../shared"
import "../state"
import "../shared/Utils.js" as Utils

// Grid-view delegate for the BACKGROUND panels (non-active tabs) -- the
// grid counterpart of panels/BackgroundListDelegate.qml, itself the
// counterpart of shared/FileGridCell.qml (the active panel's grid
// delegate). No SelectionState/lasso/rename here, mirroring
// BackgroundListDelegate.qml's own simpler interaction set exactly
// (background panels have never had a selection lasso or inline rename --
// only hover, double-click-to-navigate, and drag-source/drop-target).
CursorSurface {
  id: cellSurface
  required property var modelData
  required property int index
  property string panelPath: ""
  property bool bgSearching: false
  property Item hostDragDropOps: null
  property Item hostVideoThumbs: null
  property Item hostFileMeta: null
  property Item hostTabOps: null
  property Item hostNavController: null
  property int bgPanelIndex: -1

  readonly property bool isDir: modelData.type === "dir"
  readonly property bool isBroken: modelData.link === "broken"

  // Same Ctrl+scroll-proportional sizing as shared/FileGridCell.qml -- see
  // its comment for the ratios' origin.
  readonly property real thumbSlotSize: ViewState.cellWidth * (80 / 112)
  readonly property real thumbSourceSize: Math.min(256, ViewState.cellWidth * (96 / 112))
  readonly property real thumbGlyphSize: ViewState.cellWidth * (44 / 112)

  width: ViewState.cellWidth
  height: ViewState.cellHeight
  foreground: Commons.Color.menu.text
  accent: Commons.Color.accent
  hasCursor: mouseArea.containsMouse
  // Same 1/0.72 hover-compensation as BackgroundListDelegate.qml -- see
  // its comment for the full rationale (the whole background panel dims
  // to 0.72, this cancels that dimming only under the hovered cell).
  opacity: hasCursor ? 1 / 0.72 : 1
  current: false

  DropArea {
    anchors.fill: parent
    enabled: isDir
    keys: ["text/uri-list"]
    onEntered: function (drag) { if (!drag.hasUrls) drag.accepted = false }
    onDropped: function (drop) {
      if (hostDragDropOps) hostDragDropOps.handleFilesDropped(drop, Utils.entryPath(panelPath, modelData))
    }
  }

  Item {
    id: cellContent
    anchors.fill: parent
    anchors.margins: Style.spacing.xs

    readonly property bool isVid: Utils.isVideo(modelData)
    readonly property string vidKey: isVid ? Utils.thumbKeyFor(modelData, panelPath) : ""
    readonly property string vidThumb: vidKey ? (VideoThumbState.videoThumbReady[vidKey] || "") : ""

    readonly property string myPath: Utils.entryPath(panelPath, modelData)
    readonly property bool wantsThumb: Boolean(Utils.isImage(modelData) || Utils.isPdf(modelData)
      || (modelData.name && modelData.name.toLowerCase().slice(-4) === ".svg"))
    property string imgThumb: ""
    onMyPathChanged: {
      imgThumb = wantsThumb ? Backend.ThumbnailProvider.request(myPath, 256) : ""
      _requestCount(false)
    }
    Component.onCompleted: {
      if (isVid && hostVideoThumbs) hostVideoThumbs.requestVideoThumb(modelData, panelPath)
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
        color: Commons.Color.menu.text
      }

      OpticalGlyph {
        anchors.fill: parent
        visible: !cellSurface.isDir && !thumbImage.visible && !cellSurface.isBroken
        text: Utils.iconFor(modelData)
        fontFamily: Style.font.family
        fontSize: cellSurface.thumbGlyphSize
        color: Commons.Color.menu.text
      }

      OpticalGlyph {
        anchors.fill: parent
        visible: cellSurface.isBroken
        text: "\u{F033A}"
        fontFamily: Style.font.family
        fontSize: cellSurface.thumbGlyphSize
        color: Commons.Color.urgent
      }
    }

    Text {
      anchors.top: thumbSlot.bottom
      anchors.topMargin: Style.spacing.xs
      anchors.left: parent.left
      anchors.right: parent.right
      horizontalAlignment: Text.AlignHCenter
      text: (modelData.name || "") + (cellSurface.isDir ? "/" : "")
      font.pixelSize: Style.font.bodySmall
      font.family: Style.font.family
      maximumLineCount: 2
      wrapMode: Text.Wrap
      elide: Text.ElideRight
      color: cellSurface.isBroken ? Commons.Color.urgent : Commons.Color.menu.text
    }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    drag.target: dragProxy
    drag.axis: Drag.XAndYAxis
    onDoubleClicked: {
      if (bgSearching) {
        if (hostTabOps) hostTabOps.navigateTabTo(bgPanelIndex, cellSurface.isDir ? modelData.path : modelData.parent)
      } else if (cellSurface.isDir) {
        if (hostTabOps) hostTabOps.navigateTabTo(bgPanelIndex, Utils.joinPath(panelPath, modelData.name))
      } else {
        if (hostNavController) hostNavController.openWithDefault(Utils.entryPath(panelPath, modelData))
      }
    }
  }

  Item {
    id: dragProxy
    width: 1
    height: 1
    Drag.active: mouseArea.drag.active
    Drag.dragType: Drag.Automatic
    Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
    Drag.proposedAction: Qt.MoveAction
    Drag.mimeData: {
      var data = {}
      data["text/uri-list"] = Util.fileUrl(Utils.joinPath(panelPath, modelData.name))
      return data
    }
  }
}

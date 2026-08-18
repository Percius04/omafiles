import QtQuick
import qs.Commons
import qs.Ui
import Omafiles.Backend as Backend
import "../shared"
import "../state"
import "../shared/Utils.js" as Utils

CursorSurface {
  id: bgRowSurface

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
  property int cellWidth: 0
  property int cellHeight: 0

  width: cellWidth > 0 ? cellWidth : (parent ? parent.width : 0)
  implicitHeight: bgRowContent.implicitHeight + (ViewState.isTable ? Style.spacing.sm * 2 : Style.spacing.md * 2)
  foreground: Color.menu.text
  accent: Color.accent
  hasCursor: bgRowMouse.containsMouse
  // The hover fill/border is already semi-transparent on its own
  // (Style.hoverFillFor) -- the whole bgPanel goes to opacity:0.72 to
  // mark itself as "not the active panel", and without this that opacity is
  // multiplied ALSO over the hover, ending up doubly weak/
  // faded instead of the same look it has in the active panel.
  // 1/0.72 cancels exactly the parent's opacity only while this
  // specific row has the cursor over it.
  opacity: hasCursor ? 1 / 0.72 : 1

  DropArea {
    visible: modelData.type === "dir"
    anchors.fill: parent
    keys: ["text/uri-list"]
    onEntered: function (drag) { drag.accepted = true }
    onDropped: function (drop) {
      if (hostDragDropOps) hostDragDropOps.handleFilesDropped(drop, Utils.entryPath(panelPath, modelData))
    }
  }

  Item {
    id: bgRowContent
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: ViewState.isGrid ? Style.spacing.sm : 0
    anchors.rightMargin: ViewState.isGrid ? Style.spacing.sm : Style.spacing.rowPaddingX
    implicitHeight: ViewState.isGrid ? bgGridVisual.implicitHeight
      : (ViewState.isTable ? bgTableVisual.implicitHeight : bgFileRow.implicitHeight)

    readonly property bool isVid: Utils.isVideo(modelData)
    readonly property string vidKey: isVid ? Utils.thumbKeyFor(modelData, panelPath) : ""
    readonly property string vidThumb: vidKey ? (VideoThumbState.videoThumbReady[vidKey] || "") : ""

    // Native thumbnail (images/SVG/PDF) via ThumbnailProvider
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

    // Item counter: same as FileListRow, with THIS background
    // panel's path. The FolderCountState cache is global (per path).
    readonly property bool _isDir: modelData.type === "dir"
    function _requestCount(force) {
      if (!_isDir) return
      if (!force && !FolderCountState.needsRequest(myPath)) return
      FolderCountState.markPending(myPath)
      Backend.FolderCounter.request(myPath, NavState.showHidden)
    }

    Connections {
      target: Backend.ThumbnailProvider
      function onReady(path, thumbPath) {
        if (path === bgRowContent.myPath) bgRowContent.imgThumb = thumbPath
      }
    }

    Connections {
      target: NavState
      function onRefreshTickChanged() { bgRowContent._requestCount(true) }
    }

    FileRowVisual {
      id: bgFileRow
      visible: ViewState.isList
      anchors.fill: parent
      name: modelData.name || ""
      isDir: modelData.type === "dir"
      isBroken: modelData.link === "broken"
      fileIconGlyph: Utils.iconFor(modelData)
      thumbSource: bgRowContent.imgThumb ? Util.fileUrl(bgRowContent.imgThumb)
        : (bgRowContent.vidThumb ? Util.fileUrl(bgRowContent.vidThumb) : "")
      metaText: hostFileMeta ? hostFileMeta.metaFor(modelData, panelPath) : ""
      metaTooltip: hostFileMeta ? hostFileMeta.metaTooltipFor(modelData, panelPath) : ""
    }

    FileGridVisual {
      id: bgGridVisual
      visible: ViewState.isGrid
      anchors.fill: parent
      name: modelData.name || ""
      isDir: modelData.type === "dir"
      isBroken: modelData.link === "broken"
      fileIconGlyph: Utils.iconFor(modelData)
      thumbSource: bgRowContent.imgThumb ? Util.fileUrl(bgRowContent.imgThumb)
        : (bgRowContent.vidThumb ? Util.fileUrl(bgRowContent.vidThumb) : "")
    }

    FileTableVisual {
      id: bgTableVisual
      visible: ViewState.isTable
      anchors.fill: parent
      name: modelData.name || ""
      isDir: modelData.type === "dir"
      isBroken: modelData.link === "broken"
      fileIconGlyph: Utils.iconFor(modelData)
      thumbSource: bgRowContent.imgThumb ? Util.fileUrl(bgRowContent.imgThumb)
        : (bgRowContent.vidThumb ? Util.fileUrl(bgRowContent.vidThumb) : "")
      sizeText: hostFileMeta ? hostFileMeta.sizeTextFor(modelData, panelPath) : ""
      typeText: hostFileMeta ? hostFileMeta.typeTextFor(modelData) : ""
      dateText: hostFileMeta ? hostFileMeta.dateTextFor(modelData, panelPath) : ""
      sizeTooltip: hostFileMeta ? hostFileMeta.metaTooltipFor(modelData, panelPath) : ""
    }
  }

  MouseArea {
    id: bgRowMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    drag.target: bgDragProxy
    drag.axis: Drag.XAndYAxis
    onPressed: function (mouse) {
      if (mouse.button === Qt.LeftButton) DropHoverState.pointerDown = true
    }
    onReleased: DropHoverState.pointerDown = false
    onCanceled: DropHoverState.pointerDown = false
    onDoubleClicked: {
      if (bgSearching) {
        if (hostTabOps) hostTabOps.navigateTabTo(bgPanelIndex, modelData.type === "dir" ? modelData.path : modelData.parent)
      } else if (modelData.type === "dir") {
        if (hostTabOps) hostTabOps.navigateTabTo(bgPanelIndex, Utils.joinPath(panelPath, modelData.name))
      } else {
        if (hostNavController) hostNavController.openWithDefault(Utils.entryPath(panelPath, modelData))
      }
    }
  }

  Item {
    id: bgDragProxy
    width: 1
    height: 1
    Drag.active: bgRowMouse.drag.active
    Drag.dragType: Drag.Automatic
    Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
    Drag.proposedAction: Qt.MoveAction
    Drag.mimeData: {
      var data = {}
      data["text/uri-list"] = Util.fileUrl(Utils.joinPath(panelPath, modelData.name))
      return data
    }
    Drag.onActiveChanged: DropHoverState.dragActive = Drag.active
    Component.onDestruction: {
      if (Drag.active) DropHoverState.dragActive = false
      if (bgRowMouse.pressed) DropHoverState.pointerDown = false
    }
  }
}

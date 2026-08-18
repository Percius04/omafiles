import QtQuick
import qs.Commons
import qs.Ui
import Omafiles.Backend as Backend
import "../shared"
import "../state"
import "../shared/Utils.js" as Utils

// Row delegate of the main ListView (visual + drag/drop +
// inline rename + lasso gutters) -- second cut of
// panels/ActiveFileList.qml (761 lines, over the 300-500 limit),
// after the first one (Keys.onPressed -> logic/KeyboardShortcuts.qml).
// It's a delegate (equivalent to a Repeater), so the properties that
// come from outside are prefixed `host*` -- if they were named like an id
// of the file that instantiates this (root/listView/card/...), QML
// self-binds them instead of the passed value (see
// [[project_omafiles_architecture_rules]], same bug as BackgroundPanel.qml
// and, later, KeyboardShortcuts.qml itself despite NOT being a delegate).
CursorSurface {
  id: rowSurface
  required property var modelData
  required property int index

  property Item hostRoot: null
  property Item hostListView: null
  property Item hostCard: null
  property Item hostNavController: null
  property Item hostCommandFacade: null
  property Item hostDragDropOps: null
  property Item hostVideoThumbs: null
  property Item hostFileMeta: null
  property Item hostConflictActions: null

  width: hostListView.cellWidth
  implicitHeight: rowContent.implicitHeight + (ViewState.isTable ? Style.spacing.sm * 2 : Style.spacing.md * 2)
  Accessible.role: Accessible.ListItem
  Accessible.name: modelData.name + (modelData.type === "dir" ? ", folder" : ", file")
  Accessible.selected: SelectionState.isSelected(index)
  // When recycling delegates (recreates rows on scroll),
  // implicitHeight may pass through 0 for a frame before
  // the text layout settles -- if that transient
  // value is accepted, measuredRowHeight (shared by all
  // rows) is wrong for an instant, the footer recalculates its
  // height, contentHeight changes mid-scroll and that's exactly
  // what made the top gap grow on each cycle. All
  // rows measure the same, so keeping the maximum
  // seen is safe and never accepts a smaller transient value.
  onHeightChanged: {
    if (ViewState.isGrid) return
    if (hostRoot && height > hostRoot.measuredRowHeight) hostRoot.measuredRowHeight = height
  }
  foreground: Color.menu.text
  accent: Color.accent
  hasCursor: mouseArea.containsMouse
  current: SelectionState.isSelected(index) || DropHoverState.dropHoverIndex === index

  DropArea {
    // Only folders are a valid destination for a drop --
    // dropping onto a loose file makes no sense.
    anchors.fill: parent
    enabled: modelData.type === "dir"
    keys: ["text/uri-list"]
    onEntered: function (drag) {
      DropHoverState.dropHoverIndex = index
    }
    onExited: if (DropHoverState.dropHoverIndex === index) DropHoverState.dropHoverIndex = -1
    onDropped: function (drop) {
      DropHoverState.dropHoverIndex = -1
      hostDragDropOps.handleFilesDropped(drop, Utils.entryPath(NavState.currentPath, modelData))
    }
  }

  Item {
    id: rowContent
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: ViewState.isGrid ? Style.spacing.sm : 0
    anchors.rightMargin: ViewState.isGrid ? Style.spacing.sm : Style.spacing.rowPaddingX
    implicitHeight: ViewState.isGrid ? gridVisual.implicitHeight
      : (ViewState.isTable ? tableVisual.implicitHeight : listVisual.implicitHeight)

    readonly property bool isVid: Utils.isVideo(modelData)
    readonly property string vidKey: isVid ? Utils.thumbKeyFor(modelData, NavState.currentPath) : ""
    readonly property string vidThumb: vidKey ? (VideoThumbState.videoThumbReady[vidKey] || "") : ""

    // Native thumbnail (images/SVG/PDF) via ThumbnailProvider: on-disk
    // cache, doesn't re-decode the whole file on each scroll/revisit
    // as loading the full image at 32px did. imgThumb is the path of the
    // cached thumbnail ("" until it's ready -> the glyph is shown).
    readonly property string myPath: Utils.entryPath(NavState.currentPath, modelData)
    readonly property bool wantsThumb: Utils.isImage(modelData) || Utils.isPdf(modelData)
      || modelData.name.toLowerCase().slice(-4) === ".svg"
    property string imgThumb: ""
    // onMyPathChanged (not Component.onCompleted) because the ListView recycles
    // the delegates: when reusing a row for another entry the
    // thumbnail of the new path must be requested again.
    onMyPathChanged: {
      imgThumb = wantsThumb ? Backend.ThumbnailProvider.request(myPath, 256) : ""
      _requestCount(false)
    }

    Component.onCompleted: {
      if (isVid) hostVideoThumbs.requestVideoThumb(modelData)
      if (wantsThumb) imgThumb = Backend.ThumbnailProvider.request(myPath, 256)
      _requestCount(false)
    }

    // Item counter: only folders, lazy (this row is
    // visible) and cached. force=true on invalidation (refreshTick) to
    // recount even if it was already cached.
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
        if (path === rowContent.myPath) rowContent.imgThumb = thumbPath
      }
    }

    // Invalidation: any operation in the app (or the folder's watcher)
    // bumps refreshTick -> this row's folder is recounted. It also covers
    // the hidden toggle (toggleHidden does refresh + refreshTick).
    Connections {
      target: NavState
      function onRefreshTickChanged() { rowContent._requestCount(true) }
    }

    FileRowVisual {
      id: listVisual
      visible: ViewState.isList
      anchors.fill: parent
      name: modelData.name
      isDir: modelData.type === "dir"
      isBroken: modelData.link === "broken"
      highlighted: rowSurface.current
      dimmed: ClipboardState.clipboardMode === "cut" && ClipboardState.clipboardPaths.indexOf(Utils.entryPath(NavState.currentPath, modelData)) >= 0
      fileIconGlyph: Utils.iconFor(modelData)
      thumbSource: rowContent.imgThumb ? Util.fileUrl(rowContent.imgThumb)
        : (rowContent.vidThumb ? Util.fileUrl(rowContent.vidThumb) : "")
      metaText: hostFileMeta.metaFor(modelData)
      metaTooltip: hostFileMeta.metaTooltipFor(modelData)
      showNameText: EditModeState.renamingIndex !== index
    }

    FileGridVisual {
      id: gridVisual
      visible: ViewState.isGrid
      anchors.fill: parent
      name: modelData.name
      isDir: modelData.type === "dir"
      isBroken: modelData.link === "broken"
      highlighted: rowSurface.current
      dimmed: ClipboardState.clipboardMode === "cut" && ClipboardState.clipboardPaths.indexOf(Utils.entryPath(NavState.currentPath, modelData)) >= 0
      fileIconGlyph: Utils.iconFor(modelData)
      thumbSource: rowContent.imgThumb ? Util.fileUrl(rowContent.imgThumb)
        : (rowContent.vidThumb ? Util.fileUrl(rowContent.vidThumb) : "")
      showNameText: EditModeState.renamingIndex !== index
    }

    FileTableVisual {
      id: tableVisual
      visible: ViewState.isTable
      anchors.fill: parent
      name: modelData.name
      isDir: modelData.type === "dir"
      isBroken: modelData.link === "broken"
      highlighted: rowSurface.current
      dimmed: ClipboardState.clipboardMode === "cut" && ClipboardState.clipboardPaths.indexOf(Utils.entryPath(NavState.currentPath, modelData)) >= 0
      fileIconGlyph: Utils.iconFor(modelData)
      thumbSource: rowContent.imgThumb ? Util.fileUrl(rowContent.imgThumb)
        : (rowContent.vidThumb ? Util.fileUrl(rowContent.vidThumb) : "")
      sizeText: hostFileMeta ? hostFileMeta.sizeTextFor(modelData) : ""
      typeText: hostFileMeta ? hostFileMeta.typeTextFor(modelData) : ""
      dateText: hostFileMeta ? hostFileMeta.dateTextFor(modelData) : ""
      sizeTooltip: hostFileMeta ? hostFileMeta.metaTooltipFor(modelData) : ""
      showNameText: EditModeState.renamingIndex !== index
    }

    TextField {
      id: renameField
      visible: EditModeState.renamingIndex === index
      Accessible.role: Accessible.EditableText
      Accessible.name: "Rename"
      Accessible.description: Utils.validBasename(text) ? "" : "Invalid file name"
      color: Utils.validBasename(text) ? Color.menu.text : "#ef4444"
      // Same X as nameCol inside FileRowVisual
      // (thumbSlot.right + rowGap) -- that id is no longer
      // visible from here, so it's repeated with the
      // same known constant (Style.spacing.controlHeight,
      // the icon's fixed width) instead of chasing the id.
      anchors.left: parent.left
      anchors.leftMargin: ViewState.isGrid ? Style.spacing.xs : Style.spacing.controlHeight + Style.spacing.rowGap
      anchors.right: parent.right
      anchors.rightMargin: ViewState.isGrid ? Style.spacing.xs : 0
      anchors.bottom: ViewState.isGrid ? parent.bottom : undefined
      anchors.verticalCenter: ViewState.isGrid ? undefined : parent.verticalCenter
      verticalPadding: 2
      onVisibleChanged: if (visible) { text = modelData.name; forceActiveFocus(); selectAll() } else hostListView.forceActiveFocus()
      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          if (Utils.validBasename(text)) hostConflictActions.commitRename(text)
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
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.right: parent.right
    anchors.left: parent.left
    // Uncovered gaps on both sides (the visual content --
    // icon, text -- doesn't move, only the interactive area
    // is reduced) so the gutter MouseArea below
    // can keep the press there instead of competing for
    // hover with this one. Left raised from 14 to 24 -- josema
    // testing it live said there was excess unused distance
    // between the icon and the separator bar. Right matches
    // rowContent.anchors.rightMargin (rowPaddingX), which already
    // leaves that gap without visual content.
    anchors.leftMargin: ViewState.isGrid ? 0 : 24
    anchors.rightMargin: ViewState.isGrid ? 0 : Style.spacing.rowPaddingX
    hoverEnabled: true
    visible: EditModeState.renamingIndex !== index
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    drag.target: dragProxy
    drag.axis: Drag.XAndYAxis
    onPressed: function (mouse) {
      // Starting to drag a file that wasn't part of
      // the selection should drag only that file (like
      // Nautilus) -- but only on a simple click: Ctrl/Shift+click
      // still decide the selection in onClicked, without touching
      // the range anchor here (selectRange).
      if (mouse.button === Qt.LeftButton && mouse.modifiers === Qt.NoModifier && !SelectionState.isSelected(index)) {
        SelectionState.selectOnly(index)
      }
      // Drag thumbnail: captured here (not in
      // Drag.onActiveChanged) to give it time to
      // complete -- grabToImage is async (one frame) and by
      // the time the movement exceeds the drag threshold it's almost
      // always ready.
      if (mouse.button === Qt.LeftButton) {
        DropHoverState.pointerDown = true
        rowContent.grabToImage(function (result) { dragProxy.Drag.imageSource = result.url })
      }
    }
    onReleased: DropHoverState.pointerDown = false
    onCanceled: DropHoverState.pointerDown = false
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
    // hasPendingEdit: don't enter while there is an unconfirmed rename/new-folder/new-file
    onDoubleClicked: if ((!hostRoot || !hostRoot.hasPendingEdit) && hostNavController) hostNavController.enter(modelData)
  }

  // Invisible proxy that MouseArea.drag moves -- the only thing that
  // really matters is its Drag.active, which starts the real
  // drag (internal or toward another app) as soon as the
  // movement threshold is exceeded.
  Item {
    id: dragProxy
    width: 1
    height: 1
    Drag.active: mouseArea.drag.active
    Drag.dragType: Drag.Automatic
    Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
    Drag.proposedAction: Qt.MoveAction
    Drag.mimeData: hostDragDropOps.dragMimeDataFor(index)
    Drag.onActiveChanged: DropHoverState.dragActive = Drag.active
    Component.onDestruction: {
      if (Drag.active) DropHoverState.dragActive = false
      if (mouseArea.pressed) DropHoverState.pointerDown = false
    }
  }

  // Lasso gutters on both sides of the row -- they implement
  // the start/drag directly (they don't trust the
  // press to "fall" to something behind: in the left strip, before
  // this change, there was nothing behind except the wheel
  // MouseArea, which keeps any click anyway
  // even if it only has onWheel). anchors.leftMargin of
  // `mouseArea` (24) and anchors.rightMargin of `rowContent`
  // (Style.spacing.rowPaddingX) leave these gaps free of
  // visual content, so they steal nothing from the icon/text.
  MarqueeCatcher {
    visible: !ViewState.isGrid
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    width: 24
    catcherListView: hostListView
    measuredRowHeight: hostRoot.measuredRowHeight
  }

  MarqueeCatcher {
    visible: !ViewState.isGrid
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.right: parent.right
    width: Style.spacing.rowPaddingX
    catcherListView: hostListView
    measuredRowHeight: hostRoot.measuredRowHeight
  }
}

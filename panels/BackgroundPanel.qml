import QtQuick
import qs.Commons
import qs.Ui
import Omafiles.Backend as Backend
import "../shared"
import "../state"
import "../logic"
import "../shared/Utils.js" as Utils

// Delegate of the "background" panels (all tabs except the active one),
// nineteenth component extracted from core. Each one has its
// own listing (its own Process), without a selection lasso nor its own context
// menu -- only navigate with double click and drag, the active
// panel (which stays in core) already has everything else.
// hostPanelsRow is passed as a property separate from hostRoot -- it's the one that computes
// x/width/height of this panel (slotX/slotWidth), and without passing it explicitly
// it isn't visible from this file.
Item {
  id: bgPanel
  property Item hostRoot: null
  property Item hostPanelsRow: null
  property Item hostNavController: null
  property Item hostCommandFacade: null
  property Item hostVideoThumbs: null
  property Item hostDragDropOps: null
  property Item hostFileMeta: null
  property Item hostTabOps: null
  required property var modelData
  required property int index
  // ALWAYS rendered (not `visible:false`): an invisible ListView doesn't do its
  // layout (contentHeight=0), so on moving to the background positionViewAtIndex
  // didn't hit the mark until a couple of frames later -> the scroll jump. With opacity:0
  // (in the active slot) the ListView STILL has a real layout (ch>0), covered by the
  // activePanel that goes on top in the same slot; on moving to the background it positions
  // instantly, frozen. The background slots go to the usual 0.72 dim.
  visible: true
  opacity: index === TabsState.activeTabIndex ? 0 : 0.72
  x: hostPanelsRow.slotX(index)
  y: 0
  width: hostPanelsRow.slotWidth
  height: hostPanelsRow.height

  // PER-PANEL search: if this tab was left in GLOBAL
  // search mode (2+ chars) when moving to the background, the background panel
  // keeps it open -- bar + results -- until it's closed with the X. The
  // state (searching/searchQuery/searchEntries/searchTruncated) is saved by
  // TabOps.saveActiveTab in the tab object itself (modelData), so each
  // panel has its independent search instead of a shared global one.
  readonly property bool bgSearching: modelData.searching === true
    && (modelData.searchQuery || "").length >= 2
  // RAW results saved by TabOps (for the footer's "of N").
  readonly property var bgSearchEntries: modelData.searchEntries || []
  // Same NAME filter that the active panel applies (NavState.visibleEntries):
  // the global search also brings PATH matches (e.g. folders
  // INSIDE Steam/ like bin/ or logs/, whose name doesn't contain the term). The
  // active panel hides them; without this, the background panel showed MORE results
  // than the active one for the same search. Now the two show the same.
  readonly property var bgVisibleSearchEntries: {
    var q = (modelData.searchQuery || "").toLowerCase()
    return bgSearchEntries.filter(function (e) { return e.name.toLowerCase().indexOf(q) >= 0 })
  }

  // The listing itself lives in DirLister -- same
  // mechanism the active panel uses (NavigationController), but with
  // its own instance: several background tabs can be listing
  // different paths at the same time, so they can't share a single
  // Process. entries/pathError/loaded are no longer bgPanel's own
  // properties -- they're read directly from dirLister throughout the file.
  DirLister {
    id: dirLister
    trashDir: Paths.trashDir
    showHidden: NavState.showHidden
    // hostRoot.tabEntriesCache is what _goToPath() consults when entering
    // a path that a background panel already had listed -- only the
    // background panels fill it (see NavigationController, which does NOT
    // write here).
    onListed: {
      bgPanel._cachePut(bgPanel.effectivePath, dirLister.entries)
      // Refreshes the painted content ONLY if it really changed (Utils
      // .entriesEqual): so, on moving to the background with the folder unchanged, the
      // model is NOT reassigned -> the ListView doesn't reset the scroll -> no jump. If
      // it changed (new files), it's reassigned and re-positioned.
      if (!Utils.entriesEqual(dirLister.entries, bgPanel._content)) {
        bgPanel._content = dirLister.entries
        bgPanel._restoreScroll()
      }
    }
  }

  // LRU of the per-path entries cache: before it grew without
  // limit (one entry per folder visited in ANY background
  // tab, retaining thousands of objects in long sessions with keepLoaded).
  // It's bounded to the 8 most recent paths using the insertion order of the
  // object's keys (delete+reinsert moves to the end = most recent;
  // the ones at the start are evicted = oldest).
  readonly property int _cacheMax: 8
  function _cachePut(path, entries) {
    var c = hostRoot.tabEntriesCache
    if (c[path] !== undefined) delete c[path]
    c[path] = entries
    var keys = Object.keys(c)
    while (keys.length > _cacheMax) { delete c[keys[0]]; keys.shift() }
  }

  // Hovering makes this panel become the active one (the
  // one with the selection lasso, context menu, and that responds to the
  // j/k/F2/Del/etc. keyboard shortcuts) -- without this you could only "activate" a
  // panel by clicking inside, and josema wanted it to be enough to place the
  // cursor over it. HoverHandler instead of MouseArea: it doesn't steal the event from
  // the MouseArea of the rows/buttons below, it only observes.
  HoverHandler {
    // Don't switch the active panel while the user has a name half-
    // written (rename/new folder/new file/editable path) --
    // switchToTab -> _goToPath resets those fields, and with hover-to-activate
    // just crossing the mouse over the divider was enough to lose the text without
    // any click involved. Nor with the context menu open --
    // real bug: the menu opens over the active panel of THAT moment, but
    // if the cursor passed over another background panel on the way to a menu
    // entry (nothing blocked the hover just for having a menu on top), the
    // active tab changed mid-action and "Open in new tab"/Copy/
    // etc. ended up acting on the wrong folder.
    // The real guard now lives in switchToTab() (hasBlockingOverlay), so
    // it covers ALL the dialogs, not just these two.
    onHoveredChanged: if (hovered && !DropHoverState.blockPanelSwitch) hostTabOps.switchToTab(bgPanel.index)
  }

  // Last path for which this specific panel launched a reload --
  // see onModelDataChanged below.
  property string _lastRefreshedPath: ""

  // Path that this panel must list. For the ACTIVE tab it's NavState
  // .currentPath (the tab object is NOT updated until the switch, so
  // using modelData.path left the active-slot panel with the PREVIOUS folder
  // and its EMPTY/stale list -> on moving to the background it populated async and jumped).
  // For the background tabs it's their own saved path. So the active-slot
  // panel (opacity:0, covered by the active panel) PRELOADS the current
  // folder, and on moving to the background it already has the content and the layout -> the
  // repositioning is instant, frozen, without a jump.
  readonly property string effectivePath: index === TabsState.activeTabIndex
    ? NavState.currentPath : (modelData.path || "")
  onEffectivePathChanged: bgPanel.refreshMe()

  // Content that the background ListView paints. It's adopted SYNCHRONOUSLY from the tab
  // object (modelData.entries, which TabOps saved = what the active panel
  // saw) on moving to the background, so the list is NOT empty at that
  // instant (if it were populated async, the scroll would jump from 0 to its place). The
  // dirLister refreshes it behind the scenes without resetting if the content didn't change.
  property var _content: []

  function refreshMe() {
    if (bgPanel.effectivePath === "") return
    bgPanel._lastRefreshedPath = bgPanel.effectivePath
    dirLister.list(bgPanel.effectivePath)
  }

  // On moving to the background (no longer the active tab): restore the scroll.
  // The content is already preloaded (the active slot listed effectivePath
  // live) and with layout (opacity:0 keeps the ListView in the scene graph), so
  // positionViewAtIndex hits the mark instantly. It does NOT re-list here: the path hasn't
  // changed, and re-listing reset the list -> the jump.
  readonly property bool isBackground: index !== TabsState.activeTabIndex
  onIsBackgroundChanged: if (isBackground) {
    // Adopts the content saved in the tab (synchronous, not empty) BEFORE
    // positioning, and refreshes behind the scenes.
    bgPanel._content = bgPanel.modelData.entries || []
    bgPanel._restoreScroll()
    bgPanel.refreshMe()
  }
  // refreshTick is the signal for the NON-active panels to refresh
  // after an action (delete/move/paste/rename), which may affect
  // any panel and not only the active one. It lives in NavState since Phase 14.C
  // -- before it was in OmafilesContent (hostRoot) and this Connections was left
  // listening to a target without that signal (silent regression detected in the
  // 14.E audit: qmllint doesn't see it because hostRoot is an untyped Item).
  Connections {
    target: NavState
    function onRefreshTickChanged() { bgPanel.refreshMe() }
  }
  Component.onCompleted: bgPanel.refreshMe()

  // Scroll shared with the active panel (tab.scrollY = list.contentY). On
  // moving THIS panel to the background we have to reflect in its bgList the scroll it
  // had as the active panel; otherwise, it jumped to the beginning. It's called from
  // dirLister.onListed (when the async re-listing is already set, otherwise that
  // re-listing would reset the contentY right after).
  function _restoreScroll() {
    // By INDEX (positionViewAtIndex), not by pixel: immune to the
    // contentHeight being estimated lazily. Fallback to contentY if there is no
    // saved index (old tabs / root with no scroll).
    var idx = modelData.scrollIndex
    if (idx !== undefined && idx >= 0) {
      // A ListView just made visible hasn't done its layout yet (contentHeight
      // = 0), so positionViewAtIndex would give 0 and the scroll would jump when measured
      // async. forceLayout() completes the SYNCHRONOUS layout -> real geometry ->
      // positionViewAtIndex hits the mark on the first try, without a jump.
      // Anchored on the row's REAL y (same geometry as firstVisibleOffset
      // when saving), not on the contentY that positionViewAtIndex leaves -> no drift.
      bgList.forceLayout()
      bgList.positionViewAtIndex(idx, GridView.Beginning)
      var it = bgList.itemAtIndex(idx)
      if (it) bgList.contentY = it.y + (modelData.scrollOffset || 0)
    } else {
      bgList.contentY = modelData.scrollY || bgList.originY
    }
  }
  // And the other way around: if you scroll this background panel, it's saved in its tab
  // object so that on activating it (list.contentY = tab.scrollY) it stays the same.
  // Only on release (onMovementEnded), not by pixel, so as not to reassign
  // TabsState.tabs constantly.
  function _saveScroll() {
    if (index < 0 || index >= TabsState.tabs.length) return
    var t = TabsState.tabs[index]
    if (!t || t.scrollY === bgList.contentY) return
    var idx = bgList.indexAt(4, bgList.contentY + 4)
    var it = idx >= 0 ? bgList.itemAtIndex(idx) : null
    var off = it ? (bgList.contentY - it.y) : 0
    var next = TabsState.tabs.slice()
    next[index] = Object.assign({}, t, { "scrollY": bgList.contentY, "scrollIndex": idx, "scrollOffset": off })
    TabsState.tabs = next
  }

  DropArea {
    anchors.fill: parent
    keys: ["text/uri-list"]
    onEntered: function (drag) { drag.accepted = true }
    onDropped: function (drop) { hostDragDropOps.handleFilesDropped(drop, bgPanel.modelData.path) }
  }

  BackgroundHeader {
    id: bgHeaderRow
    anchors.top: parent.top
    modelData: bgPanel.modelData
    index: bgPanel.index
    hostTabOps: bgPanel.hostTabOps
    hostCommandFacade: bgPanel.hostCommandFacade
    bgSearching: bgPanel.bgSearching
  }

  PanelSeparator {
    id: bgHeaderSep
    anchors.top: bgHeaderRow.bottom
    anchors.topMargin: Style.spacing.rowGap
    width: parent.width
    foreground: Color.menu.text
    strength: 0.15
  }

  FileTableHeader {
    id: bgTableHeader
    visible: ViewState.isTable
    anchors.top: bgHeaderSep.bottom
    anchors.left: parent.left
    width: parent.width
    height: visible ? implicitHeight : 0
  }

  Text {
    id: bgErrorText
    visible: dirLister.pathError !== "" && !bgPanel.bgSearching
    anchors.top: bgTableHeader.visible ? bgTableHeader.bottom : bgHeaderSep.bottom
    anchors.topMargin: Style.spacing.md
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.rightMargin: Style.spacing.rowPaddingX
    height: Style.spacing.controlHeight
    verticalAlignment: Text.AlignVCenter
    text: dirLister.pathError
    font.pixelSize: Style.font.subtitle
    font.family: Style.font.family
    color: Color.urgent
  }

  FontMetrics { id: bgNameFM; font.family: Style.font.family; font.pixelSize: Style.font.title; font.weight: Font.Medium }
  FontMetrics { id: bgMetaFM; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
  readonly property int bgListRowInnerH: Math.max(Style.spacing.controlHeight,
    Math.ceil(bgNameFM.height) + Style.spacing.xs + Math.ceil(bgMetaFM.height))
  readonly property int bgTableRowInnerH: Math.max(Style.spacing.controlHeight, Math.ceil(bgNameFM.height))
  readonly property int bgListCellH: bgListRowInnerH + Style.spacing.md * 2
  readonly property int bgTableCellH: bgTableRowInnerH + Style.spacing.sm * 2
  readonly property int bgGridIconS: Style.space(ViewState.gridIconPx)
  readonly property int bgGridCellH: bgGridIconS + Style.spacing.sm + Math.ceil(bgNameFM.height) * 2 + Style.spacing.md * 2
  readonly property int bgGridMinCellW: Style.space(ViewState.gridCellWidthPx)
  readonly property int bgGridCols: ViewState.columnsForWidth(bgList.width, bgGridMinCellW)
  readonly property int bgGridCellW: ViewState.cellWidthFor(bgList.width, bgGridMinCellW)

  GridView {
    id: bgList
    anchors.top: bgErrorText.visible ? bgErrorText.bottom : bgTableHeader.bottom
    anchors.topMargin: ViewState.isTable ? Style.spacing.xs : Style.spacing.md
    anchors.bottom: bgStatusText.top
    anchors.bottomMargin: Style.spacing.rowGap
    anchors.left: parent.left
    anchors.right: parent.right
    clip: true
    model: bgPanel.bgSearching ? bgPanel.bgVisibleSearchEntries : bgPanel._content
    boundsBehavior: Flickable.StopAtBounds
    cellWidth: ViewState.isGrid ? bgPanel.bgGridCellW : Math.max(1, width)
    cellHeight: ViewState.isGrid ? bgPanel.bgGridCellH : (ViewState.isTable ? bgPanel.bgTableCellH : bgPanel.bgListCellH)
    flow: GridView.LeftToRight
    keyNavigationEnabled: false
    highlightFollowsCurrentItem: false
    onMovementEnded: bgPanel._saveScroll()

    delegate: BackgroundListDelegate {
      panelPath: bgPanel.modelData.path || ""
      bgSearching: bgPanel.bgSearching
      hostDragDropOps: bgPanel.hostDragDropOps
      hostVideoThumbs: bgPanel.hostVideoThumbs
      hostFileMeta: bgPanel.hostFileMeta
      hostTabOps: bgPanel.hostTabOps
      hostNavController: bgPanel.hostNavController
      bgPanelIndex: bgPanel.index
      cellWidth: bgList.cellWidth
      cellHeight: bgList.cellHeight
    }
  }

  EmptyState {
    visible: dirLister.loaded && dirLister.pathError === "" && ((bgPanel.bgSearching ? bgPanel.bgVisibleSearchEntries : bgPanel._content).length === 0)
    centerOn: bgList
    message: bgPanel.bgSearching
      ? "No results for “" + bgPanel.bgSearchQuery + "”"
      : (bgPanel.modelData.path === Paths.trashDir ? "Trash is empty" : "Folder is empty")
    subMessage: bgPanel.bgSearching
      ? "Try a broader search or check spelling"
      : (bgPanel.modelData.path === Paths.trashDir ? "Deleted items will appear here" : "Drop files here to add them")
  }

  Text {
    id: bgStatusText
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    // Same format as the active panel's footer (statusText in
    // MainLayout): "N items · sort: <criterion>". The sort criterion is
    // global (SortState, via SortState.sortLabel()), so the background
    // panel lists with the SAME order -- omitting it made the two views
    // look different when moving the cursor. The active panel's extras
    // (selection/clipboard/search) are states that only exist there, not
    // in a background panel, so they're not replicated.
    // With a search open, the footer reflects THIS panel's RESULTS
    // (count + trimmed-list notice), same as the active panel's footer
    // when searching; otherwise, the normal folder listing.
    text: bgPanel.bgSearching
      ? (bgPanel.bgVisibleSearchEntries.length + (bgPanel.bgVisibleSearchEntries.length === 1 ? " item" : " items")
         + " of " + bgPanel.bgSearchEntries.length
         + (bgPanel.modelData.searchTruncated ? " · showing first 200" : ""))
      : (dirLister.entries.length + (dirLister.entries.length === 1 ? " item" : " items")
         + " · sort: " + SortState.sortLabel()
         + " · view: " + ViewState.viewLabel())
    font.pixelSize: Style.font.subtitle
    font.family: Style.font.family
    color: Color.menu.text
    opacity: Style.emphasis.secondary
  }
}

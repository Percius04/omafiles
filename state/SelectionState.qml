pragma Singleton
import QtQuick

// Row selection state (single + drag marquee) --
// first singleton of the state/ layer, a pilot to validate the
// Selection state singleton for active file listing.
// Util/Color/Style of qs.Commons already use) before moving more state here. The
// logic that manipulates it stays in logic/SelectionOps.qml -- this is ONLY
// the state, without functions.
QtObject {
  property int selectedIndex: -1
  property var selectedIndices: []
  property int anchorIndex: -1

  // ---------- Selection marquee (drag over empty space) ----------
  // Coordinates in the ListView's content space (independent
  // of the scroll), not the viewport -- so the rectangle stays correct if
  // the user drags into the scrolled area.
  property bool marqueeActive: false
  property real marqueeStartX: 0
  property real marqueeStartY: 0
  property real marqueeCurrentX: 0
  property real marqueeCurrentY: 0
  property bool marqueeAdditive: false
  property var marqueeBaseSelection: []
  // Cursor position relative to `list`'s viewport (0 = very top,
  // list.height = very bottom) -- for the auto-scroll when the
  // marquee reaches an edge with more rows than fit on screen.
  property real marqueeViewportY: 0

  function selectedEntries() {
    var entries = []
    for (var i = 0; i < selectedIndices.length; i++) {
      var idx = selectedIndices[i]
      if (idx >= 0 && idx < NavState.visibleEntries.length) entries.push(NavState.visibleEntries[idx])
    }
    return entries
  }

  function isSelected(index) {
    return selectedIndices.indexOf(index) >= 0
  }

  function selectOnly(index) {
    selectedIndex = index
    anchorIndex = index
    selectedIndices = index >= 0 ? [index] : []
  }

  function toggleSelect(index) {
    var next = selectedIndices.slice()
    var pos = next.indexOf(index)
    if (pos >= 0) next.splice(pos, 1)
    else next.push(index)
    selectedIndices = next
    selectedIndex = index
    anchorIndex = index
  }

  function selectNone() {
    selectOnly(-1)
  }

  function invertSelection() {
    var current = selectedIndices
    var next = []
    for (var i = 0; i < NavState.visibleEntries.length; i++) {
      if (current.indexOf(i) < 0) next.push(i)
    }
    selectedIndices = next
    selectedIndex = next.length > 0 ? next[next.length - 1] : -1
    anchorIndex = selectedIndex
  }

  function selectRange(index) {
    var start = anchorIndex >= 0 ? anchorIndex : index
    var from = Math.min(start, index)
    var to = Math.max(start, index)
    var next = []
    for (var i = from; i <= to; i++) next.push(i)
    selectedIndices = next
    selectedIndex = index
  }

  function startMarquee(x, contentY, vY, ctrlHeld) {
    marqueeAdditive = ctrlHeld
    marqueeBaseSelection = ctrlHeld ? selectedIndices.slice() : []
    if (!ctrlHeld) selectOnly(-1)
    marqueeStartX = x
    marqueeCurrentX = x
    marqueeStartY = contentY
    marqueeCurrentY = contentY
    marqueeViewportY = vY
    marqueeActive = true
  }

  function moveMarquee(x, contentY, vY, measuredRowHeight) {
    if (!marqueeActive) return
    marqueeCurrentX = x
    marqueeCurrentY = contentY
    marqueeViewportY = vY
    updateMarqueeSelection(marqueeAdditive, marqueeBaseSelection, measuredRowHeight)
  }

  function endMarquee() {
    marqueeActive = false
  }

  function updateMarqueeSelection(additive, base, measuredRowHeight) {
    var total = NavState.visibleEntries.length
    if (total === 0) return

    var next
    if (ViewState.isGrid) {
      next = ViewState.gridIndicesInRect(
        marqueeStartX, marqueeStartY, marqueeCurrentX, marqueeCurrentY,
        ViewState.gridCellWidth, ViewState.gridCellHeight, ViewState.gridColumns, total)
      if (additive) {
        var merged = base.slice()
        for (var g = 0; g < next.length; g++) {
          if (merged.indexOf(next[g]) < 0) merged.push(next[g])
        }
        next = merged
      }
    } else {
      if (measuredRowHeight <= 0) return
      var fromY = Math.min(marqueeStartY, marqueeCurrentY)
      var toY = Math.max(marqueeStartY, marqueeCurrentY)
      var firstVisible = Math.floor(fromY / measuredRowHeight)
      var lastVisible = Math.floor(toY / measuredRowHeight)
      if (firstVisible < 0) firstVisible = 0
      if (lastVisible >= total) lastVisible = total - 1
      next = additive ? base.slice() : []
      for (var i = firstVisible; i <= lastVisible; i++) {
        if (next.indexOf(i) < 0) next.push(i)
      }
    }
    selectedIndices = next
    if (next.length > 0) {
      selectedIndex = next[next.length - 1]
      anchorIndex = selectedIndex
    }
  }
}

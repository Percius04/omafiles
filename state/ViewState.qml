pragma Singleton
import QtQuick

// Current file display type (list / table / grid) -- same pattern as
// SortState: one global criterion, a key that cycles it, no dropdown.
QtObject {
  property string viewMode: "list"

  readonly property var viewModes: ["list", "table", "grid"]
  readonly property var viewModeLabels: ({ list: "List", table: "Table", grid: "Icons" })
  readonly property bool isList: viewMode === "list"
  readonly property bool isTable: viewMode === "table"
  readonly property bool isGrid: viewMode === "grid"

  // Unscaled column widths. Visuals pass them through Style.space()
  // so they track the same spacing scale as the rest of the shell.
  readonly property int sizeColPx: 88
  readonly property int typeColPx: 72
  readonly property int dateColPx: 110

  // Unscaled grid tile size. The active GridView converts these
  // through Style.space() and writes the live pixel metrics below
  // so keyboard motion and the lasso can use the real cell.
  readonly property int gridIconPx: 72
  readonly property int gridCellWidthPx: 112

  property int gridColumns: 1
  property int gridCellWidth: 112
  property int gridCellHeight: 140

  function viewLabel() {
    return viewModeLabels[viewMode] || "List"
  }

  function setView(mode) {
    if (viewModes.indexOf(mode) < 0) return
    viewMode = mode
  }

  function cycleView() {
    var idx = viewModes.indexOf(viewMode)
    setView(viewModes[(idx + 1) % viewModes.length])
  }

  function columnsForWidth(width, minCell) {
    var m = Math.max(1, minCell)
    return Math.max(1, Math.floor(Math.max(m, width) / m))
  }

  function cellWidthFor(width, minCell) {
    var cols = columnsForWidth(width, minCell)
    return Math.max(minCell, Math.floor(Math.max(minCell, width) / cols))
  }

  // Items whose cells intersect a content-space rectangle. Used by
  // the lasso in icon view; kept here so selfcheck can prove the math.
  function gridIndicesInRect(x1, y1, x2, y2, cellW, cellH, cols, total) {
    if (cellW <= 0 || cellH <= 0 || cols <= 0 || total <= 0) return []
    var left = Math.min(x1, x2)
    var right = Math.max(x1, x2)
    var top = Math.min(y1, y2)
    var bottom = Math.max(y1, y2)
    var colStart = Math.floor(left / cellW)
    var colEnd = Math.floor(right / cellW)
    var rowStart = Math.floor(top / cellH)
    var rowEnd = Math.floor(bottom / cellH)
    var next = []
    for (var row = rowStart; row <= rowEnd; row++) {
      for (var col = colStart; col <= colEnd; col++) {
        if (col < 0 || col >= cols || row < 0) continue
        var i = row * cols + col
        if (i >= 0 && i < total) next.push(i)
      }
    }
    return next
  }
}

import QtQuick
import qs.Commons

// Breadcrumb row (path segments) -- fifteenth component
// extracted from core, shared between the active and background panels.
// Previously they were two nearly identical Repeaters (breadcrumbRow and bgBreadcrumbRow)
// that compared each segment against a different "current" path depending on the
// panel -- here that "current" is a single parameter (activePath) that the caller
// already resolves (root.currentPath or bgPanel.modelData.path). The active
// panel still has, outside this component, the MouseArea and the
// TextField to edit the path by hand -- the background one does not need them.
//
// No MouseArea inside on purpose: the caller owns the MouseArea (click to
// navigate, double-click to edit in the active panel). This component only
// exposes pathAt() so the caller can translate a local x into the segment
// under the pointer.
Row {
  id: root

  property var segments: []
  property string activePath: ""

  // Map a local x (in this Row's coordinates) to the path of the segment
  // containing it, or "" if it lands on a separator / empty space. Used by
  // the caller's MouseArea to navigate on a single click.
  function pathAt(x) {
    var cursor = 0
    for (var i = 0; i < root.segments.length; i++) {
      var seg = root.segments[i]
      var labelW = Math.ceil(menuFont.advanceWidth(seg.label))
      var rowW = labelW + (seg.path !== root.activePath ? Math.ceil(menuFont.advanceWidth("\u203A")) : 0)
      if (i > 0) rowW += root.spacing
      if (x >= cursor && x < cursor + labelW) return seg.path
      cursor += rowW
    }
    return ""
  }

  // Measures the labels so pathAt() does not depend on the delegates being
  // laid out yet (same font the visible Texts use).
  FontMetrics {
    id: menuFont
    font.pixelSize: Style.font.title
    font.family: Style.font.family
    font.weight: Font.Medium
  }

  spacing: Style.spacing.xs
  clip: true

  Repeater {
    model: root.segments

    Row {
      required property var modelData
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xs

      Text {
        text: modelData.label
        font.pixelSize: Style.font.title
        font.family: Style.font.family
        font.bold: modelData.path === root.activePath
        color: Color.menu.text
        opacity: modelData.path === root.activePath ? 1.0 : Style.emphasis.secondary
      }

      Text {
        visible: modelData.path !== root.activePath
        text: "\u203A"
        font.pixelSize: Style.font.title
        font.family: Style.font.family
        color: Color.menu.text
        opacity: Style.emphasis.muted
      }
    }
  }
}

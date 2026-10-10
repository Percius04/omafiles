import QtQuick
import qs.Commons
import qs.Commons as Commons

// Breadcrumb row (path segments) -- fifteenth component
// extracted from core, shared between the active and background panels.
// Previously they were two nearly identical Repeaters (breadcrumbRow and bgBreadcrumbRow)
// that compared each segment against a different "current" path depending on the
// panel -- here that "current" is a single parameter (activePath) that the caller
// already resolves (root.currentPath or bgPanel.modelData.path). The active
// panel still has, outside this component, the MouseArea and the
// TextField to edit the path by hand -- the background one does not need them.
Row {
  id: root

  property var segments: []
  property string activePath: ""

  spacing: Style.spacing.xs
  clip: true

  Repeater {
    model: root.segments

    Row {
      required property var modelData
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xs

      // No own MouseArea on purpose -- josema did not want per-segment
      // navigation (the back/up buttons are already there for that),
      // just text that lets the click pass through to the MouseArea behind (edit
      // the path by hand, only in the active panel).
      Text {
        text: modelData.label
        font.pixelSize: Style.font.title
        font.family: Style.font.family
        font.bold: modelData.path === root.activePath
        color: Commons.Color.menu.text
        opacity: modelData.path === root.activePath ? 1.0 : Style.emphasis.secondary
      }

      Text {
        visible: modelData.path !== root.activePath
        text: "›"
        font.pixelSize: Style.font.title
        font.family: Style.font.family
        color: Commons.Color.menu.text
        opacity: Style.emphasis.muted
      }
    }
  }
}

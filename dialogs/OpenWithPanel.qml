import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../shared"

// "Open with..." dialog. Fourth component extracted from core --
// as with ConnectServer.qml, the real action (launch the chosen app) is
// exposed as a parameterized signal instead of calling root.launchWith()
// directly from within the component.
//
// The modal wrapper (scrim + card + animation + padding) is
// shared/ModalSurface.qml, common to all dialogs.
Item {
  id: root

  property bool open: false
  property var entry: null
  property var apps: []

  signal closeRequested()
  signal appSelected(string appId)

  ModalSurface {
    open: root.open
    maxWidth: Style.space(320)
    onDismissed: root.closeRequested()

    Text {
      width: parent.width
      text: "Open \"" + (root.entry ? root.entry.name : "") + "\" with:"
      font.pixelSize: Style.font.title
      font.family: Style.font.family
      font.bold: true
      color: Commons.Color.menu.text
      elide: Text.ElideMiddle
    }

    PanelSeparator { foreground: Commons.Color.menu.text; strength: 0.15 }

    Text {
      visible: root.apps.length === 0
      width: parent.width
      text: "No registered applications for this file type."
      font.pixelSize: Style.font.title
      font.family: Style.font.family
      color: Commons.Color.menu.text
      opacity: Style.emphasis.secondary
      wrapMode: Text.Wrap
    }

    Repeater {
      model: root.apps

      CursorSurface {
        required property var modelData
        width: parent.width
        implicitHeight: Style.spacing.controlHeight
        foreground: Commons.Color.menu.text
        accent: Commons.Color.accent
        hasCursor: appMouse.containsMouse

        Text {
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: parent.left
          anchors.leftMargin: Style.spacing.sm
          text: parent.modelData.name
          font.pixelSize: Style.font.title
          font.family: Style.font.family
          font.weight: Font.Medium
          color: Commons.Color.menu.text
        }

        MouseArea {
          id: appMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.appSelected(modelData.id)
        }
      }
    }
  }
}

import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../shared"

// "Already exists, overwrite/skip/cancel?" dialog. Seventh
// component extracted from core -- unlike the
// previous ones, this is not just a relocation: "Paste conflict" and
// "Drop conflict" were two ~55-line blocks IDENTICAL except for
// which function they called, so they are unified into a single
// reusable component with generic signals (overwriteRequested/skipRequested/
// cancelRequested) instead of keeping the duplication in two files.
//
// The modal wrapper (scrim + card + animation + padding) is
// shared/ModalSurface.qml, common to all dialogs.
Item {
  id: root

  property bool open: false
  property var names: []

  signal overwriteRequested()
  signal skipRequested()
  signal cancelRequested()

  ModalSurface {
    open: root.open
    maxWidth: Style.space(360)
    onDismissed: root.cancelRequested()

    Text {
      width: parent.width
      text: root.names.length === 1
        ? "\"" + root.names[0] + "\" already exists here."
        : root.names.length + " items already exist here."
      font.pixelSize: Style.font.title
      font.family: Style.font.family
      font.bold: true
      color: Commons.Color.menu.text
      wrapMode: Text.Wrap
    }

    Column {
      width: parent.width
      spacing: Style.spacing.xs

      Button { width: parent.width; leftAlign: true; bordered: true; text: "Overwrite all"; Accessible.role: Accessible.Button; Accessible.name: text; onClicked: root.overwriteRequested() }
      Button { width: parent.width; leftAlign: true; bordered: true; text: "Skip existing"; Accessible.role: Accessible.Button; Accessible.name: text; onClicked: root.skipRequested() }
      Button { width: parent.width; leftAlign: true; bordered: true; text: "Cancel"; Accessible.role: Accessible.Button; Accessible.name: text; onClicked: root.cancelRequested() }
    }
  }
}

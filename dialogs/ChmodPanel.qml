import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../shared"

// Permissions (chmod) dialog. Fifth component extracted from
// core. root.chmodBitSet()/toggleChmodBit() read and wrote
// root.chmodMode directly -- since a separate component does not see that
// "root" (it is its own), the computation of which cell is checked is
// reproduced here locally from the received `mode` property
// (same exact logic as chmodDigit()/chmodBitSet(), only
// parameterized), and changing a cell is requested outward with a
// signal instead of writing the mode directly -- core is still
// the only real owner of root.chmodMode.
//
// The modal wrapper (scrim + card + animation + padding) is
// shared/ModalSurface.qml, common to all dialogs.
Item {
  id: root

  property bool open: false
  property var names: []
  property bool mixed: false
  property string mode: ""
  property bool hasDir: false
  property bool recursive: false

  signal closeRequested()
  signal bitToggled(int ownerIdx, int bit)
  signal recursiveToggled()
  signal applyRequested(string mode)

  function digitAt(ownerIdx) {
    var m = String(root.mode || "0")
    while (m.length < 3) m = "0" + m
    return parseInt(m.substring(m.length - 3).charAt(ownerIdx) || "0", 10)
  }

  function bitSet(ownerIdx, bit) {
    return (root.digitAt(ownerIdx) & bit) !== 0
  }

  ModalSurface {
    open: root.open
    maxWidth: Style.space(320)
    onDismissed: root.closeRequested()

    Text {
      width: parent.width
      text: root.names.length === 1
        ? "Permissions for \"" + root.names[0] + "\""
        : "Permissions for " + root.names.length + " items"
      font.pixelSize: Style.font.title
      font.family: Style.font.family
      font.bold: true
      color: Commons.Color.menu.text
      elide: Text.ElideMiddle
    }

    Text {
      width: parent.width
      visible: root.mixed
      text: "Mixed permissions — choose a mode to apply to all"
      font.pixelSize: Style.font.bodySmall
      font.family: Style.font.family
      // Qt.darker is used in this file for DISABLED text
      // (buttons/rows with no possible action) -- this text is not
      // disabled, it is just a secondary notice, so it
      // gets the same convention (Style.emphasis.secondary) as the
      // rest of the file's secondary text.
      color: Commons.Color.menu.text
      opacity: Style.emphasis.secondary
      wrapMode: Text.WordWrap
    }

    PanelSeparator { foreground: Commons.Color.menu.text; strength: 0.15 }

    // Column header -- empty space to the left of the width of the
    // row label (Owner/Group/Other), then Read/Write/Exec.
    Row {
      width: parent.width
      spacing: Style.spacing.sm

      Item { width: 60; height: 1 }

      Repeater {
        model: ["Read", "Write", "Exec"]

        Text {
          required property string modelData
          width: Style.spacing.controlHeight
          horizontalAlignment: Text.AlignHCenter
          text: modelData
          font.pixelSize: Style.font.caption
          font.family: Style.font.family
          color: Commons.Color.menu.text
          opacity: Style.emphasis.secondary
        }
      }
    }

    // Owner (you) / Group / Other -- each row with its 3 rwx cells,
    // instead of writing the octal by hand. root.mode is still the
    // source of truth (a 3-digit string, real owner in
    // core); each cell queries a bit of it directly and
    // requests changing it with bitToggled().
    Repeater {
      model: [
        { label: "Owner", idx: 0 },
        { label: "Group", idx: 1 },
        { label: "Other", idx: 2 }
      ]

      Row {
        id: chmodRow
        required property var modelData
        width: parent.width
        spacing: Style.spacing.sm

        Text {
          width: 60
          anchors.verticalCenter: parent.verticalCenter
          text: chmodRow.modelData.label
          font.pixelSize: Style.font.subtitle
          font.family: Style.font.family
          color: Commons.Color.menu.text
        }

        Repeater {
          model: [4, 2, 1]

          // CursorSurface instead of a hand-made Rectangle+MouseArea --
          // same component that any other clickable row/tab
          // of the app uses, so the cell has the same
          // hover and the same "selected" (current) treatment
          // as the rest, instead of a separately invented style.
          CursorSurface {
            id: chmodCell
            required property int modelData
            width: Style.spacing.controlHeight
            height: Style.spacing.controlHeight
            anchors.verticalCenter: parent.verticalCenter
            foreground: Commons.Color.menu.text
            accent: Commons.Color.accent
            bordered: true
            hasCursor: chmodCellMouse.containsMouse
            current: root.bitSet(chmodRow.modelData.idx, modelData)

            MouseArea {
              id: chmodCellMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.bitToggled(chmodRow.modelData.idx, chmodCell.modelData)
            }
          }
        }
      }
    }

    PanelSeparator { foreground: Commons.Color.menu.text; strength: 0.15 }

    Text {
      width: parent.width
      text: "Octal: " + root.mode
      font.pixelSize: Style.font.subtitle
      font.family: Style.font.family
      color: Commons.Color.menu.text
      opacity: Style.emphasis.secondary
    }

    Toggle {
      width: parent.width
      visible: root.hasDir
      label: "Apply to subfolders"
      description: "chmod -R -- also changes everything inside"
      checked: root.recursive
      foreground: Commons.Color.menu.text
      accent: Commons.Color.accent
      onClicked: root.recursiveToggled()
    }

    Button {
      text: "Apply"
      bordered: true
      Accessible.role: Accessible.Button
      Accessible.name: text
      onClicked: root.applyRequested(root.mode)
    }
  }
}

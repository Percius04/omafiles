import QtQuick
import qs.Commons
import qs.Ui
import "../shared"
import "../shared/Utils.js" as Utils

// "Bulk rename..." dialog. Sixth component extracted from core.
// The chosen pattern is requested outward with a parameterized signal
// (like ConnectServer.qml/ChmodPanel.qml) -- core is still
// the real owner of root.bulkRenamePattern.
//
// The modal wrapper (scrim + card + animation + padding) is
// shared/ModalSurface.qml, common to all dialogs.
Item {
  id: root

  property bool open: false
  property int selectedCount: 0
  property string pattern: ""
  property var history: []

  signal closeRequested()
  signal renameRequested(string pattern)
  signal focusReturnRequested()

  ModalSurface {
    open: root.open
    maxWidth: Style.space(380)
    onDismissed: root.closeRequested()

    Text {
      width: parent.width
      text: "Rename " + root.selectedCount + " items"
      font.pixelSize: Style.font.title
      font.family: Style.font.family
      font.bold: true
      color: Color.menu.text
    }

    Text {
      width: parent.width
      text: "Use {name}, {ext}, {n} (sequence number)"
      font.pixelSize: Style.font.subtitle
      font.family: Style.font.family
      color: Color.menu.text
      opacity: Style.emphasis.secondary
      wrapMode: Text.Wrap
    }

    TextField {
      id: bulkRenameField
      width: parent.width
      Accessible.role: Accessible.EditableText
      Accessible.name: "Bulk rename pattern"
      readonly property string sampleName: text.replace(/\{name\}/g, "name").replace(/\{ext\}/g, ".txt").replace(/\{n\}/g, "1")
      readonly property bool generatedNameValid: Utils.validBasename(sampleName)
      Accessible.description: generatedNameValid ? "" : "Pattern creates an invalid file name"
      color: generatedNameValid ? Color.menu.text : "#ef4444"
      text: root.pattern
      onVisibleChanged: if (visible) { forceActiveFocus(); selectAll() } else root.focusReturnRequested()
      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          if (generatedNameValid) root.renameRequested(text)
          event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
          root.closeRequested()
          event.accepted = true
        }
      }
    }

    // Previously used patterns, most recent first -- a click fills
    // the field (does not rename directly), so it can be reviewed/
    // adjusted before applying. Only if there is history: the first
    // time Bulk rename is used there is nothing to offer here.
    Flow {
      width: parent.width
      visible: root.history.length > 0
      spacing: Style.spacing.xs

      Repeater {
        model: root.history

        CursorSurface {
          id: patternChip
          required property string modelData
          width: chipText.implicitWidth + Style.spacing.sm * 2
          height: Style.spacing.controlHeight * 0.8
          foreground: Color.menu.text
          accent: Color.accent
          // Without this it was confused with loose text at rest -- the
          // same component already carries a permanent border in the chmod
          // permissions grid (chmodCell) for this exact
          // reason, here it had been forgotten.
          bordered: true
          hasCursor: chipMouse.containsMouse
          Accessible.role: Accessible.Button
          Accessible.name: "Use pattern " + modelData

          Text {
            id: chipText
            anchors.centerIn: parent
            text: patternChip.modelData
            font.pixelSize: Style.font.bodySmall
            font.family: Style.font.family
            color: Color.menu.text
          }

          MouseArea {
            id: chipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              bulkRenameField.text = patternChip.modelData
              bulkRenameField.forceActiveFocus()
              bulkRenameField.selectAll()
            }
          }
        }
      }
    }

    Button {
      text: "Rename"
      bordered: true
      Accessible.role: Accessible.Button
      Accessible.name: text
      enabled: bulkRenameField.generatedNameValid
      onClicked: root.renameRequested(bulkRenameField.text)
    }
  }
}

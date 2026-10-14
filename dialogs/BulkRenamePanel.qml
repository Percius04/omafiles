import QtQuick
import qs.Commons
import qs.Commons as Commons
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
  // Full selected entries (was just selectedCount: int) -- needed for the
  // live preview below, which computes real names via
  // Utils.bulkRenameNames(), the exact same pure function
  // logic/ActionEngine.qml's commitBulkRename() applies for real.
  property var entries: []
  property string pattern: ""
  property string find: ""
  property string replace: ""
  property var history: []

  // Recomputed on every keystroke (bulkRenameField/findField/replaceField's
  // .text are normal QML binding dependencies here, same as any other
  // property read).
  property var _previewNames: Utils.bulkRenameNames(root.entries, bulkRenameField.text, findField.text, replaceField.text)

  signal closeRequested()
  signal renameRequested(string pattern, string find, string replace)
  signal focusReturnRequested()

  ModalSurface {
    open: root.open
    maxWidth: Style.space(380)
    onDismissed: root.closeRequested()

    Text {
      width: parent.width
      text: "Rename " + root.entries.length + " items"
      font.pixelSize: Style.font.title
      font.family: Style.font.family
      font.bold: true
      color: Commons.Color.menu.text
    }

    Text {
      width: parent.width
      text: "Use {name}, {ext}, {n} (sequence number, or {n:3} to zero-pad) — Find/Replace below run first, on the name"
      font.pixelSize: Style.font.subtitle
      font.family: Style.font.family
      color: Commons.Color.menu.text
      opacity: Style.emphasis.secondary
      wrapMode: Text.Wrap
    }

    TextField {
      id: bulkRenameField
      width: parent.width
      Accessible.role: Accessible.EditableText
      Accessible.name: "Bulk rename pattern"
      text: root.pattern
      onVisibleChanged: if (visible) { forceActiveFocus(); selectAll() } else root.focusReturnRequested()
      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.renameRequested(text, findField.text, replaceField.text)
          event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
          root.closeRequested()
          event.accepted = true
        }
      }
    }

    // Regex find/replace (V1.1), applied to the base name (before {name}/
    // {ext}/{n}) -- both optional, an empty Find is a no-op. Same Enter/
    // Escape handling as the pattern field above so either field can be
    // used to confirm/dismiss without a mouse.
    Row {
      width: parent.width
      spacing: Style.spacing.sm

      TextField {
        id: findField
        width: (parent.width - parent.spacing) / 2
        Accessible.role: Accessible.EditableText
        Accessible.name: "Bulk rename find (regex, optional)"
        placeholderText: "Find (regex, optional)"
        text: root.find
        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.renameRequested(bulkRenameField.text, text, replaceField.text)
            event.accepted = true
          } else if (event.key === Qt.Key_Escape) {
            root.closeRequested()
            event.accepted = true
          }
        }
      }

      TextField {
        id: replaceField
        width: (parent.width - parent.spacing) / 2
        Accessible.role: Accessible.EditableText
        Accessible.name: "Bulk rename replace with"
        placeholderText: "Replace with"
        text: root.replace
        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.renameRequested(bulkRenameField.text, findField.text, text)
            event.accepted = true
          } else if (event.key === Qt.Key_Escape) {
            root.closeRequested()
            event.accepted = true
          }
        }
      }
    }

    // Live preview (V1.1): before this, the pattern's actual effect was
    // invisible until confirming -- surprising results (e.g. {ext} on an
    // extensionless file) were only discovered after the fact, past the
    // point where the conflict dialog would have caught anything.
    // Utils.bulkRenameNames() is the exact function commitBulkRename()
    // uses for real, so this can never show something different from
    // what pressing "Rename" actually does. Bounded height + clip: a
    // large selection scrolls instead of pushing the dialog past the
    // window.
    ListView {
      id: previewList
      width: parent.width
      height: Math.min(count * Style.space(22), Style.space(160))
      visible: count > 0
      clip: true
      spacing: 0
      model: root._previewNames
      delegate: Row {
        width: previewList.width
        height: Style.space(22)
        spacing: Style.spacing.xs

        Text {
          width: (parent.width - unchangedTag.width - parent.spacing * 2) / 2
          anchors.verticalCenter: parent.verticalCenter
          text: modelData.oldName
          font.pixelSize: Style.font.bodySmall
          font.family: Style.font.family
          color: Commons.Color.menu.text
          opacity: Style.emphasis.secondary
          elide: Text.ElideMiddle
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "→"
          font.pixelSize: Style.font.bodySmall
          font.family: Style.font.family
          color: Commons.Color.menu.text
          opacity: Style.emphasis.secondary
        }

        Text {
          width: (parent.width - unchangedTag.width - parent.spacing * 2) / 2
          anchors.verticalCenter: parent.verticalCenter
          text: modelData.newName || "(empty — won't be renamed)"
          font.pixelSize: Style.font.bodySmall
          font.family: Style.font.family
          color: modelData.newName ? Commons.Color.menu.text : Commons.Color.urgent
          elide: Text.ElideMiddle
        }

        Text {
          id: unchangedTag
          anchors.verticalCenter: parent.verticalCenter
          visible: modelData.newName === modelData.oldName
          text: "(same)"
          font.pixelSize: Style.font.bodySmall
          font.family: Style.font.family
          color: Commons.Color.menu.text
          opacity: Style.emphasis.secondary
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
          foreground: Commons.Color.menu.text
          accent: Commons.Color.accent
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
            color: Commons.Color.menu.text
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
      onClicked: root.renameRequested(bulkRenameField.text, findField.text, replaceField.text)
    }
  }
}

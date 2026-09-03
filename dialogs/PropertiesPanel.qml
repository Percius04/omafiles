import QtQuick
import qs.Commons
import qs.Ui
import "../shared"

// "Properties" dialog of the selection. Third component extracted
// from core -- read-only (no TextField nor own Process,
// the parent already resolves size/permissions/owner/date on its
// own with the propertiesRequestId race guard), so it only
// needs a close signal, just as simple as ShortcutsHelp.qml.
//
// The modal wrapper (scrim + card + animation + padding) is
// shared/ModalSurface.qml, common to all dialogs.
Item {
  id: root

  property bool open: false
  property bool multi: false
  property int count: 0
  property var entry: null
  property bool sizeLoading: false
  property string size: ""
  property string perms: ""
  property string owner: ""
  property string mtime: ""
  property string btime: ""  // "" hides the Created row (no birth time on this filesystem)

  signal closeRequested()

  ModalSurface {
    open: root.open
    maxWidth: Style.space(360)
    onDismissed: root.closeRequested()

    Text {
      width: parent.width
      text: root.multi
        ? root.count + " items selected"
        : (root.entry ? root.entry.name : "")
      font.pixelSize: Style.font.title
      font.family: Style.font.family
      font.bold: true
      color: Color.menu.text
      elide: Text.ElideMiddle
    }

    PanelSeparator { foreground: Color.menu.text; strength: 0.15 }

    Repeater {
      model: root.multi
        ? [
            { label: "Items", value: String(root.count) },
            { label: "Total size", value: root.sizeLoading ? "Calculating…" : root.size }
          ]
        : [
            { label: "Type", value: root.entry ? (root.entry.type === "dir" ? "Folder" : "File") : "" },
            { label: "Size", value: root.sizeLoading ? "Calculating…" : root.size },
            { label: "Permissions", value: root.perms },
            { label: "Owner", value: root.owner },
            { label: "Modified", value: root.mtime }
          ].concat(root.btime ? [{ label: "Created", value: root.btime }] : [])

      Row {
        required property var modelData
        width: parent.width
        spacing: Style.spacing.sm

        Text {
          // Same adjustment as the audio metadata table: 84 did not
          // reach "Permissions" (it measures as wide as
          // "Sample rate", measured with the real font).
          width: 120
          text: parent.modelData.label
          font.pixelSize: Style.font.subtitle
          font.family: Style.font.family
          color: Color.menu.text
          opacity: Style.emphasis.secondary
        }

        Text {
          width: parent.width - 120 - Style.spacing.sm
          text: parent.modelData.value
          font.pixelSize: Style.font.subtitle
          font.family: Style.font.family
          color: Color.menu.text
          elide: Text.ElideRight
        }
      }
    }

    Button {
      text: "Close"
      bordered: true
      Accessible.role: Accessible.Button
      Accessible.name: text
      onClicked: root.closeRequested()
    }
  }
}

import QtQuick
import qs.Commons
import qs.Ui
import "../shared"

// Merged "Properties" dialog -- combines the read-only property table of
// the old PropertiesPanel with the permission (chmod) editor of the old
// ChmodPanel into a single modal. Both were shown for the same selection
// and each opened its own ModalSurface, so they are collapsed here into
// one card: info up top (fed by PropertiesState), the rwx grid below
// (fed by ChmodState). State is +1'd together by the caller, so the
// dialog opens once and closes both states on dismiss.
//
// The modal wrapper (scrim + card + animation + padding) is
// shared/ModalSurface.qml, common to all dialogs.
Item {
  id: root

  property bool open: false

  // --- Properties (info) section ---
  property bool multi: false
  property int count: 0
  property var entry: null
  property bool sizeLoading: false
  property string size: ""
  property string perms: ""
  property string owner: ""
  property string mtime: ""

  // --- Permissions (chmod) section ---
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
    maxWidth: Style.space(400)
    onDismissed: root.closeRequested()

    Column {
      width: parent.width
      spacing: Style.spacing.md

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

      // ---- Properties info table ----
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
            ]

        Row {
          required property var modelData
          width: parent.width
          spacing: Style.spacing.sm

          Text {
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

      PanelSeparator { foreground: Color.menu.text; strength: 0.15 }

      // ---- Permissions editor ----
      Text {
        width: parent.width
        visible: root.mixed
        text: "Mixed permissions — choose a mode to apply to all"
        font.pixelSize: Style.font.bodySmall
        font.family: Style.font.family
        color: Color.menu.text
        opacity: Style.emphasis.secondary
        wrapMode: Text.WordWrap
      }

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
            color: Color.menu.text
            opacity: Style.emphasis.secondary
          }
        }
      }

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
            color: Color.menu.text
          }

          Repeater {
            model: [4, 2, 1]

            CursorSurface {
              id: chmodCell
              required property int modelData
              width: Style.spacing.controlHeight
              height: Style.spacing.controlHeight
              anchors.verticalCenter: parent.verticalCenter
              foreground: Color.menu.text
              accent: Color.accent
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

      Text {
        width: parent.width
        text: "Octal: " + root.mode
        font.pixelSize: Style.font.subtitle
        font.family: Style.font.family
        color: Color.menu.text
        opacity: Style.emphasis.secondary
      }

      Toggle {
        width: parent.width
        visible: root.hasDir
        label: "Apply to subfolders"
        description: "chmod -R -- also changes everything inside"
        checked: root.recursive
        foreground: Color.menu.text
        accent: Color.accent
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
}
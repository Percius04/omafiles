import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../shared"
import "../shared/Utils.js" as Utils

// "Find duplicates..." dialog. Ninth component extracted to dialogs/,
// same wiring shape as BulkRenamePanel.qml/ChmodPanel.qml: purely
// presentational, fed by props from DialogsState/DuplicatesState, changes
// requested outward via signals -- core/logic/ActionEngine.qml is still
// the real owner of the scan and of DuplicatesState.selected.
//
// The modal wrapper (scrim + card + animation + padding) is
// shared/ModalSurface.qml, common to all dialogs.
Item {
  id: root

  property bool open: false
  property bool scanning: false
  property int filesScanned: 0
  // [{ size: qint64, paths: [string, ...] }, ...], oldest path first per
  // group (see DuplicateFinder.cpp) -- "select all but first" therefore
  // keeps the oldest copy of each group by construction.
  property var groups: []
  property var selected: ({})
  property int selectedCount: 0

  signal closeRequested()
  signal cancelRequested()
  signal toggleRequested(string path)
  signal selectAllButFirstRequested()
  signal trashRequested()

  ModalSurface {
    open: root.open
    maxWidth: Style.space(460)
    // Not dismissable mid-scan -- Escape/scrim-click should not silently
    // orphan a running background scan; use the explicit Cancel button.
    dismissable: !root.scanning
    onDismissed: root.closeRequested()

    Text {
      width: parent.width
      text: root.scanning ? "Scanning for duplicates…" : "Duplicate files"
      font.pixelSize: Style.font.title
      font.family: Style.font.family
      font.bold: true
      color: Commons.Color.menu.text
    }

    // ---------- Scanning ----------
    Row {
      visible: root.scanning
      width: parent.width
      spacing: Style.spacing.sm

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - cancelScanButton.width - parent.spacing
        text: root.filesScanned + " files scanned…"
        font.pixelSize: Style.font.subtitle
        font.family: Style.font.family
        color: Commons.Color.menu.text
        opacity: Style.emphasis.secondary
      }

      Button {
        id: cancelScanButton
        text: "Cancel"
        bordered: true
        anchors.verticalCenter: parent.verticalCenter
        Accessible.role: Accessible.Button
        Accessible.name: text
        onClicked: root.cancelRequested()
      }
    }

    // ---------- Results ----------
    Text {
      visible: !root.scanning && root.groups.length === 0
      width: parent.width
      text: "No duplicate files found here."
      font.pixelSize: Style.font.subtitle
      font.family: Style.font.family
      color: Commons.Color.menu.text
      opacity: Style.emphasis.secondary
    }

    ListView {
      id: groupsList
      visible: !root.scanning && root.groups.length > 0
      width: parent.width
      // Bounded height + clip: a large result set scrolls instead of
      // pushing the dialog past the window (same idea as
      // BulkRenamePanel.qml's previewList).
      height: Math.min(contentHeight, Style.space(360))
      clip: true
      spacing: Style.spacing.md
      model: root.groups

      delegate: Column {
        id: groupColumn
        required property var modelData
        width: groupsList.width
        spacing: Style.spacing.xs

        Text {
          width: parent.width
          text: groupColumn.modelData.paths.length + " copies · " + Utils.formatSize(groupColumn.modelData.size) + " each"
          font.pixelSize: Style.font.subtitle
          font.family: Style.font.family
          font.bold: true
          color: Commons.Color.menu.text
        }

        Repeater {
          model: groupColumn.modelData.paths

          Row {
            id: dupRow
            required property string modelData
            width: groupColumn.width
            spacing: Style.spacing.sm

            // Same small checkbox-square component as ChmodPanel.qml's
            // chmodCell -- the codebase has no dedicated CheckBox, and
            // Ui/Toggle.qml is a full labeled-row control, too wide for a
            // per-file row here.
            CursorSurface {
              id: dupCell
              width: Style.spacing.controlHeight
              height: Style.spacing.controlHeight
              anchors.verticalCenter: parent.verticalCenter
              foreground: Commons.Color.menu.text
              accent: Commons.Color.accent
              bordered: true
              hasCursor: dupCellMouse.containsMouse
              current: !!root.selected[dupRow.modelData]

              MouseArea {
                id: dupCellMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleRequested(dupRow.modelData)
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - dupCell.width - parent.spacing
              text: dupRow.modelData
              font.pixelSize: Style.font.bodySmall
              font.family: Style.font.family
              color: Commons.Color.menu.text
              elide: Text.ElideMiddle
            }
          }
        }
      }
    }

    Row {
      visible: !root.scanning && root.groups.length > 0
      width: parent.width
      spacing: Style.spacing.sm

      Button {
        text: "Select all but first per group"
        bordered: true
        Accessible.role: Accessible.Button
        Accessible.name: text
        onClicked: root.selectAllButFirstRequested()
      }

      Button {
        text: "Trash " + root.selectedCount + " selected"
        bordered: true
        enabled: root.selectedCount > 0
        Accessible.role: Accessible.Button
        Accessible.name: text
        onClicked: root.trashRequested()
      }
    }

    Button {
      visible: !root.scanning
      text: "Close"
      bordered: true
      Accessible.role: Accessible.Button
      Accessible.name: text
      onClicked: root.closeRequested()
    }
  }
}

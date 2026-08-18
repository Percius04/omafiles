import QtQuick
import qs.Commons
import qs.Ui
import "../state"

// Fixed column header for table view. Lives above the ListView so it
// does not scroll with the rows. Click a column to sort by it; click
// the same column again to reverse direction.
Item {
  id: root

  implicitHeight: headerRow.implicitHeight + Style.spacing.sm * 2

  readonly property int iconW: Style.spacing.controlHeight
  readonly property int gap: Style.spacing.rowGap
  readonly property int sizeW: Style.space(ViewState.sizeColPx)
  readonly property int typeW: Style.space(ViewState.typeColPx)
  readonly property int dateW: Style.space(ViewState.dateColPx)
  readonly property int nameW: Math.max(Style.space(48),
    width - Style.spacing.rowPaddingX - iconW - sizeW - typeW - dateW - gap * 4)

  component HeaderCell: Item {
    id: cell
    property string sortKey: ""
    property string label: ""
    property int align: Text.AlignLeft

    implicitHeight: cellText.implicitHeight
    Accessible.role: Accessible.Button
    Accessible.name: "Sort by " + label
    Accessible.onPressAction: SortState.toggleSort(sortKey)

    readonly property bool active: SortState.sortKey === sortKey

    Rectangle {
      anchors.fill: parent
      anchors.margins: -Style.spacing.xs
      visible: cellHover.hovered
      color: Style.hoverFillFor(Color.menu.text, Color.accent)
    }

    Text {
      id: cellText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: cell.label + (cell.active ? (SortState.sortDesc ? " ↓" : " ↑") : "")
      horizontalAlignment: cell.align
      font.pixelSize: Style.font.bodySmall
      font.family: Style.font.family
      font.weight: cell.active ? Font.Medium : Font.Normal
      color: Color.menu.text
      opacity: cell.active ? Style.emphasis.strong : Style.emphasis.secondary
      elide: Text.ElideRight
    }

    HoverHandler { id: cellHover }
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.PointingHandCursor
      onClicked: SortState.toggleSort(cell.sortKey)
    }
  }

  Row {
    id: headerRow
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.rightMargin: Style.spacing.rowPaddingX
    anchors.verticalCenter: parent.verticalCenter
    spacing: root.gap

    Item { width: root.iconW; height: 1 }

    HeaderCell {
      width: root.nameW
      sortKey: "name"
      label: "Name"
    }
    HeaderCell {
      width: root.sizeW
      sortKey: "size"
      label: "Size"
      align: Text.AlignRight
    }
    HeaderCell {
      width: root.typeW
      sortKey: "type"
      label: "Type"
    }
    HeaderCell {
      width: root.dateW
      sortKey: "mtime"
      label: "Date"
    }
  }

  Rectangle {
    anchors.bottom: parent.bottom
    width: parent.width
    height: Style.spacing.hairline
    color: Color.menu.text
    opacity: 0.15
  }
}

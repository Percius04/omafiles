import QtQuick
import qs.Commons
import qs.Ui
import "../state"

// Single-line table row: icon + name + size + type + date.
// Column widths match FileTableHeader via ViewState.
Item {
  id: root

  property string name: ""
  property bool isDir: false
  property bool isBroken: false
  property bool highlighted: false
  property bool dimmed: false
  property string fileIconGlyph: ""
  property url thumbSource: ""
  property string sizeText: ""
  property string typeText: ""
  property string dateText: ""
  property string sizeTooltip: ""
  property bool showNameText: true

  readonly property int iconW: Style.spacing.controlHeight
  readonly property int gap: Style.spacing.rowGap
  readonly property int sizeW: Style.space(ViewState.sizeColPx)
  readonly property int typeW: Style.space(ViewState.typeColPx)
  readonly property int dateW: Style.space(ViewState.dateColPx)

  FontMetrics { id: _nameFM; font.family: Style.font.family; font.pixelSize: Style.font.title; font.weight: Font.Medium }
  implicitHeight: Math.max(Style.spacing.controlHeight, Math.ceil(_nameFM.height))

  readonly property color nameColor: root.isBroken ? Color.urgent
    : root.dimmed ? Qt.darker(Color.menu.text, 1.6)
    : (root.highlighted ? Color.menu.selectedText : Color.menu.text)
  readonly property color metaColor: root.highlighted ? Color.menu.selectedText : Color.menu.text

  Item {
    id: thumbSlot
    clip: true
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: root.iconW
    height: root.iconW

    Image {
      id: thumbImage
      anchors.fill: parent
      visible: status === Image.Ready
      source: root.thumbSource
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      sourceSize.width: 32
      sourceSize.height: 32
    }

    OpticalGlyph {
      anchors.fill: parent
      visible: root.isDir && !root.isBroken
      text: "󰉋"
      fontFamily: Style.font.family
      fontSize: Style.font.iconLarge
      color: root.highlighted ? Color.menu.selectedText : Color.menu.text
    }

    OpticalGlyph {
      anchors.fill: parent
      visible: !root.isDir && !thumbImage.visible && !root.isBroken
      text: root.fileIconGlyph
      fontFamily: Style.font.family
      fontSize: Style.font.iconLarge
      color: root.highlighted ? Color.menu.selectedText : Color.menu.text
    }

    OpticalGlyph {
      anchors.fill: parent
      visible: root.isBroken
      text: "\u{F033A}"
      fontFamily: Style.font.family
      fontSize: Style.font.iconLarge
      color: Color.urgent
    }
  }

  Text {
    id: nameText
    visible: root.showNameText
    anchors.left: thumbSlot.right
    anchors.leftMargin: root.gap
    anchors.right: sizeText.left
    anchors.rightMargin: root.gap
    anchors.verticalCenter: parent.verticalCenter
    text: root.name + (root.isDir ? "/" : "")
    font.pixelSize: Style.font.title
    font.family: Style.font.family
    font.weight: Font.Medium
    color: root.nameColor
    elide: Text.ElideRight
  }

  Text {
    id: sizeText
    width: root.sizeW
    anchors.right: typeText.left
    anchors.rightMargin: root.gap
    anchors.verticalCenter: parent.verticalCenter
    text: root.sizeText
    horizontalAlignment: Text.AlignRight
    font.pixelSize: Style.font.bodySmall
    font.family: Style.font.family
    color: root.metaColor
    opacity: Style.emphasis.secondary
    elide: Text.ElideRight

    HoverHandler { id: sizeHover; enabled: root.sizeTooltip.length > 0 }
    PanelToolTip {
      visible: sizeHover.hovered && root.sizeTooltip.length > 0
      text: root.sizeTooltip
    }
  }

  Text {
    id: typeText
    width: root.typeW
    anchors.right: dateText.left
    anchors.rightMargin: root.gap
    anchors.verticalCenter: parent.verticalCenter
    text: root.typeText
    font.pixelSize: Style.font.bodySmall
    font.family: Style.font.family
    color: root.metaColor
    opacity: Style.emphasis.secondary
    elide: Text.ElideRight
  }

  Text {
    id: dateText
    width: root.dateW
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    text: root.dateText
    font.pixelSize: Style.font.bodySmall
    font.family: Style.font.family
    color: root.metaColor
    opacity: Style.emphasis.secondary
    elide: Text.ElideRight
  }
}

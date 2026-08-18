import QtQuick
import qs.Commons
import qs.Ui
import "../state"

// Icon-view tile: large thumbnail/glyph above a two-line name.
// Cell size is owned by the GridView; this only paints inside it.
Item {
  id: root

  property string name: ""
  property bool isDir: false
  property bool isBroken: false
  property bool highlighted: false
  property bool dimmed: false
  property string fileIconGlyph: ""
  property url thumbSource: ""
  property bool showNameText: true

  readonly property int iconS: Style.space(ViewState.gridIconPx)

  FontMetrics { id: _nameFM; font.family: Style.font.family; font.pixelSize: Style.font.title; font.weight: Font.Medium }
  implicitHeight: iconS + Style.spacing.sm + Math.ceil(_nameFM.height) * 2

  readonly property color nameColor: root.isBroken ? Color.urgent
    : root.dimmed ? Qt.darker(Color.menu.text, 1.6)
    : (root.highlighted ? Color.menu.selectedText : Color.menu.text)

  Item {
    id: thumbSlot
    clip: true
    width: root.iconS
    height: root.iconS
    anchors.top: parent.top
    anchors.horizontalCenter: parent.horizontalCenter

    Image {
      id: thumbImage
      anchors.fill: parent
      visible: status === Image.Ready
      source: root.thumbSource
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      sourceSize.width: root.iconS
      sourceSize.height: root.iconS
    }

    OpticalGlyph {
      anchors.fill: parent
      visible: root.isDir && !root.isBroken
      text: "󰉋"
      fontFamily: Style.font.family
      fontSize: Style.font.display
      color: root.highlighted ? Color.menu.selectedText : Color.menu.text
    }

    OpticalGlyph {
      anchors.fill: parent
      visible: !root.isDir && !thumbImage.visible && !root.isBroken
      text: root.fileIconGlyph
      fontFamily: Style.font.family
      fontSize: Style.font.display
      color: root.highlighted ? Color.menu.selectedText : Color.menu.text
    }

    OpticalGlyph {
      anchors.fill: parent
      visible: root.isBroken
      text: "\u{F033A}"
      fontFamily: Style.font.family
      fontSize: Style.font.display
      color: Color.urgent
    }
  }

  Text {
    id: nameText
    visible: root.showNameText
    anchors.top: thumbSlot.bottom
    anchors.topMargin: Style.spacing.sm
    anchors.left: parent.left
    anchors.right: parent.right
    height: Math.ceil(_nameFM.height) * 2
    text: root.name + (root.isDir ? "/" : "")
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignTop
    wrapMode: Text.Wrap
    maximumLineCount: 2
    elide: Text.ElideRight
    font.pixelSize: Style.font.title
    font.family: Style.font.family
    font.weight: Font.Medium
    color: root.nameColor
  }
}

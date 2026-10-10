import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../shared/Utils.js" as Utils

// Sidebar recent section.
Column {
  id: root

  property var recentFiles: []
  property var iconForBookmark: null
  property var openContextMenu: null
  property Item positionRelativeTo: null

  signal recentOpened(var item)
  signal recentLaunched(var item)
  signal recentRemoveRequested(string path)
  signal recentClearRequested()

  width: parent ? parent.width : 0
  spacing: Style.spacing.md

  Item {
    visible: root.recentFiles.length > 0
    width: 1
    height: Style.spacing.sm
  }

  PanelSeparator {
    visible: root.recentFiles.length > 0
    foreground: Commons.Color.menu.text
    strength: 0.15
  }

  Item {
    visible: root.recentFiles.length > 0
    width: 1
    height: Style.spacing.xs
  }

  PanelSectionHeader {
    visible: root.recentFiles.length > 0
    text: "RECENT"
    foreground: Commons.Color.menu.text
    fontFamily: Style.font.family
    fontSize: Style.font.subtitle + 1
  }

  Item {
    visible: root.recentFiles.length > 0
    width: 1
    height: Style.spacing.xxs
  }

  Repeater {
    model: root.recentFiles

    CursorSurface {
      OpacityAnimator on opacity { from: 0; to: 1; duration: 120; easing.type: Easing.OutCubic }
      required property var modelData
      width: root.width
      implicitHeight: Style.spacing.controlHeight
      foreground: Commons.Color.menu.text
      accent: Commons.Color.accent
      hasCursor: recentMouse.containsMouse
      Accessible.role: Accessible.ListItem
      Accessible.name: "Recent file, " + modelData.name

      OpticalGlyph {
        id: recentIcon
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.sm
        width: Style.font.title + 1
        height: Style.font.title + 1
        text: Utils.iconFor({ type: "file", name: parent.modelData.name })
        fontFamily: Style.font.family
        fontSize: Style.font.icon + 1
        color: Commons.Color.menu.text
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: recentIcon.right
        anchors.leftMargin: Style.spacing.xs
        text: parent.modelData.name
        font.pixelSize: Style.font.title + 1
        font.family: Style.font.family
        font.weight: Font.Medium
        color: Commons.Color.menu.text
        elide: Text.ElideRight
        width: root.width - Style.spacing.sm * 2 - recentIcon.width - Style.spacing.xs
      }

      MouseArea {
        id: recentMouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: function (mouse) {
          if (mouse.button === Qt.RightButton) {
            var pos = mapToItem(root.positionRelativeTo, mouse.x, mouse.y)
            if (root.openContextMenu) {
              root.openContextMenu(pos.x, pos.y, [
                { label: "Open", action: function () { root.recentOpened(modelData) } },
                { label: "Remove from recent", destructive: true, action: function () { root.recentRemoveRequested(modelData.path) } },
                { label: "Clear recent", destructive: true, action: function () { root.recentClearRequested() } }
              ])
            }
            return
          }
          root.recentOpened(modelData)
        }
        onDoubleClicked: root.recentLaunched(modelData)
      }
    }
  }
}

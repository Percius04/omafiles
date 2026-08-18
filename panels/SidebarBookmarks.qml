import QtQuick
import qs.Commons
import qs.Ui
import "../shared/Utils.js" as Utils

// Sidebar bookmarks section.
Column {
  id: root

  property var bookmarks: []
  property string currentPath: ""
  property string dropHoverPath: ""
  property Item positionRelativeTo: null

  property var iconForBookmark: null
  property var openContextMenu: null
  property var bookmarkActionsFor: null

  signal bookmarkOpened(var bookmark)
  signal dropHoverChanged(string path)
  signal filesDropped(var drop, string destPath)

  width: parent ? parent.width : 0
  spacing: Style.spacing.md

  PanelSectionHeader {
    text: "BOOKMARKS"
    foreground: Color.menu.text
    fontFamily: Style.font.family
    fontSize: Style.font.subtitle
  }

  Item {
    width: 1
    height: Style.spacing.xxs
  }

  Repeater {
    model: root.bookmarks

    CursorSurface {
      // Phase 22: appears with a short fade (120 ms) when the delegate is created
      OpacityAnimator on opacity { from: 0; to: 1; duration: 120; easing.type: Easing.OutCubic }
      required property var modelData
      readonly property bool isCurrent: root.currentPath === modelData.path
      width: root.width
      implicitHeight: Style.spacing.controlHeight
      foreground: Color.menu.text
      accent: Color.accent
      hasCursor: bookmarkMouse.containsMouse
      current: isCurrent || root.dropHoverPath === modelData.path
      Accessible.role: Accessible.ListItem
      Accessible.name: "Bookmark, " + modelData.label
      Accessible.selected: isCurrent

      DropArea {
        anchors.fill: parent
        enabled: modelData.type !== "file"
        keys: ["text/uri-list"]
        onEntered: function (drag) {
          root.dropHoverChanged(modelData.path)
        }
        onExited: if (root.dropHoverPath === modelData.path) root.dropHoverChanged("")
        onDropped: function (drop) {
          root.dropHoverChanged("")
          root.filesDropped(drop, modelData.path)
        }
      }

      OpticalGlyph {
        id: bookmarkIcon
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.sm
        width: Style.font.title
        height: Style.font.title
        text: root.iconForBookmark ? root.iconForBookmark(parent.modelData) : ""
        fontFamily: Style.font.family
        fontSize: Style.font.icon
        color: parent.isCurrent ? Color.menu.selectedText : Color.menu.text
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: bookmarkIcon.right
        anchors.leftMargin: Style.spacing.xs
        text: parent.modelData.label
        font.pixelSize: Style.font.title
        font.family: Style.font.family
        font.weight: Font.Medium
        color: parent.isCurrent ? Color.menu.selectedText : Color.menu.text
        elide: Text.ElideRight
        width: root.width - Style.spacing.sm * 2 - bookmarkIcon.width - Style.spacing.xs
      }

      MouseArea {
        id: bookmarkMouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: function (mouse) {
          if (mouse.button === Qt.RightButton) {
            var pos = mapToItem(root.positionRelativeTo, mouse.x, mouse.y)
            if (root.openContextMenu && root.bookmarkActionsFor) {
              root.openContextMenu(pos.x, pos.y, root.bookmarkActionsFor(modelData))
            }
            return
          }
          root.bookmarkOpened(modelData)
        }
      }
    }
  }
}

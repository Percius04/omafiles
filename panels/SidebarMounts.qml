import QtQuick
import qs.Commons
import qs.Ui
import "../shared/Utils.js" as Utils

// Sidebar mounts section.
Column {
  id: root

  property var mounts: []
  property string currentPath: ""
  property string dropHoverPath: ""
  property string ejectingDevice: ""
  property Item positionRelativeTo: null

  property var iconForMount: null
  property var openContextMenu: null
  property var mountActionsFor: null

  signal mountActivated(var mount)
  signal mountEjectRequested(var mount)
  signal dropHoverChanged(string path)
  signal filesDropped(var drop, string destPath)

  width: parent ? parent.width : 0
  spacing: Style.spacing.md
  visible: root.mounts.length > 0

  Item {
    width: 1
    height: Style.spacing.sm
  }

  PanelSeparator {
    foreground: Color.menu.text
    strength: 0.15
  }

  Item {
    width: 1
    height: Style.spacing.xs
  }

  PanelSectionHeader {
    text: "DEVICES"
    foreground: Color.menu.text
    fontFamily: Style.font.family
    fontSize: Style.font.subtitle
  }

  Item {
    width: 1
    height: Style.spacing.xxs
  }

  Repeater {
    model: root.mounts

    CursorSurface {
      // Phase 22: appears with a short fade (120 ms) when the delegate is created
      OpacityAnimator on opacity { from: 0; to: 1; duration: 120; easing.type: Easing.OutCubic }
      required property var modelData
      readonly property bool isCurrent: root.currentPath === modelData.path
      width: root.width
      implicitHeight: Style.spacing.controlHeight
      foreground: Color.menu.text
      accent: Color.accent
      hasCursor: mountMouse.containsMouse
      current: isCurrent || root.dropHoverPath === modelData.path
      Accessible.role: Accessible.ListItem
      Accessible.name: modelData.label + (modelData.mounted ? "" : ", not mounted")
      Accessible.selected: isCurrent

      DropArea {
        anchors.fill: parent
        enabled: modelData.mounted
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
        id: mountIcon
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.sm
        width: Style.font.title
        height: Style.font.title
        opacity: parent.modelData.mounted ? 1.0 : 0.5
        text: root.iconForMount ? root.iconForMount(parent.modelData) : ""
        fontFamily: Style.font.family
        fontSize: Style.font.icon
        color: parent.isCurrent ? Color.menu.selectedText : Color.menu.text
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: mountIcon.right
        anchors.leftMargin: Style.spacing.xs
        opacity: parent.modelData.mounted ? 1.0 : 0.5
        text: parent.modelData.label
        font.pixelSize: Style.font.title
        font.family: Style.font.family
        font.weight: Font.Medium
        color: parent.isCurrent ? Color.menu.selectedText : Color.menu.text
        elide: Text.ElideRight
        width: root.width - Style.spacing.sm * 2 - mountIcon.width - Style.spacing.xs
          - (parent.modelData.removable ? Style.font.title + Style.spacing.sm : 0)
      }

      PanelToolTip {
        visible: mountMouse.containsMouse && !parent.modelData.mounted
        text: "Not mounted -- click to mount"
      }

      MouseArea {
        id: mountMouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: function (mouse) {
          if (mouse.button === Qt.RightButton) {
            var pos = mapToItem(root.positionRelativeTo, mouse.x, mouse.y)
            if (root.openContextMenu && root.mountActionsFor) {
              root.openContextMenu(pos.x, pos.y, root.mountActionsFor(modelData))
            }
            return
          }
          root.mountActivated(modelData)
        }
      }

      Item {
        id: ejectSlot
        readonly property var mount: parent.modelData
        readonly property bool isCurrent: parent.isCurrent
        readonly property bool ejecting: mount.device === root.ejectingDevice
        readonly property bool hovered: mountMouse.containsMouse || ejectMouse.containsMouse
        visible: mount.removable
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        width: Style.font.title
        height: Style.font.title

        OpticalGlyph {
          anchors.verticalCenter: parent.verticalCenter
          anchors.right: parent.right
          anchors.rightMargin: ejectSlot.hovered ? 0 : 3
          width: Style.font.title
          height: Style.font.title
          visible: !ejectSlot.ejecting
          text: "\u{F01EA}" // nf-md-eject
          fontFamily: Style.font.family
          fontSize: Style.font.icon
          color: ejectSlot.isCurrent ? Color.menu.selectedText : Color.menu.text
          opacity: ejectSlot.hovered ? 0.95 : Style.emphasis.muted
          Behavior on opacity { NumberAnimation { duration: 120 } }
          Behavior on anchors.rightMargin { NumberAnimation { duration: 120 } }
        }

        Item {
          id: ejectSpinner
          anchors.centerIn: parent
          width: Style.font.icon
          height: Style.font.icon
          visible: ejectSlot.ejecting
          Rectangle {
            width: 3; height: 3; radius: 1.5
            color: Color.accent
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
          }
          RotationAnimator on rotation {
            running: ejectSpinner.visible
            loops: Animation.Infinite
            from: 0; to: 360; duration: 800
          }
        }

        MouseArea {
          id: ejectMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          enabled: !ejectSlot.ejecting
          onClicked: root.mountEjectRequested(ejectSlot.mount)
        }
      }
    }
  }
}

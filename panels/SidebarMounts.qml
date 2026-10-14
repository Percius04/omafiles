import QtQuick
import qs.Commons
import qs.Commons as Commons
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
    foreground: Commons.Color.menu.text
    strength: 0.15
  }

  Item {
    width: 1
    height: Style.spacing.xs
  }

  PanelSectionHeader {
    text: "DEVICES"
    foreground: Commons.Color.menu.text
    fontFamily: Style.font.family
    fontSize: Style.font.subtitle + 1
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
      // usedFraction is -1 for unmounted entries (nothing to statvfs yet).
      readonly property real usedFraction: modelData.usedFraction !== undefined ? modelData.usedFraction : -1
      readonly property bool hasUsage: usedFraction >= 0
      readonly property real _barHeight: 2
      readonly property real _barGap: Style.spacing.xxs
      readonly property real _extraHeight: hasUsage ? (_barHeight + _barGap) : 0
      width: root.width
      implicitHeight: Style.spacing.controlHeight + _extraHeight
      foreground: Commons.Color.menu.text
      accent: Commons.Color.accent
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
          if (!drag.hasUrls) { drag.accepted = false; return }
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
        anchors.verticalCenterOffset: -parent._extraHeight / 2
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.sm
        width: Style.font.title + 1
        height: Style.font.title + 1
        opacity: parent.modelData.mounted ? 1.0 : 0.5
        text: root.iconForMount ? root.iconForMount(parent.modelData) : ""
        fontFamily: Style.font.family
        fontSize: Style.font.icon + 1
        color: parent.isCurrent ? Commons.Color.menu.selectedText : Commons.Color.menu.text
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: -parent._extraHeight / 2
        anchors.left: mountIcon.right
        anchors.leftMargin: Style.spacing.xs
        opacity: parent.modelData.mounted ? 1.0 : 0.5
        text: parent.modelData.label
        font.pixelSize: Style.font.title + 1
        font.family: Style.font.family
        font.weight: Font.Medium
        color: parent.isCurrent ? Commons.Color.menu.selectedText : Commons.Color.menu.text
        elide: Text.ElideRight
        width: root.width - Style.spacing.sm * 2 - mountIcon.width - Style.spacing.xs
          - (parent.modelData.removable ? Style.font.title + 1 + Style.spacing.sm : 0)
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
        anchors.verticalCenterOffset: -parent._extraHeight / 2
        width: Style.font.title + 1
        height: Style.font.title + 1

        OpticalGlyph {
          anchors.verticalCenter: parent.verticalCenter
          anchors.right: parent.right
          anchors.rightMargin: ejectSlot.hovered ? 0 : 3
          width: Style.font.title + 1
          height: Style.font.title + 1
          visible: !ejectSlot.ejecting
          text: "\u{F01EA}" // nf-md-eject
          fontFamily: Style.font.family
          fontSize: Style.font.icon + 1
          color: ejectSlot.isCurrent ? Commons.Color.menu.selectedText : Commons.Color.menu.text
          opacity: ejectSlot.hovered ? 0.95 : Style.emphasis.muted
          Behavior on opacity { NumberAnimation { duration: 120 } }
          Behavior on anchors.rightMargin { NumberAnimation { duration: 120 } }
        }

        Item {
          id: ejectSpinner
          anchors.centerIn: parent
          width: Style.font.icon + 1
          height: Style.font.icon + 1
          visible: ejectSlot.ejecting
          Rectangle {
            width: 3; height: 3; radius: 1.5
            color: Commons.Color.accent
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

      // Disk-usage bar: only mounted entries have a real path to statvfs
      // (see LocalMounts.cpp's usedFraction), so unmounted "click to mount"
      // rows stay their original height with no bar.
      Item {
        id: usageBar
        readonly property real fraction: Math.max(0, Math.min(1, parent.usedFraction))
        visible: parent.hasUsage
        anchors.left: mountIcon.left
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.sm
        anchors.bottom: parent.bottom
        height: parent._barHeight

        Rectangle {
          anchors.fill: parent
          radius: height / 2
          color: Commons.Color.menu.text
          opacity: Style.emphasis.muted
        }
        Rectangle {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: parent.width * usageBar.fraction
          radius: height / 2
          color: Commons.Color.accent
        }
      }
    }
  }
}

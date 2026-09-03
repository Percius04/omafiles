import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Context menu (right-click). Eighth component extracted from
// core. The actions already arrive as a list of objects
// { label, action, enabled, destructive } built by
// root.itemActions()/emptyAreaActions()/etc. -- each `action` is already a
// function ready to call, so this component does not need
// per-action signals, only to execute it and request closing.
Item {
  id: root

  property bool open: false
  property real menuX: 0
  property real menuY: 0
  property var actions: []

  signal closeRequested()

  // Make sure no stale flyout survives open/close cycles: whenever the menu
  // opens the flyout is cleared so the last opened submenu doesn't linger
  // across invocations; on close the timer is stopped too.
  onOpenChanged: {
    submenuOpen = false
    activeSubmenuIndex = -1
    activeSubmenuItems = []
    _suppressSubmenuClose = false
    _submenuTimer.stop()
  }

  // --- hover flyout submenu state ---
  property int activeSubmenuIndex: -1
  property var activeSubmenuItems: []
  property bool submenuOpen: false
  property real submenuX: 0
  property real submenuY: 0

  // Width/height of the flyout, matching how the main menu sizes itself:
  // label width (FontMetrics) + row spacing + the BorderSurface insets
  // (border + padding), so the surface never clips its rows.
  readonly property real submenuWidth: {
    if (!contextMenu) return 0
    var m = 0
    for (var i = 0; i < root.activeSubmenuItems.length; i++) {
      m = Math.max(m, menuFontMetrics.advanceWidth(root.activeSubmenuItems[i].label))
    }
    return Math.max(160, m + Style.spacing.sm * 2 + contextMenu.contentLeftInset + contextMenu.contentRightInset)
  }
  readonly property real submenuHeight: {
    if (!contextMenu) return 0
    var n = root.activeSubmenuItems.length
    var contentH = n * Style.spacing.controlHeight + Math.max(0, n - 1) * Style.spacing.sm
    var naturalH = contentH + contextMenu.contentTopInset + contextMenu.contentBottomInset
    // Long flyouts (e.g. "Open with" with many registered apps) are capped so
    // the inner Flickable scrolls instead of overflowing the panel.
    var maxH = root.height - submenuY - Style.spacing.lg
    return Math.min(naturalH, Math.max(Style.spacing.controlHeight, maxH))
  }
  // Guards the close-on-exit race: when the pointer slides from the parent
  // row into the flyout, the parent's onExited may fire before the flyout
  // sees the enter. A short grace timer windows that transition.
  property bool _suppressSubmenuClose: false

  function openSubmenu(index, row) {
    if (index < 0 || index >= root.actions.length) return
    if (!root.actions[index].items) return
    var pt = row.mapToItem(root, 0, 0)
    activeSubmenuIndex = index
    activeSubmenuItems = root.actions[index].items
    // Open to the right by default; flip left when it would overflow.
    submenuX = contextMenu.x + contextMenu.width + Style.spacing.xs
    if (submenuX + root.submenuWidth > root.width) submenuX = contextMenu.x - Style.spacing.xs - root.submenuWidth
    submenuY = pt.y
    submenuOpen = true
    _submenuTimer.stop()
    _suppressSubmenuClose = false
  }

  function closeSubmenu() {
    _submenuTimer.stop()
    if (_suppressSubmenuClose) return
    submenuOpen = false
    activeSubmenuIndex = -1
  }

  // Measures the labels WITHOUT instantiating any visible Text -- avoids the
  // problem of depending on real children to compute the width
  // (circular: the width of each row would depend on the menu width, which
  // in turn should depend on the width of each row). Same font that
  // each row's real Text uses (see below).
  FontMetrics {
    id: menuFontMetrics
    font.pixelSize: Style.font.title
    font.family: Style.font.family
    font.weight: Font.Medium
  }

  readonly property real maxLabelWidth: {
    var m = 0
    for (var i = 0; i < root.actions.length; i++) {
      m = Math.max(m, menuFontMetrics.advanceWidth(root.actions[i].label))
    }
    return m
  }

  MouseArea {
    anchors.fill: parent
    visible: root.open
    z: 15
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: root.closeRequested()
    onWheel: function(wheel) { wheel.accepted = true }
  }

  BorderSurface {
    id: contextMenu
    visible: root.open
    x: root.menuX
    y: root.menuY
    width: Math.max(200, root.maxLabelWidth + Style.spacing.sm * 2 + contentLeftInset + contentRightInset)
    height: Math.min(contextMenuColumn.implicitHeight + contentTopInset + contentBottomInset, root.height - root.menuY - Style.spacing.lg)
    radius: Style.cornerRadius
    color: Color.menu.background
    borderSpec: Border.flat(Color.menu.border, Style.normalBorderWidth)
    padding: Style.spacing.popupPadding
    z: 20

      Flickable {
        id: menuFlickable
        anchors.fill: parent
        anchors.topMargin: contextMenu.contentTopInset
        anchors.rightMargin: contextMenu.contentRightInset
        anchors.bottomMargin: contextMenu.contentBottomInset
        anchors.leftMargin: contextMenu.contentLeftInset
        clip: true
        contentHeight: contextMenuColumn.implicitHeight
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: contextMenuColumn
          width: parent.width
          spacing: Style.spacing.sm

          Repeater {
            model: root.actions

            CursorSurface {
              required property int index
              required property var modelData
              readonly property bool actionEnabled: modelData.enabled !== false
              readonly property bool hasSubmenu: !!modelData.items && modelData.items.length > 0
              width: contextMenuColumn.width
              implicitHeight: Style.spacing.controlHeight
              foreground: Color.menu.text
              accent: Color.accent
              hasCursor: itemMouse.containsMouse && actionEnabled

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.sm
                text: parent.modelData.label
                font.pixelSize: Style.font.title
                font.family: Style.font.family
                font.weight: Font.Medium
                color: parent.modelData.destructive ? Color.urgent : (parent.actionEnabled ? Color.menu.text : Qt.darker(Color.menu.text, 1.8))
              }

              // Trailing flyout arrow for submenu-parent rows.
              Text {
                visible: parent.hasSubmenu
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.sm
                text: "\u203A"
                font.pixelSize: Style.font.title
                font.family: Style.font.family
                font.weight: Font.Medium
                color: parent.actionEnabled ? Color.menu.text : Qt.darker(Color.menu.text, 1.8)
                opacity: Style.emphasis.secondary
              }

              MouseArea {
                id: itemMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: parent.actionEnabled
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (parent.hasSubmenu) {
                    root.openSubmenu(parent.index, parent)
                    return
                  }
                  root.closeRequested()
                  parent.modelData.action()
                }
                onEntered: {
                  if (parent.hasSubmenu) root.openSubmenu(parent.index, parent)
                  else if (root.activeSubmenuIndex !== -1) root.closeSubmenu()
                }
                onExited: {
                  if (parent.hasSubmenu && root.activeSubmenuIndex === parent.index) {
                    if (!_submenuTimer.running) _submenuTimer.start()
                  }
                }
              }
            }
          }
        }
      }

      Rectangle {
        visible: root.open && contextMenuColumn.implicitHeight > menuFlickable.height
        anchors.top: menuFlickable.top
        anchors.bottom: menuFlickable.bottom
        anchors.right: menuFlickable.right
        width: Style.space(8)
        color: "transparent"

        Rectangle {
          readonly property real trackLen: parent.height
          readonly property real handleLen: Math.max(26, trackLen * (menuFlickable.height / contextMenuColumn.implicitHeight))
          y: Math.max(0, Math.min(trackLen - handleLen, (trackLen - handleLen) * (menuFlickable.contentY / Math.max(1, contextMenuColumn.implicitHeight - menuFlickable.height))))
          width: parent.width
          height: handleLen
          radius: width / 2
          color: Util.alpha(Color.foreground, 0.28)
        }
      }

      // Grace timer bridging the parent-row-exit -> flyout-enter transition.
      Timer {
        id: _submenuTimer
        interval: 150
        onTriggered: {
          if (!_suppressSubmenuClose) root.closeSubmenu()
          _suppressSubmenuClose = false
        }
      }
    }

    // ---- Hover flyout submenu (sibling of the menu, may overflow it) ----
    BorderSurface {
      visible: root.submenuOpen && root.open
      x: root.submenuX
      y: root.submenuY
      width: root.submenuWidth
      height: root.submenuHeight
      radius: Style.cornerRadius
      color: Color.menu.background
      borderSpec: Border.flat(Color.menu.border, Style.normalBorderWidth)
      padding: Style.spacing.popupPadding
      z: 30

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onEntered: {
          root._suppressSubmenuClose = true
          _submenuTimer.stop()
        }
        onExited: root.closeSubmenu()
      }

      // Inner scrollable list matching the main menu's Flickable, so long
      // flyouts scroll rather than overflow the panel.
      Flickable {
        id: submenuFlickable
        anchors.fill: parent
        anchors.topMargin: parent.contentTopInset
        anchors.rightMargin: parent.contentRightInset
        anchors.bottomMargin: parent.contentBottomInset
        anchors.leftMargin: parent.contentLeftInset
        clip: true
        contentHeight: submenuColumn.implicitHeight
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: submenuColumn
          width: parent.width
          spacing: Style.spacing.sm

          Repeater {
            model: root.activeSubmenuItems

            CursorSurface {
              required property var modelData
              width: submenuColumn.width
              implicitHeight: Style.spacing.controlHeight
              foreground: Color.menu.text
              accent: Color.accent
              hasCursor: subMouse.containsMouse

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.sm
                text: parent.modelData.label
                font.pixelSize: Style.font.title
                font.family: Style.font.family
                font.weight: Font.Medium
                color: parent.modelData.destructive ? Color.urgent : Color.menu.text
              }

              MouseArea {
                id: subMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root._suppressSubmenuClose = true
                onClicked: {
                  root.closeRequested()
                  parent.modelData.action()
                }
              }
            }
          }
        }
      }

      Rectangle {
        visible: root.submenuOpen && submenuColumn.implicitHeight > submenuFlickable.height
        anchors.top: submenuFlickable.top
        anchors.bottom: submenuFlickable.bottom
        anchors.right: submenuFlickable.right
        width: Style.space(8)
        color: "transparent"

        Rectangle {
          readonly property real trackLen: parent.height
          readonly property real handleLen: Math.max(26, trackLen * (submenuFlickable.height / submenuColumn.implicitHeight))
          y: Math.max(0, Math.min(trackLen - handleLen, (trackLen - handleLen) * (submenuFlickable.contentY / Math.max(1, submenuColumn.implicitHeight - submenuFlickable.height))))
          width: parent.width
          height: handleLen
          radius: width / 2
          color: Util.alpha(Color.foreground, 0.28)
        }
      }
    }
  }

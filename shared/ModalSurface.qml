import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Omafiles' shared modal surface: darkened scrim + animated
// centered card. Unifies the background, the open/close animation, the
// radius, border, color and padding of ALL the centered dialogs of
// the app, so they are perceived as a single family (Visual Sprint 2 --
// findings A-01/A-03/B-02 of VISUAL_AUDIT_V1). Previously each dialog repeated
// this wrapper nearly identically (backdrop MouseArea + card BorderSurface +
// Behaviors + Column with insets), with small divergences (spacing xs/sm,
// fixed height with dead space, and NO visible scrim except in ConfirmDialog).
//
// Each dialog keeps its own API (open + signals + content) and only
// delegates the visual look here: it instantiates ModalSurface, sets its maxWidth and
// puts its content inside; the scrim, the animation and the padding are no longer
// repeated in each file.
//
// The scrim uses EXACTLY the same value as qs.Ui/ConfirmDialog
// (Util.alpha(Color.background, 0.7)) -- which cannot be touched (qs.Ui
// shared) -- so the darkened background is identical wherever the dialog
// comes from.
Item {
  id: root
  anchors.fill: parent

  property bool open: false
  // Maximum width of the card (each dialog chooses its own according to its
  // content). The HEIGHT always comes from the content, bounded to the window.
  property real maxWidth: Style.space(360)
  // Some dialogs block the click-outside close in certain states
  // (e.g. ConnectServer while connecting). false disables it.
  property bool dismissable: true
  // Content of the card: it is placed as children of the inner Column, with
  // the same spacing for all.
  default property alias content: contentColumn.data

  // Click on the scrim (outside the card).
  signal dismissed()

  // Single duration/curve of the modal family: 120 ms OutCubic,
  // no overshoot, entry and exit equal, scrim and card synchronized.
  readonly property int transitionDuration: 120

  Rectangle {
    id: scrim
    anchors.fill: parent
    color: Util.alpha(Commons.Color.background, 0.7)
    opacity: root.open ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: root.transitionDuration; easing.type: Easing.OutCubic } }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      enabled: root.open
      onClicked: if (root.dismissable) root.dismissed()
    }
  }

  BorderSurface {
    id: card
    visible: root.open || opacity > 0
    width: Math.min(parent.width - Style.space(32), root.maxWidth)
    // Sized by content (implicitHeight, intrinsic -> does not create a cycle with
    // the Column's real height), bounded to the window. This way no dialog
    // reserves extra dead space (previously ShortcutsHelp fixed 460).
    height: Math.min(parent.height - Style.space(32),
                     contentColumn.implicitHeight + contentTopInset + contentBottomInset)
    anchors.centerIn: parent
    opacity: root.open ? 1 : 0
    scale: root.open ? 1 : 0.98
    Behavior on opacity { NumberAnimation { duration: root.transitionDuration; easing.type: Easing.OutCubic } }
    Behavior on scale { NumberAnimation { duration: root.transitionDuration; easing.type: Easing.OutCubic } }
    radius: Style.cornerRadius
    color: Commons.Color.menu.background
    borderSpec: Border.flat(Commons.Color.menu.border, Style.normalBorderWidth)
    padding: Style.spacing.panelPadding

    // Eats clicks inside the card so they do not close the dialog.
    MouseArea { anchors.fill: parent; onClicked: {} }

    Column {
      id: contentColumn
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
      spacing: Style.spacing.sm
    }
  }
}

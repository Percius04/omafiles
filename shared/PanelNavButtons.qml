import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Navigation buttons (back/forward/up) -- fourteenth component
// extracted from core, shared between the active and background panels.
// Previously each button existed twice (one in navRow, another in bgHeaderRow)
// with the same glyph/size, and only what function of root
// they called and from what property they got the "disabled" (grey) changed. Here that
// is three signals and three booleans that the caller already resolves.
Row {
  id: root

  property bool canGoBack: false
  property bool canGoForward: false
  property bool canGoUp: false
  signal backRequested()
  signal forwardRequested()
  signal upRequested()

  spacing: Style.spacing.controlGap

  Button {
    width: Style.spacing.controlHeight
    height: Style.spacing.controlHeight
    anchors.verticalCenter: parent.verticalCenter
    foreground: root.canGoBack ? Commons.Color.menu.text : Qt.darker(Commons.Color.menu.text, 1.6)
    onClicked: root.backRequested()
    Accessible.role: Accessible.Button
    Accessible.name: "Back"

    OpticalGlyph {
      anchors.centerIn: parent
      // md-arrow_left, verified against the font's real cmap.
      text: "\u{F004D}"
      fontFamily: Style.font.family
      fontSize: Style.font.icon
      color: parent.foreground
    }
  }

  Button {
    width: Style.spacing.controlHeight
    height: Style.spacing.controlHeight
    anchors.verticalCenter: parent.verticalCenter
    foreground: root.canGoForward ? Commons.Color.menu.text : Qt.darker(Commons.Color.menu.text, 1.6)
    onClicked: root.forwardRequested()
    Accessible.role: Accessible.Button
    Accessible.name: "Forward"

    OpticalGlyph {
      anchors.centerIn: parent
      // md-arrow_right, verified against the font's real cmap.
      text: "\u{F0054}"
      fontFamily: Style.font.family
      fontSize: Style.font.icon
      color: parent.foreground
    }
  }

  Button {
    width: Style.spacing.controlHeight
    height: Style.spacing.controlHeight
    anchors.verticalCenter: parent.verticalCenter
    foreground: root.canGoUp ? Commons.Color.menu.text : Qt.darker(Commons.Color.menu.text, 1.6)
    onClicked: root.upRequested()
    Accessible.role: Accessible.Button
    Accessible.name: "Up"

    OpticalGlyph {
      anchors.centerIn: parent
      text: "󰅃"
      fontFamily: Style.font.family
      fontSize: Style.font.icon
      color: parent.foreground
    }
  }
}

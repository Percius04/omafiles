import QtQuick
import qs.Commons
import qs.Commons as Commons

// Empty state ("Nothing here yet" / "Trash is empty" / "No results
// for...") -- thirteenth component extracted from core, and the second
// (after FileRowVisual.qml) that unifies the active and background panels
// instead of just relocating code.
//
// BEWARE when touching this: `centerOn` is the real cause of a bug already caught
// once this same session -- the icon/text "jumped" position when
// hovering between panels because the active panel centered
// over a container that included the header (navRow/breadcrumb) and the
// background one over one that did not. Here there is only one component, so it can
// no longer desynchronize -- but whoever uses it must ALWAYS
// pass the panel's real ListView (list/bgList), never a wider
// container, or the bug returns.
Column {
  id: root

  property Item centerOn: null
  property string message: ""
  property string subMessage: ""

  anchors.centerIn: root.centerOn
  width: root.centerOn ? root.centerOn.width : 0
  spacing: Style.spacing.sm

  Text {
    text: "\u{F0209}"
    color: Commons.Color.menu.selectedText
    opacity: Style.emphasis.strong
    font.family: Style.font.family
    font.pixelSize: Style.font.displayLarge
    horizontalAlignment: Text.AlignHCenter
    width: parent.width
  }

  Text {
    text: root.message
    color: Commons.Color.menu.text
    opacity: Style.emphasis.strong
    font.family: Style.font.family
    font.pixelSize: Style.font.title
    horizontalAlignment: Text.AlignHCenter
    width: parent.width
  }

  Text {
    visible: root.subMessage !== ""
    text: root.subMessage
    color: Commons.Color.menu.text
    opacity: Style.emphasis.secondary
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    horizontalAlignment: Text.AlignHCenter
    width: parent.width
  }
}

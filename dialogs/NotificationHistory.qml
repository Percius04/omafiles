import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import Omafiles.Backend as Backend
import "../shared"
import "../shared/Utils.js" as Utils

// Recent-notifications overlay (Alt+N) -- V1.1. Same componentization
// pattern as dialogs/ShortcutsHelp.qml (its header comment explains why:
// isolated, no Process/async, a single external property). Reads
// Backend.Notifier.history directly (it's a QML_SINGLETON, unlike the
// per-instance data ShortcutsHelp needs passed in from core) -- newest
// first, capped at 50 by the backend.
//
// This exists because a missed desktop toast (notify-send historically,
// now org.freedesktop.Notifications) left no way to find out afterward
// what, if anything, had happened -- the concrete gap behind the
// unreproduced "Trash freeze" report (docs/audits/V1_1_FEATURE_INVENTORY.md
// §6/§9headline 2). Deliberately not actionable (no inline buttons) and
// not persisted across restarts -- a reliability fix, not a notification
// center.
Item {
  id: root

  property bool open: false
  signal requestClose()

  ModalSurface {
    open: root.open
    maxWidth: Style.space(420)
    onDismissed: root.requestClose()

    Row {
      width: parent.width

      Text {
        width: parent.width - clearButton.width
        text: "Recent notifications"
        font.pixelSize: Style.font.title
        font.family: Style.font.family
        font.bold: true
        color: Commons.Color.menu.text
      }

      Button {
        id: clearButton
        text: "Clear"
        bordered: true
        visible: Backend.Notifier.history.length > 0
        Accessible.role: Accessible.Button
        Accessible.name: text
        onClicked: Backend.Notifier.clearHistory()
      }
    }

    PanelSeparator { foreground: Commons.Color.menu.text; strength: 0.15 }

    Text {
      width: parent.width
      visible: Backend.Notifier.history.length === 0
      text: "No notifications yet."
      font.pixelSize: Style.font.bodySmall
      font.family: Style.font.family
      color: Commons.Color.menu.text
      opacity: Style.emphasis.secondary
    }

    Flickable {
      width: parent.width
      // Same fixed-scroll-area-not-card approach as ShortcutsHelp: the
      // card sizes to title + button + this, no dead space below.
      height: 320
      visible: Backend.Notifier.history.length > 0
      clip: true
      contentWidth: width
      contentHeight: historyColumn.implicitHeight
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: historyColumn
        width: parent.width
        spacing: Style.spacing.xs

        Repeater {
          model: Backend.Notifier.history

          Column {
            required property var modelData
            width: historyColumn.width

            Text {
              width: parent.width
              text: parent.modelData.text
              font.pixelSize: Style.font.bodySmall
              font.family: Style.font.family
              color: Commons.Color.menu.text
              wrapMode: Text.Wrap
            }

            Text {
              width: parent.width
              text: Utils.relativeTime(parent.modelData.timestamp)
              font.pixelSize: Style.font.caption
              font.family: Style.font.family
              color: Commons.Color.menu.text
              opacity: Style.emphasis.secondary
            }

            PanelSeparator { foreground: Commons.Color.menu.text; strength: 0.08 }
          }
        }
      }
    }

    Button {
      id: closeHistoryButton
      text: "Close"
      bordered: true
      Accessible.role: Accessible.Button
      Accessible.name: text
      onClicked: root.requestClose()
    }
  }
}

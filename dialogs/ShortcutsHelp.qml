import QtQuick
import qs.Commons
import qs.Ui
import "../shared"

// Keyboard shortcuts help overlay ("?" key). Extracted from
// core as the first step of an incremental componentization --
// this one was chosen for being the most isolated piece of the file: no
// Process/async, no touching disk, a single external property (whether it is
// open) and a single action outward (request closing). The rest of the
// file is still the real owner of root.shortcutsHelpOpen; this
// component only reflects it.
//
// The modal wrapper (scrim + card + animation + padding) is
// shared/ModalSurface.qml, common to all dialogs. The card
// adjusts to the content (title + list of 320 + button), instead of a
// fixed height that left dead space below the Close button (B-01).
Item {
  id: root

  property bool open: false
  signal requestClose()

  ModalSurface {
    open: root.open
    maxWidth: Style.space(420)
    onDismissed: root.requestClose()

    Text {
      width: parent.width
      text: "Keyboard shortcuts"
      font.pixelSize: Style.font.title
      font.family: Style.font.family
      font.bold: true
      color: Color.menu.text
    }

    PanelSeparator { foreground: Color.menu.text; strength: 0.15 }

    Flickable {
      width: parent.width
      // Fixed height of the scroll AREA (not the card): it leaves room
      // for the ~27 rows so it hardly ever scrolls, and the card
      // adjusts to this + title + button (no dead space).
      height: 320
      clip: true
      contentWidth: width
      contentHeight: shortcutsHelpRepeaterColumn.implicitHeight
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: shortcutsHelpRepeaterColumn
        width: parent.width
        spacing: Style.spacing.xs

        // Same order as the table of the "Keyboard
        // shortcuts" section of the README -- if a shortcut is added/edited there,
        // do it here too.
        Repeater {
          model: [
            { key: "j / k / ↓ / ↑", action: "Move down / up" },
            { key: "Shift+j / k / ↓ / ↑", action: "Extend selection down / up" },
            { key: "h / Backspace", action: "Go up a directory" },
            { key: "l / Enter", action: "Open (enter directory / launch file)" },
            { key: "Alt+← / Alt+→", action: "Back / forward (per panel)" },
            { key: "gg / Shift+G", action: "Jump to top / bottom" },
            { key: "Space", action: "Toggle preview (Quick Look)" },
            { key: "/ · Ctrl+F", action: "Search files (name; content: to search inside)" },
            { key: ": / Ctrl+P", action: "Command palette" },
            { key: "Ctrl+A", action: "Select all" },
            { key: "Ctrl+Shift+A", action: "Select none" },
            { key: "Ctrl+I", action: "Invert selection" },
            { key: "F2", action: "Rename" },
            { key: "Delete", action: "Delete (to trash)" },
            { key: "Ctrl+C / Ctrl+X / Ctrl+V", action: "Copy / cut / paste" },
            { key: "Ctrl+Z", action: "Undo" },
            { key: "Ctrl+Shift+Z / Ctrl+Y", action: "Redo" },
            { key: "s / Shift+S", action: "Cycle sort field / reverse order" },
            { key: "v", action: "Cycle view (list / table / icons)" },
            { key: "Ctrl+L", action: "Edit path (Tab completes, ↑/↓ pick)" },
            { key: "Ctrl+Shift+N", action: "New folder" },
            { key: "Ctrl+N", action: "New file" },
            { key: "Ctrl+T / Ctrl+\\", action: "New panel" },
            { key: "Ctrl+W / Ctrl+Tab", action: "Close active panel / next panel" },
            { key: "Ctrl+H", action: "Toggle hidden files" },
            { key: "Shift+Enter", action: "Open a terminal here" },
            { key: "F5", action: "Refresh" },
            { key: "?", action: "Toggle this help" },
            { key: "Escape", action: "Close search, preview, or the active panel" }
          ]

          Row {
            required property var modelData
            width: shortcutsHelpRepeaterColumn.width
            spacing: Style.spacing.sm

            Text {
              width: 170
              text: parent.modelData.key
              font.pixelSize: Style.font.bodySmall
              font.family: Style.font.family
              color: Color.menu.text
              opacity: Style.emphasis.strong
              wrapMode: Text.Wrap
            }

            Text {
              width: parent.width - 170 - Style.spacing.sm
              text: parent.modelData.action
              font.pixelSize: Style.font.bodySmall
              font.family: Style.font.family
              color: Color.menu.text
              wrapMode: Text.Wrap
            }
          }
        }
      }
    }

    Button {
      id: closeShortcutsButton
      text: "Close"
      bordered: true
      Accessible.role: Accessible.Button
      Accessible.name: text
      onClicked: root.requestClose()
    }
  }
}

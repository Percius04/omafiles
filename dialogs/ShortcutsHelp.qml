import QtQuick
import qs.Commons
import qs.Commons as Commons
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
  // Effective bindings (defaults + any valid ~/.config/omafiles/keybindings.toml
  // overrides), one row per resolver-tracked action -- passed in by
  // core/DialogLayer.qml from controllers.keybindingResolver.effectiveBindingsList()
  // (P2.5, 2026-08-17). Replaces the old hand-maintained copy of the shortcut
  // table that used to live only here and drift from the actual code/README.
  property var bindings: []
  signal requestClose()

  // The two-key "gg" chord and Escape aren't resolver actions (see
  // logic/KeybindingResolver.qml's header: both stay hardcoded, not simple
  // "key -> action" bindings), so they're not in `bindings` -- listed here
  // by hand instead. Same for the Shift+arrow extend-selection quirk,
  // documented accurately (Shift+j/k do NOT extend, only Shift+Down/Up do --
  // see state/KeyboardDefaults.qml's header for why).
  readonly property var structuralRows: [
    { key: "gg", action: "Jump to top (press g twice)" },
    { key: "Shift+Down / Shift+Up", action: "Extend selection down / up" },
    { key: "Escape", action: "Close search, preview, or the active panel" }
  ]

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
      color: Commons.Color.menu.text
    }

    PanelSeparator { foreground: Commons.Color.menu.text; strength: 0.15 }

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

        // Effective bindings: resolver-tracked actions (defaults, or the
        // user's keybindings.toml overrides where valid) plus the handful
        // of structural entries that aren't resolver actions. This is no
        // longer a separately hand-maintained list -- see `bindings` above.
        Repeater {
          model: root.structuralRows.concat(root.bindings)

          Row {
            required property var modelData
            width: shortcutsHelpRepeaterColumn.width
            spacing: Style.spacing.sm

            Text {
              width: 170
              text: parent.modelData.key
              font.pixelSize: Style.font.bodySmall
              font.family: Style.font.family
              color: Commons.Color.menu.text
              opacity: Style.emphasis.strong
              wrapMode: Text.Wrap
            }

            Text {
              width: parent.width - 170 - Style.spacing.sm
              text: parent.modelData.action
              font.pixelSize: Style.font.bodySmall
              font.family: Style.font.family
              color: Commons.Color.menu.text
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

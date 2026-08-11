import QtQuick
import qs.Commons
import qs.Ui
import "../shared"

// Overlay de ayuda de atajos de teclado (tecla "?"). Extraído de
// Omafiles.qml como primer paso de un componentizado incremental --
// se eligió este por ser el trozo más aislado del fichero: sin
// Process/async, sin tocar disco, una sola propiedad externa (si está
// abierto) y una sola acción hacia fuera (pedir cerrarse). El resto del
// fichero sigue siendo el dueño real de root.shortcutsHelpOpen; este
// componente solo lo refleja.
//
// El envoltorio modal (scrim + tarjeta + animación + padding) es
// shared/ModalSurface.qml, común a todos los diálogos. La tarjeta se
// ajusta al contenido (título + lista de 320 + botón), en vez de una
// altura fija que dejaba hueco muerto debajo del botón Close (B-01).
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
      // Altura fija de la ZONA de scroll (no de la tarjeta): deja sitio
      // para las ~27 filas sin que haga scroll casi nunca, y la tarjeta
      // se ajusta a esto + título + botón (sin hueco muerto).
      height: 320
      clip: true
      contentWidth: width
      contentHeight: shortcutsHelpRepeaterColumn.implicitHeight
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: shortcutsHelpRepeaterColumn
        width: parent.width
        spacing: Style.spacing.xs

        // Mismo orden que la tabla de la sección "Keyboard
        // shortcuts" del README -- si se añade/edita un atajo ahí,
        // hacerlo aquí también.
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

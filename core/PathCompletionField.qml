import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../state"
import Omafiles.Backend as Backend

// Address bar with NATIVE autocompletion (Ctrl+L, Phase 26). Replaces the
// standalone TextField that was in MainLayout: same base behaviour (Enter
// navigates, Escape cancels) plus a live suggestions dropdown, Tab to
// complete the segment and arrows to walk the options. All the path
// resolution is C++ (Omafiles.Backend.PathCompleter -> QDir), without external processes:
// it resolves ~, absolute paths and paths relative to the current folder.
//
// Lives in core/, not shared/ (architectural audit 2026-08-17, P2.1
// follow-up): it reads NavState/EditModeState and calls
// Backend.PathCompleter directly, which shared/ components are not
// allowed to do (see docs/architecture/ARCHITECTURE.md's dependency
// rules); its only consumer (core/MainLayout.qml) already lives in
// core/, where that restriction doesn't apply -- so relocating removed
// the violation instead of adding property/signal plumbing for a
// decoupling nothing else currently needs.
Item {
  id: field
  property Item root: null
  property var navController: null
  property Item list: null // to return focus on hiding

  property var suggestions: []
  property int highlight: -1
  // The dropdown is only shown with the field focused and with something to suggest. On
  // opening it does NOT autocomplete (the field carries the current path selected): the
  // suggestions appear as soon as the user types.
  readonly property bool dropdownVisible: input.activeFocus && suggestions.length > 0

  // The focus/selection is triggered from HERE (not from input.onVisibleChanged):
  // `visible` is a property of this root Item (set by MainLayout with
  // editingPath); the inner TextField's local `visible` never changes, so
  // its onVisibleChanged would not fire on opening.
  onVisibleChanged: {
    if (visible) {
      input.text = NavState.currentPath
      input.forceActiveFocus()
      input.selectAll()
    } else {
      suggestions = []
      if (list)
        list.forceActiveFocus()
    }
  }

  function refresh() {
    suggestions = Backend.PathCompleter.complete(input.text, NavState.currentPath)
    highlight = suggestions.length > 0 ? 0 : -1
  }

  function fillWith(path) {
    input.text = path
    input.cursorPosition = path.length
  }

  // Tab: accepts the highlighted suggestion and re-completes -> shows the content of
  // the just-chosen folder, ready to go down another segment.
  function acceptHighlighted() {
    if (highlight < 0 || highlight >= suggestions.length)
      return
    fillWith(suggestions[highlight])
    refresh()
  }

  function navigate(target) {
    var dest = Backend.PathCompleter.expandTilde(target)
    if (navController) navController.navigateTo(dest)
    else if (root && root.navigateTo) root.navigateTo(dest)
    EditModeState.editingPath = false
  }

  TextField {
    id: input
    anchors.fill: parent
    verticalPadding: 2
    Accessible.role: Accessible.EditableText
    Accessible.name: "Path"
    // The kit's default TextField background is a subtle alpha wash (8%
    // fill / 25% border, Style.controlFill/controlBorder) -- fine for a
    // field sitting inside an already-boxed surface (dialogs, forms), but
    // here it replaces the breadcrumb directly in the toolbar with nothing
    // else behind it, and the suggestion dropdown right below (same file)
    // is already solid (Color.menu.background + Border.flat), so the field
    // read as "no background" against it. Same solid treatment as the
    // dropdown it belongs to, not a new theme.
    background: BorderSurface {
      color: Commons.Color.menu.background
      borderSpec: Border.flat(Commons.Color.menu.border, Style.normalBorderWidth)
      radius: Style.cornerRadius
    }
    // Only when the user types (not when fillWith/onVisibleChanged assign
    // text by code: onTextEdited does not fire with programmatic assignments).
    onTextEdited: field.refresh()
    Keys.onPressed: function (event) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        field.navigate(field.dropdownVisible && field.highlight >= 0
          ? field.suggestions[field.highlight] : input.text)
        event.accepted = true
      } else if (event.key === Qt.Key_Escape) {
        EditModeState.editingPath = false
        event.accepted = true
      } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
        field.acceptHighlighted()
        event.accepted = true
      } else if (event.key === Qt.Key_Down) {
        if (field.suggestions.length > 0) {
          field.highlight = Math.min(field.suggestions.length - 1, field.highlight + 1)
          suggestList.positionViewAtIndex(field.highlight, ListView.Contain)
        }
        event.accepted = true
      } else if (event.key === Qt.Key_Up) {
        if (field.suggestions.length > 0) {
          field.highlight = Math.max(0, field.highlight - 1)
          suggestList.positionViewAtIndex(field.highlight, ListView.Contain)
        }
        event.accepted = true
      }
    }
  }

  // Floating dropdown below the field. High z: it is drawn OVER the file
  // list; no ancestor of the active panel clips (verified).
  BorderSurface {
    id: dropdown
    visible: field.dropdownVisible
    z: 50
    anchors.top: input.bottom
    anchors.topMargin: 2
    anchors.left: input.left
    width: input.width
    height: Math.min(suggestList.contentHeight + 2 * Style.spacing.xs, 240)
    radius: Style.cornerRadius
    color: Commons.Color.menu.background
    borderSpec: Border.flat(Commons.Color.menu.border, Style.normalBorderWidth)

    ListView {
      id: suggestList
      anchors.fill: parent
      anchors.margins: Style.spacing.xs
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      model: field.suggestions

      delegate: CursorSurface {
        required property var modelData
        required property int index
        width: suggestList.width
        implicitHeight: Style.spacing.controlHeight
        foreground: Commons.Color.menu.text
        accent: Commons.Color.accent
        hasCursor: index === field.highlight

        Text {
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: parent.left
          anchors.leftMargin: Style.spacing.sm
          anchors.right: parent.right
          anchors.rightMargin: Style.spacing.sm
          elide: Text.ElideMiddle
          text: parent.modelData
          font.pixelSize: Style.font.body
          font.family: Style.font.family
          color: parent.index === field.highlight ? Commons.Color.menu.selectedText : Commons.Color.menu.text
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: field.highlight = parent.index
          onClicked: field.navigate(parent.modelData)
        }
      }
    }
  }
}

import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../state"

// Expandable search magnifier of the top bar. At
// rest only the magnifier is shown, stuck to the right edge of navRow; on activating it
// (click or Ctrl+F) the field unfolds TO THE LEFT with a smooth
// animation, eating width from the breadcrumb (which MainLayout shrinks, never to 0:
// the path stays visible, truncated). It's not a new search system:
// it reuses SearchOps/SearchWorker (incremental recursive search from the
// current folder, results in NavState.entries = the same active panel).
//
// It lives in panels/ (not shared/) because it reads NavState and calls searchOps: the
// panels/ layer = can read state/ and drive injected logic/, just like
// Search input and live filter bar.
// and Qt6): there is nothing host-specific here.
Item {
  id: sb

  // Injected by MainLayout (ActiveFileList pattern, not root.*).
  property Item list: null
  property var searchOps: null
  property var navController: null

  // Maximum width that MainLayout leaves for the expanded field (what's left
  // after reserving a minimum for the breadcrumb) -- so in narrow windows
  // the magnifier expands less and the path never disappears.
  property real maxWidth: 300

  readonly property int collapsedW: Style.spacing.controlHeight
  readonly property int expandedW: Math.max(collapsedW, Math.min(300, maxWidth))

  height: Style.spacing.controlHeight
  width: NavState.searching ? expandedW : collapsedW
  // Smooth expand/collapse (200-250 ms) to the left: the magnifier stays
  // fixed to the right because MainLayout anchors this component at the end of
  // navRow and shrinks the breadcrumb in its place.
  Behavior on width { enabled: !NavState.suppressSearchAnim; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

  function expand() {
    if (NavState.searching) { field.forceActiveFocus(); return }
    searchOps.startSearch() // searching=true, query="" -> the field becomes visible and takes focus
  }
  function collapse() {
    searchOps.exitSearch() // searching=false, cancels, clears, refreshes, deselects
  }

  // Set around the field's OWN Up/Down handling below so the Connections
  // just under this don't mistake the search field's own result
  // navigation for "the user clicked something else."
  property bool _selfSelect: false

  // Real fix for "click something else with an empty search -> close it":
  // onActiveFocusChanged further down only fires if Qt's keyboard focus
  // actually MOVES away from the field, but clicking a file row, a sidebar
  // bookmark/mount, or a breadcrumb segment never calls forceActiveFocus()
  // on its own MouseArea, so the field keeps activeFocus regardless and
  // that handler never fires. Selection changing (a row was clicked) or
  // the path changing (navigated away) are the two concrete signals that
  // "something else" actually happened, keyboard focus notwithstanding.
  Connections {
    target: SelectionState
    function onSelectedIndexChanged() {
      if (sb._selfSelect) return
      if (NavState.searching && NavState.searchQuery.length === 0) sb.collapse()
    }
  }
  Connections {
    target: NavState
    function onCurrentPathChanged() {
      if (NavState.searching && NavState.searchQuery.length === 0) sb.collapse()
    }
  }

  // Field background -- only visible when expanded (at rest: only the magnifier).
  // Same radius as the rest of the app's controls (TextField/Button use
  // Style.cornerRadius = Hyprland's decoration:rounding), not a round
  // pill: so it follows the theme's original corners.
  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: NavState.searching ? Commons.Color.menu.selectedBackground : "transparent"
    border.width: NavState.searching ? Style.spacing.hairline : 0
    border.color: Commons.Color.menu.border
    // Same as the width animation: during a tab switch the background must NOT
    // fade (otherwise the collapsed magnifier of the tab you arrive at
    // flickers "selected" as the selectedBackground fades out). Snap.
    Behavior on color { enabled: !NavState.suppressSearchAnim; ColorAnimation { duration: 200 } }
  }

  TextField {
    id: field
    // Magnifier on the LEFT (josema's mockup): the field goes to its right,
    // up to the edge. At rest (width = collapsedW) the field is ~0 wide
    // and invisible, and only the magnifier stuck to the right edge of navRow is shown.
    anchors.left: iconSlot.right
    anchors.leftMargin: Style.spacing.xs
    anchors.right: parent.right
    anchors.rightMargin: Style.spacing.sm
    anchors.verticalCenter: parent.verticalCenter
    verticalPadding: 2
    visible: NavState.searching
    opacity: NavState.searching ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 150 } }
    placeholderText: "Search files…"
    Accessible.role: Accessible.EditableText
    Accessible.name: "Search files"
    text: NavState.searchQuery
    onTextChanged: {
      if (text !== NavState.searchQuery) NavState.searchQuery = text
      debounce.restart()
    }
    onVisibleChanged: if (visible) forceActiveFocus(); else if (sb.list) sb.list.forceActiveFocus()
    // Click outside with the field empty -> collapse (if there is text, it stays
    // open showing the results even if focus goes to a row).
    onActiveFocusChanged: {
      // The ListView reclaims active focus every time its model resets
      // (the live filter changes with each letter), which used to let you type only
      // one letter. While the magnifier is open with text, the keyboard belongs to the
      // field (SearchBar handles Up/Down/Enter/Escape), so we
      // give it back on the next cycle (callLater avoids fighting in the same one).
      if (!activeFocus && NavState.searching && NavState.searchQuery.length > 0) Qt.callLater(forceActiveFocus)
      else if (!activeFocus && NavState.searching && NavState.searchQuery.length === 0) sb.collapse()
    }
    Keys.onPressed: function (event) {
      if (event.key === Qt.Key_Escape) {
        if (NavState.searchQuery.length > 0) { field.text = ""; NavState.searchQuery = ""; sb.searchOps.restoreListing() }
        else sb.collapse()
        event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        if (SelectionState.selectedIndex >= 0)
          sb.navController.enter(NavState.visibleEntries[SelectionState.selectedIndex])
        sb.searchOps.exitSearch()
        event.accepted = true
      } else if (event.key === Qt.Key_Down) {
        var d = Math.min(NavState.visibleEntries.length - 1, SelectionState.selectedIndex + 1)
        if (d >= 0) {
          sb._selfSelect = true
          sb.SelectionState.selectOnly(d)
          sb._selfSelect = false
          if (sb.list) sb.list.positionViewAtIndex(d, ListView.Contain)
        }
        event.accepted = true
      } else if (event.key === Qt.Key_Up) {
        var u = Math.max(0, SelectionState.selectedIndex - 1)
        if (NavState.visibleEntries.length > 0) {
          sb._selfSelect = true
          sb.SelectionState.selectOnly(u)
          sb._selfSelect = false
          if (sb.list) sb.list.positionViewAtIndex(u, ListView.Contain)
        }
        event.accepted = true
      }
    }
  }

  Item {
    id: iconSlot
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: Style.spacing.controlHeight
    height: Style.spacing.controlHeight

    OpticalGlyph {
      anchors.centerIn: parent
      visible: !NavState.searchBusy
      text: "\u{F0349}" // nf-md-magnify
      fontFamily: Style.font.family
      fontSize: Style.font.icon
      color: NavState.searching ? Commons.Color.menu.selectedText : Commons.Color.menu.text
      opacity: NavState.searching ? 1 : Style.emphasis.strong
    }

    // Minimal spinner: a dot in orbit (without depending on a glyph or
    // conical gradients). Only while a search is in flight.
    Item {
      id: spinner
      anchors.centerIn: parent
      width: Style.font.icon
      height: Style.font.icon
      visible: NavState.searchBusy
      Rectangle {
        width: 4; height: 4; radius: 2
        color: Commons.Color.accent
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
      }
      RotationAnimator on rotation {
        running: spinner.visible
        loops: Animation.Infinite
        from: 0; to: 360; duration: 800
      }
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: NavState.searching ? sb.collapse() : sb.expand()
    }
  }

  Timer {
    id: debounce
    interval: 150
    onTriggered: {
      // Incremental recursive from 2 characters; with 0-1 the normal
      // listing of the current folder is restored (see SearchOps).
      if (NavState.searchQuery.length >= 2) sb.searchOps.runDeepSearch()
      else sb.searchOps.restoreListing()
    }
  }
}

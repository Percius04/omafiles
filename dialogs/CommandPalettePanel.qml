import QtQuick
import qs.Commons
import qs.Ui
import "../shared"

// Command palette (":" or Ctrl+P). Ninth component extracted from
// core -- the most interactive of all (live text field +
// arrow navigation + mouse selection), so it exposes more
// signals than the previous ones, but the pattern is the same: core
// is still the real owner of paletteQuery/paletteIndex, and
// `commands` already arrives filtered from outside (root.filteredPaletteCommands()
// is still evaluated in the parent, where "root" really is the real root
// -- here only the result is shown).
Item {
  id: root

  property bool open: false
  property string query: ""
  property int index: 0
  property var commands: []

  signal queryEdited(string text)
  signal closeRequested()
  signal indexRequested(int index)
  signal commandActivated(int index)
  signal focusReturnRequested()

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    visible: root.open
    z: 25
    onClicked: root.closeRequested()
  }

  BorderSurface {
    id: palette
    visible: root.open
    width: Math.min(parent.width - 80, 420)
    height: Math.min(parent.height - 2 * Style.spacing.huge, 360)
    anchors.horizontalCenter: parent.horizontalCenter
    y: Style.spacing.huge
    radius: Style.cornerRadius
    color: Color.menu.background
    borderSpec: Border.flat(Color.menu.border, Style.normalBorderWidth)
    // Same popup padding as the context menu (popupPadding, 14): the
    // two menus share the system spacing instead of the tight sm (4).
    padding: Style.spacing.popupPadding
    z: 30

    MouseArea { anchors.fill: parent; onClicked: {} }

    Column {
      id: paletteColumn
      anchors.fill: parent
      anchors.topMargin: palette.contentTopInset
      anchors.rightMargin: palette.contentRightInset
      anchors.bottomMargin: palette.contentBottomInset
      anchors.leftMargin: palette.contentLeftInset
      spacing: Style.spacing.sm

      TextField {
        id: paletteField
        width: parent.width
        Accessible.role: Accessible.EditableText
        Accessible.name: "Command palette"
        placeholderText: "Type a command…"
        text: root.query
        onTextChanged: root.queryEdited(text)
        onVisibleChanged: if (visible) forceActiveFocus(); else root.focusReturnRequested()
        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Escape) {
            root.closeRequested()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.commandActivated(root.index)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            var nextIdx = Math.min(root.commands.length - 1, root.index + 1)
            root.indexRequested(nextIdx)
            paletteList.positionViewAtIndex(nextIdx, ListView.Contain)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            var prevIdx = Math.max(0, root.index - 1)
            root.indexRequested(prevIdx)
            paletteList.positionViewAtIndex(prevIdx, ListView.Contain)
            event.accepted = true
          }
        }
      }

      PanelSeparator { id: paletteSep; foreground: Color.menu.text; strength: 0.15 }

      ListView {
        id: paletteList
        width: parent.width
        height: parent.height - paletteField.height - paletteSep.height - 2 * paletteColumn.spacing
        spacing: Style.spacing.sm
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.commands

        delegate: CursorSurface {
          required property var modelData
          required property int index
          readonly property bool cmdEnabled: modelData.enabled !== false
          width: paletteList.width
          implicitHeight: Style.spacing.controlHeight
          foreground: Color.menu.text
          accent: Color.accent
          hasCursor: index === root.index && cmdEnabled

          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.sm
            text: parent.modelData.label
            font.pixelSize: Style.font.title
            font.family: Style.font.family
            font.weight: Font.Medium
            color: parent.cmdEnabled ? (index === root.index ? Color.menu.selectedText : Color.menu.text) : Qt.darker(Color.menu.text, 1.8)
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            enabled: parent.cmdEnabled
            cursorShape: Qt.PointingHandCursor
            onEntered: root.indexRequested(index)
            onClicked: root.commandActivated(index)
          }
        }
      }
      
    }

    // OUTSIDE the Column on purpose -- same reason as PreviewPanel's
    // "No file selected" state: EmptyState anchors itself (centerIn), and an
    // anchored child inside a positioner makes the Column log "Column will
    // not function" and permanently stop laying out its children. This was
    // the warning printed on every single launch.
    EmptyState {
      visible: root.commands.length === 0
      // paletteColumn, NOT paletteList: anchors.centerIn only accepts a
      // parent or sibling, and the list stayed inside the Column this
      // EmptyState moved out of ("Cannot anchor to an item that isn't a
      // parent or sibling" -- caught in the journal right after the move).
      centerOn: paletteColumn
      message: root.query ? "No results for “" + root.query + "”" : "No commands available"
      subMessage: root.query ? "Try a broader search" : ""
    }
  }
}

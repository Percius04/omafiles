pragma Singleton
import QtQuick

// Visual "dragging over..." feedback during a
// drag&drop -- seventeenth singleton of the state/ layer. dropHoverIndex
// is for rows of the main list (FileListRow.qml, indexed by
// position); dropHoverPath is for bookmarks/drives in the
// sidebar (Sidebar.qml, indexed by path) -- two forms of the same
// concept, with the key that fits each UI.
QtObject {
  property int dropHoverIndex: -1
  property string dropHoverPath: ""
  // True while a file row is pressed or a Drag is live. Hover-to-activate
  // must not switch panels in that window: switchToTab rebuilds the list
  // and destroys the drag source.
  property bool pointerDown: false
  property bool dragActive: false
  readonly property bool blockPanelSwitch: pointerDown || dragActive
}

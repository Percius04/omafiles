pragma Singleton
import QtQuick
import Omafiles.Backend as Backend

// Tabs (each one a visible panel, side by side) + back/forward history
// of the ACTIVE tab -- twenty-first and last
// singleton of the state/ layer. The most central of all: currentPath/
// _goToPath/refresh (which do stay in core, too
// central to move) read/write this constantly. The initial values
// are just a placeholder -- open() always rewrites them
// before the user sees anything (with the real payload, or defaulting
// to a single "$HOME" panel -- no session restore).
QtObject {
  readonly property string _initialHome: Backend.Env.get("HOME")
  property var tabs: [{ path: _initialHome, history: [_initialHome], historyIndex: 0 }]
  property int activeTabIndex: 0
  // Back/forward history of the ACTIVE tab -- each tab keeps
  // its own in its object (the history/historyIndex fields above)
  // and this pair of properties is just the "current view" of that
  // tab, swapped on changing tab (see
  // switchToTab/newTab/etc. in logic/TabOps.qml).
  property var navHistory: [_initialHome]
  property int navHistoryIndex: 0
}

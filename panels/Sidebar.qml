import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "../shared/Utils.js" as Utils

// Sidebar (bookmarks/recents/drives/network).
Item {
  id: root

  property var bookmarks: []
  property var recentFiles: []
  property var mounts: []
  property var networkMounts: []
  property string currentPath: ""
  property string dropHoverPath: ""
  // Device path whose ejection is in progress -> eject button spinner
  property string ejectingDevice: ""

  property Item positionRelativeTo: null

  property var iconForBookmark: null
  property var iconForMount: null
  property var iconForNetworkMount: null
  property var openContextMenu: null
  property var bookmarkActionsFor: null
  property var mountActionsFor: null
  property var networkMountActionsFor: null

  signal bookmarkOpened(var bookmark)
  signal recentOpened(var item)
  signal recentLaunched(var item)
  signal recentRemoveRequested(string path)
  signal recentClearRequested()
  signal mountActivated(var mount)
  signal mountEjectRequested(var mount)
  signal networkMountOpened(var mount)
  signal connectRequested()
  signal filesDropped(var drop, string destPath)
  signal dropHoverChanged(string path)

  Flickable {
    id: sidebarFlickable
    anchors.fill: parent
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    contentHeight: sidebarColumn.implicitHeight
    interactive: sidebarColumn.implicitHeight > height

    ScrollBar.vertical: ScrollBar {
      policy: sidebarColumn.implicitHeight > sidebarFlickable.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
      width: Style.space(8)
      anchors.left: parent.left

      contentItem: Rectangle {
        implicitWidth: parent.width
        implicitHeight: 26
        radius: parent.width / 2
        color: Util.alpha(Color.foreground, 0.28)
      }
    }

    Column {
      id: sidebarColumn
      width: parent.width
      spacing: 0 // Components already manage their own spacing

      SidebarBookmarks {
        bookmarks: root.bookmarks
        currentPath: root.currentPath
        dropHoverPath: root.dropHoverPath
        positionRelativeTo: root.positionRelativeTo
        iconForBookmark: root.iconForBookmark
        openContextMenu: root.openContextMenu
        bookmarkActionsFor: root.bookmarkActionsFor

        onBookmarkOpened: function(b) { root.bookmarkOpened(b) }
        onDropHoverChanged: function(p) { root.dropHoverChanged(p) }
        onFilesDropped: function(d, p) { root.filesDropped(d, p) }
      }

      SidebarRecent {
        recentFiles: root.recentFiles
        positionRelativeTo: root.positionRelativeTo
        openContextMenu: root.openContextMenu

        onRecentOpened: function(i) { root.recentOpened(i) }
        onRecentLaunched: function(i) { root.recentLaunched(i) }
        onRecentRemoveRequested: function(p) { root.recentRemoveRequested(p) }
        onRecentClearRequested: function() { root.recentClearRequested() }
      }

      SidebarMounts {
        mounts: root.mounts
        currentPath: root.currentPath
        dropHoverPath: root.dropHoverPath
        ejectingDevice: root.ejectingDevice
        positionRelativeTo: root.positionRelativeTo
        iconForMount: root.iconForMount
        openContextMenu: root.openContextMenu
        mountActionsFor: root.mountActionsFor

        onMountActivated: function(m) { root.mountActivated(m) }
        onMountEjectRequested: function(m) { root.mountEjectRequested(m) }
        onDropHoverChanged: function(p) { root.dropHoverChanged(p) }
        onFilesDropped: function(d, p) { root.filesDropped(d, p) }
      }

      SidebarNetwork {
        networkMounts: root.networkMounts
        currentPath: root.currentPath
        positionRelativeTo: root.positionRelativeTo
        iconForNetworkMount: root.iconForNetworkMount
        openContextMenu: root.openContextMenu
        networkMountActionsFor: root.networkMountActionsFor

        onNetworkMountOpened: function(m) { root.networkMountOpened(m) }
        onConnectRequested: function() { root.connectRequested() }
      }
    }
  }
}

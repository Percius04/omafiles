import QtQuick
import Omafiles.Backend as Backend

// AppBindings -- lifecycle and timer wiring of Omafiles (Phase
// 11.C, josema: complete the frontend decoupling). It gathers the
// reactions/timers that are neither UI (MainLayout/DialogLayer) nor
// operational facade (CommandFacade): disk/network updates and the debounce of the `g` key
// (gg -> go to top). It receives only what it uses: `root` (pluginDir/opened/
// gPending) and `mountOps`. It exposes `gTimer` as an alias because KeyboardShortcuts
// (via ActiveFileList) restarts it.
Item {
  id: appBindings

  property Item root
  property var mountOps

  property alias gTimer: gTimer

  // Block devices (USB/ISO/disks): reactive via UDisks2.
  // The native watcher (backend/UDisksWatcher, D-Bus subscription) emits
  // devicesChanged() coalesced on any connection/ejection/mount/
  // label change, and here it responds by listing again -- no polling. The
  // initial load is done by OmafilesContent.open(); `enabled: root.opened` avoids
  // re-listing with the window closed (on reopening, open() catches up).
  //
  // NETWORK mounts (GVfs) are NOT covered by UDisks2: they are refreshed only by
  // internal events (connect/disconnect server in Omafiles, navigate to network) and on
  // opening the window -- without periodic polling. KNOWN LIMITATION: a network
  // mount created from ANOTHER app (nautilus...) does not appear until the next
  // internal event or reopening. Future improvement: a GVfs-specific watcher
  // (D-Bus signals of org.gtk.vfs), never polling.
  Connections {
    target: Backend.UDisksWatcher
    enabled: root.opened
    function onDevicesChanged() { mountOps.refreshMounts() }
  }

  Connections {
    target: Backend.TerminalResolver
    function onError(message) {
      Backend.Notifier.notify(message)
    }
  }

  // Debounce of the `g` key (pressing `g` twice in a row = go to the very
  // top, vim style). onTriggered clears the state if the second didn't arrive.
  Timer {
    id: gTimer
    interval: 600
    onTriggered: root.gPending = false
  }
}

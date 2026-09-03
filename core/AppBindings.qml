import "../state"
import QtQuick
import Omafiles.Backend as Backend

// AppBindings -- lifecycle and timer wiring of Omafiles (Phase
// 11.C, josema: complete the frontend decoupling). It gathers the
// reactions/timers that are neither UI (MainLayout/DialogLayer) nor
// operational facade (CommandFacade): the self-registration as file manager
// on load, the periodic polling of disks/network and the debounce of the `g` key
// (gg -> go to top). It receives only what it uses: `root` (pluginDir/opened/
// gPending) and `mountOps`. It exposes `gTimer` as an alias because KeyboardShortcuts
// (via ActiveFileList) restarts it.
Item {
  id: appBindings

  property Item root
  property var mountOps

  property alias gTimer: gTimer

  // Self-registration as the system file manager (MimeType inode/
  // directory + org.freedesktop.FileManager1) -- launched once on loading
  // the plugin. The script is idempotent (scripts/install-integrations.sh),
  // so calling it on every shell startup is cheap and safe.
  Component.onCompleted: {
    // Under the validation harness (omafiles --selfcheck, Phase 12) it does NOT
    // self-register as file manager: the selfcheck instantiates the core
    // many times and must not have side effects on the system. On a
    // normal startup OMAFILES_SELFCHECK does not exist and the behavior is the
    // usual one.
    if (Backend.Env.get("OMAFILES_SELFCHECK") === "1") return
    Backend.Detached.run([Paths.resourceDir + "/scripts/install-integrations.sh"])
  }

  // Block devices (USB/ISO/disks): reactive via UDisks2.
  // The native watcher (backend/UDisksWatcher, D-Bus subscription) emits
  // devicesChanged() coalesced on any connection/ejection/mount/
  // label change, and here it responds by listing again -- no polling. The
  // initial load is done by OmafilesContent.open(); `enabled: root.opened` avoids
  // re-listing with the window closed (on reopening, open() catches up).
  Connections {
    target: Backend.UDisksWatcher
    enabled: root.opened
    function onDevicesChanged() { mountOps.refreshMounts() }
  }

  // NETWORK mounts (GVfs): reactive via the same pattern (V1.1), closing the
  // previously-documented gap here -- a mount created/removed from ANOTHER
  // app (Nautilus, gio mount, a file picker...) used to stay invisible
  // until the next internal event (connect/disconnect server in Omafiles,
  // navigate to network) or reopening the window. backend/GvfsWatcher
  // subscribes to org.gtk.vfs.MountTracker's Mounted/Unmounted on the
  // session bus (verified present, 2026-08-18) and emits mountsChanged(),
  // coalesced the same way. No polling here either.
  Connections {
    target: Backend.GvfsWatcher
    enabled: root.opened
    function onMountsChanged() { mountOps.refreshNetworkMounts() }
  }

  // Auto-mount the most recent network profile on first startup.
  // Triggered once when BookmarksState.networkProfilesLoaded flips true.
  Connections {
    target: BookmarksState
    enabled: root.opened
    property bool _autoConnectDone: false
    function onNetworkProfilesLoadedChanged() {
      if (_autoConnectDone || !BookmarksState.networkProfilesLoaded) return
      _autoConnectDone = true
      var profiles = BookmarksState.networkProfiles
      if (profiles.length === 0) return
      var uri = profiles[0]
      // Check if it's already mounted (GVfs FUSE path exists)
      var mounts = Backend.NetworkMounts.list()
      var already = mounts.some(function (m) { return m.uri === uri })
      if (!already) {
        DialogsState.connectServerUri = uri
        mountOps.commitConnectToServer()
      }
    }
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

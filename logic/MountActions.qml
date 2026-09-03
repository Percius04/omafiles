import QtQuick
import "../state"
import Omafiles.Backend as Backend
import "../shared/Utils.js" as Utils

// Mount/eject drives (udisksctl) + connect/disconnect network drives
// (gio mount) -- twelfth component extracted from core, and the
// first to move Process + the functions that orchestrate them together out
// of the "Active panel" zone (same criterion as ConflictActions:
// related code that lived scattered; here it was already physically
// contiguous in the file except for the functions, which now truly live
// together). All external calls used `root.xxx(...)`, so they were
// updated to `mountActions.xxx(...)` at their call sites -- no loose
Item {
  property Item root: null
  property Item navController: null

  property Item tabOps: null

  function refreshMounts() {
    // NATIVE enumeration of local drives (V1.2 code-quality pass):
    // LocalMounts.list() replaces list-mounts.sh's findmnt+lsblk (3
    // subprocess forks) with UDisks2 D-Bus calls -- same synchronous
    // contract as refreshNetworkMounts() below. See backend/LocalMounts.h
    // for why this doesn't reintroduce the QStorageInfo limitation
    // (unmounted removable devices) the script was originally kept for.
    MountsState.mounts = Backend.LocalMounts.list()
    _ensureCurrentPathMounted()
  }

  function refreshNetworkMounts() {
    // NATIVE enumeration of GVfs mounts: NetworkMounts.list()
    // replaces list-network-mounts.sh. Synchronous (readdir over gvfs).
    MountsState.networkMounts = Backend.NetworkMounts.list()
  }

  function disconnectNetworkMount(mount) {
    // We pass the context info directly to the signal handler via a state object
    // if we needed to, but we can just use the state variable.
    MountsState.ejectingDevice = mount.path // Using ejectingDevice to signify busy state
    _lastNetworkUnmountWasInside = NavState.currentPath === mount.path || NavState.currentPath.indexOf(mount.path + "/") === 0
    _lastNetworkUnmountTabIndex = TabsState.activeTabIndex
    Backend.NetworkResolver.disconnectMount(mount.uri)
  }

  property bool _lastNetworkUnmountWasInside: false
  property int _lastNetworkUnmountTabIndex: -1

  function startConnectToServer() {
    DialogsState.connectServerUri = ""
    DialogsState.connectServerError = ""
    DialogsState.networkAuthRequested = false
    DialogsState.connectServerOpen = true
  }

  function cancelConnectToServer() {
    DialogsState.connectServerOpen = false
    DialogsState.networkAuthRequested = false
    cancelNetworkConnect()
  }

  // Captured here (not re-read from DialogsState in onMountFinished) --
  // same reasoning as mountProc.tabIndex above: the dialog may already be
  // closed/cleared by the time the async mount actually finishes.
  property string _lastConnectUri: ""

  function commitConnectToServer() {
    var uri = DialogsState.connectServerUri.trim()
    if (!uri) return
    DialogsState.connectServerError = ""
    DialogsState.networkConnecting = true
    _lastConnectUri = uri
    Backend.NetworkResolver.mountUrl(uri)
  }

  function cancelNetworkConnect() {
    Backend.NetworkResolver.cancelAuth()
    DialogsState.networkConnecting = false
  }

  function ejectMount(mount) {
    // Without this guard, double-clicking "Eject" would reassign
    // ejectProc.command in the middle of the first call, restarting it --
    // same problem runAction() already avoided for file actions,
    // but this process didn't have it.
    // Explicit notice instead of a mute return -- without this, the second
    // click did nothing visible and it looked like the app had ignored the
    // press, same as used to happen to runAction() (see there).
    if (ejectProc.busy) {
      Backend.Notifier.notify("Still ejecting a drive — try again in a moment")
      return
    }
    var wasInside = NavState.currentPath === mount.path || NavState.currentPath.indexOf(mount.path + "/") === 0
    ejectProc.mountPath = mount.path
    ejectProc.wasInside = wasInside
    ejectProc.tabIndex = TabsState.activeTabIndex
    ejectProc.device = mount.device
    // Eject button spinner: cleared in ejectProc.onFinished.
    MountsState.ejectingDevice = mount.device
    ejectProc.start(["udisksctl", "unmount", "-b", mount.device])
  }

  // udisksctl prints "Mounted /dev/sdX at /run/media/user/Label." -- the
  // path is extracted from there instead of re-running list-mounts.sh and
  // guessing which is the newly mounted drive.
  function mountDevice(mount) {
    if (mountProc.busy) {
      Backend.Notifier.notify("Still mounting a drive — try again in a moment")
      return
    }
    // Captured here (not re-read in onFinished) -- if the mouse moves to
    // another panel while the mount takes a while, the result must navigate
    // the panel that requested it, not whichever happens to be active when it
    // finishes.
    mountProc.tabIndex = TabsState.activeTabIndex
    mountProc.start(["udisksctl", "mount", "-b", mount.device])
  }

  // Unlike isArchive() (enterArchive(), read-only navigation without
  // mounting anything for real), an .iso is mounted as a real loop
  // device -- so whatever is inside (an installer, for example) can be
  // run/copied just like in any normal folder, not just looked at. It
  // appears in the sidebar like any other removable drive as soon as it is
  // mounted (list-mounts.sh already distinguishes the icon by
  // fstype=iso9660) and is ejected the same way.
  function mountIso(entry) {
    if (mountIsoProc.busy) {
      Backend.Notifier.notify("Still mounting an ISO — try again in a moment")
      return
    }
    mountIsoProc.tabIndex = TabsState.activeTabIndex
    mountIsoProc.start(["bash", Paths.resourceDir + "/scripts/runtime/mount-iso.sh", Utils.joinPath(NavState.currentPath, entry.name)])
  }

  // Req 4: if the removable/external drive you were browsing is
  // ejected (physically or from another app), UDisks2 triggers refreshMounts()
  // and here it is detected that currentPath hangs off a mount point that is no
  // longer mounted -> navigate to Home. It only looks at paths under /run/media
  // or /mnt (the ones managed by drives): a normal home path never triggers
  // this. A MANUAL eject already navigated with its own wasInside; this covers
  // the ejection NOT started by the app.
  function _ensureCurrentPathMounted() {
    var p = NavState.currentPath
    if (p.indexOf("/run/media/") !== 0 && p.indexOf("/mnt/") !== 0) return
    var covered = MountsState.mounts.some(function (m) {
      return m.mounted && (p === m.path || p.indexOf(m.path + "/") === 0)
    })
    if (!covered) tabOps.navigateTabTo(TabsState.activeTabIndex, Paths.homeDir)
  }

  Backend.ProcessRunner {
    id: ejectProc
    property string mountPath: ""
    property bool wasInside: false
    property int tabIndex: -1
    property string device: ""
    onFinished: function (result) {
      MountsState.ejectingDevice = ""
      if (result.exitCode === 0) {
        if (ejectProc.wasInside) tabOps.navigateTabTo(ejectProc.tabIndex, Paths.homeDir)
        // An .iso mounted with mountIso() leaves the /dev/loopN associated to
        // the file even after it is unmounted -- without this, the .iso stays
        // "in use" (can't be moved/deleted) and each one would use up a loop
        // device forever until reboot.
        if (ejectProc.device.indexOf("/dev/loop") === 0) {
          Backend.Detached.run(["udisksctl", "loop-delete", "-b", ejectProc.device])
        }
        refreshMounts()
      } else {
        Backend.Notifier.notify(result.stderr || "Couldn't eject drive")
      }
    }
  }

  Backend.ProcessRunner {
    id: mountProc
    property int tabIndex: -1
    onFinished: function (result) {
      refreshMounts()
      if (result.exitCode === 0) {
        var match = result.stdout.match(/ at (\/[^\s.]+)/)
        if (match) tabOps.navigateTabTo(mountProc.tabIndex, match[1])
      } else {
        Backend.Notifier.notify(result.stderr || "Couldn't mount drive")
      }
    }
  }

  Backend.ProcessRunner {
    id: mountIsoProc
    property int tabIndex: -1
    onFinished: function (result) {
      refreshMounts()
      if (result.exitCode === 0) {
        var match = result.stdout.match(/ at (\/[^\s.]+)/)
        if (match) tabOps.navigateTabTo(mountIsoProc.tabIndex, match[1])
      } else {
        Backend.Notifier.notify(result.stderr || "Couldn't mount ISO")
      }
    }
  }

  Connections {
    target: Backend.NetworkResolver
    function onDisconnectFinished(success, errorMessage) {
      MountsState.ejectingDevice = ""
      if (success) {
        if (_lastNetworkUnmountWasInside) tabOps.navigateTabTo(_lastNetworkUnmountTabIndex, Paths.homeDir)
        refreshNetworkMounts()
      } else {
        Backend.Notifier.notify(errorMessage || "Couldn't disconnect")
      }
    }

    function onMountFinished(success, errorMessage, localPath, homePath) {
      DialogsState.networkConnecting = false
      if (success) {
        // Saved connection profiles (V1.1, headline #4): only the URI (no
        // password, see BookmarksState.addNetworkProfile's doc comment),
        // only on a REAL successful connect -- a failed/cancelled attempt
        // never pollutes the saved list.
        BookmarksState.addNetworkProfile(_lastConnectUri)
        DialogsState.connectServerOpen = false
        var before = MountsState.networkMounts.map(function (m) { return m.path })
        var parsed = Backend.NetworkMounts.list()
        MountsState.networkMounts = parsed
        var fresh = parsed.filter(function (m) { return before.indexOf(m.path) < 0 })
        // Nautilus-like: open the mount's default location (remote home dir
        // for sftp) rather than the mount root "/". backend exposes it via
        // NetworkResolver (g_mount_get_default_location).
        var target = homePath
        if (!target && fresh.length > 0) target = fresh[0].path
        if (!target) target = localPath
        if (target) navController.navigateTo(target)
      } else {
        DialogsState.connectServerError = errorMessage || "Connection failed"
      }
    }

    function onAuthRequested(message, defaultUser) {
      // The backend needs credentials. We can use the same dialog but show auth fields.
      // Since DialogsState.connectServerOpen is already true, we can signal the UI to show password fields.
      DialogsState.networkConnecting = false
      DialogsState.networkAuthRequested = true
      DialogsState.networkAuthMessage = message
      if (defaultUser) DialogsState.networkAuthUser = defaultUser
    }
  }
}

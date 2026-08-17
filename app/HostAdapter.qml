import QtQuick
import Omafiles.Backend as Backend
import "../state"


// Omafiles host contract -- the ONLY artifact that
// formalizes what a host frontend must provide to the core. The official
// implementation is app/Main.qml (over ApplicationWindow);
// (core/OmafilesContent.qml) exposes open()/close()/opened + the closeRequested()
// signal and nothing else.

//
// The contract is divided into:
//
//   1. Window/lifecycle  -- host-SPECIFIC, implemented by each
//      host window over its own type (FloatingWindow /
//      ApplicationWindow). Each host MUST expose:
//        · show()               show the window
//        · hide()               hide it (without destroying state)
//        · close()              close it
//        · signal closedExternally()  the window went away by a mechanism that
//                               the host did not initiate (the WM's close button)
//
//   2. Geometry              -- HOST-AGNOSTIC, lives here and is shared by the
//      two hosts. It's limited to SIZE: on Wayland the client doesn't control its
//      position (the compositor fixes it), so "remember position" and
//      "center" are not client capabilities -- center() is a documented
//      no-op and it only persists width/height.
//
// The other capabilities sometimes thought of as "host" ones (theme,
// notifications, open-external, environment, process I/O) do NOT go through here:
// Detached, Env, ProcessRunner...), with the same API in both frontends. See
// ARCHITECTURE.md ("Host contract") and the Phase 18 report.
QtObject {
  id: adapter

  // The host window (FloatingWindow or ApplicationWindow). Both
  // expose width/height; each host applies the restored size to its own
  // Restores window geometry from persistent storage.
  // Qt6) from the sizeRestored handler.
  property var window: null

  // Window state file, shared by the two frontends (the size
  // is an "Omafiles window" preference, not a host one). Same directory
  // ~/.local/state/omafiles/ as the rest of the persistence.
  readonly property string _file: Backend.Env.get("HOME") + "/.local/state/omafiles/window.json"

  // Emitted by restore() when there is a valid saved size -- the host applies it
  // to its concrete size property.
  signal sizeRestored(int w, int h)

  // Reads the saved size (async: arrives via onLoaded). The host calls this
  // in Component.onCompleted.
  function restore() {
    Backend.JsonStore.read(adapter._file)
  }

  // Persists the current size (debounced, so as not to write on every pixel of
  // a resize drag).
  function remember() {
    if (PickerState.sessionActive) return
    _debounce.restart()
  }

  // Documented no-op: on Wayland the compositor places the windows; the
  // client can't center itself. It exists to complete the contract
  // and so that a future X11/other host can give it a body without touching call sites.
  function center() {}

  function _write() {
    // Recheck at delivery time: picker sizing can schedule the debounce before
    // OmafilesContent marks the short-lived picker session active.
    if (PickerState.sessionActive || !adapter.window) return
    Backend.JsonStore.write(adapter._file, {
      width: Math.round(adapter.window.width),
      height: Math.round(adapter.window.height)
    })
  }

  property Timer _debounce: Timer {
    interval: 400
    onTriggered: adapter._write()
  }

  property Connections _js: Connections {
    target: Backend.JsonStore
    function onLoaded(path, data, ok) {
      if (path !== adapter._file) return
      if (ok && data && data.width > 0 && data.height > 0)
        adapter.sizeRestored(data.width, data.height)
    }
  }

  property Connections _win: Connections {
    target: adapter.window
    ignoreUnknownSignals: true
    function onWidthChanged() { adapter.remember() }
    function onHeightChanged() { adapter.remember() }
  }
}

import QtQuick
import QtQuick.Controls
import qs.Commons
import Omafiles.Backend as Backend
import "../../core"
import ".."

// Standalone Qt6 host adapter (Phase 4 → Phase 18, josema). It is the
// single official host frontend for Omafiles: it instantiates
// core/OmafilesContent.qml over an ApplicationWindow.
// It fulfills the host contract (see integrations/HostAdapter.qml):

//   · show()/hide()/close()  -- built-in of Window/ApplicationWindow.
//   · external close          -- onClosing (WM's close button / Alt+F4).
//   · geometry (size)         -- via HostAdapter, same persistence as
//                               Quickshell (~/.local/state/omafiles/window.json).
// The bootstrap (create the engine, load this file) is done by main.cpp; that's
// why, unlike the Quickshell side, here the window IS the root (main.cpp
// expects a QQuickWindow) and there is no intermediate Omafiles.qml nor host
// `shell` object.
ApplicationWindow {
  id: window
  visible: true
  // Default size of the first opening; HostAdapter overrides it if
  // there is a saved window.json (see onSizeRestored).
  width: 1400
  height: 900
  minimumWidth: 560
  minimumHeight: 380
  title: "Omafiles"
  color: Color.menu.background

  HostAdapter {
    id: adapter
    window: window
  }

  Connections {
    target: adapter
    function onSizeRestored(w, h) {
      window.width = w
      window.height = h
    }
  }

  // External close (window manager's close button / Alt+F4) and internal
  // close (Esc / closing the last tab, via onCloseRequested -> window.
  // close()). In a single-window standalone, closing = quitting the app
  // (quitOnLastWindowClosed). content.close() is the one that PERSISTS the session
  // (saveSession, synchronous) besides stopping the watcher and resetting dialogs;
  // calling it here is essential, otherwise the session is never saved in the
  // standalone (Phase 25 regression: before this only set opened=false and
  // skipped the save, so session.json stayed frozen).
  onClosing: {
    content.close()
    Qt.quit()
  }

  OmafilesContent {
    id: content
    anchors.fill: parent
    // Esc / closing the last tab: no `shell` object to notify (there is no
    // host to hide the plugin), so the window is closed directly.
    onCloseRequested: {
      window.close()
      Qt.quit()
    }
  }

  // Single instance (Phase 25): a second invocation `omafiles [path]` doesn't open
  // another window -- main.cpp delivers the payload over the local socket and here it
  // navigates/selects (content.open) and brings the window to the front. Same
  // content.open() that the initial opening uses and that the plugin's summon used.
  Connections {
    target: SingleInstance
    function onReceived(payload) {
      content.open(payload)
      window.show()
      window.raise()
      window.requestActivate()
    }
  }

  Component.onCompleted: {
    var isPicker = typeof omafilesInitialPayload !== "undefined" && omafilesInitialPayload.indexOf("picker:") >= 0
    if (!isPicker) {
      adapter.restore()
    } else {
      window.width = 900
      window.height = 600
    }
    // Initial payload from the command line (main.cpp). Empty = restores the
    // previous session (folder/tabs), same as the plugin startup.
    content.open(typeof omafilesInitialPayload !== "undefined" ? omafilesInitialPayload : "")
  }
}

import QtQuick
import QtQuick.Controls
import qs.Commons
import Omafiles.Backend as Backend
import "../core"
import "."

// Standalone Qt6 host adapter (Phase 4 → Phase 18, josema). It is the
// single official host frontend for Omafiles: it instantiates
// core/OmafilesContent.qml over an ApplicationWindow.
// It fulfills the host contract (see integrations/HostAdapter.qml):

//   · show()/hide()/close()  -- built-in of Window/ApplicationWindow.
//   · external close          -- onClosing (WM's close button / Alt+F4).
//   · geometry (size)         -- via HostAdapter, same persistence as
// Window size persistence.
// The bootstrap (create the engine, load this file) is done by main.cpp; that's
// expects a QQuickWindow) and there is no intermediate core nor host
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

  function isValidatedPickerPayload(payload) {
    if (!payload || payload.charAt(0) !== "{") return false
    try {
      var value = JSON.parse(payload)
      var modes = ["open-file", "open-dir", "save-file", "save-files"]
      var schema = ["files", "folder", "kind", "mode", "multiple", "requestId", "suggestedName"]
      if (Object.keys(value).sort().join(",") !== schema.join(",")
          || value.kind !== "picker"
          || typeof value.folder !== "string" || value.folder.charAt(0) !== "/"
          || value.folder.indexOf("\0") >= 0
          || typeof value.requestId !== "string" || value.requestId.length === 0
          || modes.indexOf(value.mode) < 0 || typeof value.multiple !== "boolean"
          || typeof value.suggestedName !== "string" || !Array.isArray(value.files)) return false
      if (value.mode === "save-files" && value.files.length === 0) return false
      for (var i = 0; i < value.files.length; i++) {
        var name = value.files[i]
        if (typeof name !== "string" || !name || name === "." || name === ".."
            || name.indexOf("/") >= 0 || name.indexOf("\0") >= 0) return false
      }
      return true
    } catch (e) {
      return false
    }
  }

  readonly property bool initialPicker: typeof omafilesInitialIsPicker !== "undefined"
    && omafilesInitialIsPicker === true
    && isValidatedPickerPayload(typeof omafilesInitialPayload !== "undefined" ? omafilesInitialPayload : "")

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
  onClosing: function(closeEvent) {
    if (!content.close()) {
      closeEvent.accepted = false
      return
    }
    Qt.quit()
  }

  OmafilesContent {
    id: content
    anchors.fill: parent
    // Esc / closing the last tab: no `shell` object to notify (there is no
    // Closes the application window.
    onCloseRequested: window.close()
  }

  // Single instance: a second invocation `omafiles [path]` doesn't open
  // another window -- main.cpp delivers the payload over the local socket and here it
  // navigates/selects (content.open) and brings the window to the front. Same
  // Opens the specified path or previous session.
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
    if (!window.initialPicker) {
      adapter.restore()
    } else {
      window.width = 900
      window.height = 600
    }
    // Initial payload from the command line (main.cpp). Empty = restores the
    // Restores previous session tabs.
    content.open(typeof omafilesInitialPayload !== "undefined" ? omafilesInitialPayload : "")
  }
}

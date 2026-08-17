import QtQuick

// Central registry — preserves exact registration order of the monolithic _register().
QtObject {
  id: registryRoot

  readonly property var _moduleUrls: [
    "checks/CheckInfrastructure.qml",
    "checks/CheckPersistence.qml",
    "checks/CheckFilesystemListing.qml",
    "checks/CheckPreview.qml",
    "checks/CheckFilesystemOps.qml",
    "checks/CheckFilesystemTrash.qml",
    "checks/CheckPerformance.qml",
    "checks/CheckActions.qml",
    "checks/CheckPanels.qml",
    "checks/CheckSearch.qml",
    "checks/CheckDevices.qml",
    "checks/CheckIntegration.qml"
  ]

  function registerAll(sc) {
    var base = Qt.resolvedUrl(".")
    for (var i = 0; i < _moduleUrls.length; i++) {
      var url = base + _moduleUrls[i]
      var comp = Qt.createComponent(url)
      if (comp.status !== Component.Ready) {
        SelfCheckOut.line("[FAIL] SelfCheckRegistry: could not load " + _moduleUrls[i]
          + " — " + comp.errorString())
        Qt.exit(2)
        return
      }
      var mod = comp.createObject(registryRoot)
      mod.register(sc)
    }
  }
}

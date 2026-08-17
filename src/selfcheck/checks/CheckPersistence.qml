import QtQuick
import Omafiles.Backend as Backend
import "../../../state"
import "../../../shared/Utils.js" as Utils

// Domain checks extracted from app/SelfCheck.qml (_register).
// Structural refactor only — behavior unchanged.
QtObject {
  function register(sc) {
        sc.add("Backend.JsonStore write/read round-trip", function (done) {
          var payload = { a: 1, b: "x", nested: { k: [1, 2, 3] } }
          function onSaved(path, ok) {
            Backend.JsonStore.saved.disconnect(onSaved)
            if (!ok) { done(false, "write failed"); return }
            function onLoaded(p, data, lok) {
              Backend.JsonStore.loaded.disconnect(onLoaded)
              if (!lok) { done(false, "read failed"); return }
              var good = data && data.a === 1 && data.b === "x"
                && data.nested && data.nested.k.length === 3
              done(good, good ? "" : "data doesn't match: " + JSON.stringify(data))
            }
            Backend.JsonStore.loaded.connect(onLoaded)
            Backend.JsonStore.read(sc.jsonFile)
          }
          Backend.JsonStore.saved.connect(onSaved)
          Backend.JsonStore.write(sc.jsonFile, payload)
        })
  }
}

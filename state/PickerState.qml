pragma Singleton
import QtQuick

// Holds the state of the active file chooser portal request
QtObject {
  property bool active: false
  property string requestId: ""
  property string mode: "open-file" // "open-file" | "open-dir" | "save-file"
  property bool multiple: false
  property string suggestedName: ""
}

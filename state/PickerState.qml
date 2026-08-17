pragma Singleton
import QtQuick

// Holds the state of the active file chooser portal request
QtObject {
  property bool active: false
  // Remains true after a successful response clears the visible picker. It
  // prevents this short-lived process from writing normal session state.
  property bool sessionActive: false
  property string mode: "open-file" // "open-file" | "open-dir" | "save-file" | "save-files"
  property bool multiple: false
  property string suggestedName: ""
  property var saveFiles: []
}

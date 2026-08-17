pragma Singleton
import QtQuick

// State of the permissions (chmod) dialog -- eighth singleton of the
// state/ layer. dialogs/ChmodPanel.qml is purely presentational (its own
// local `id: root`, fed by binding from core), so it
// does not need to import this directly.
QtObject {
  property bool chmodOpen: false
  // A list of names instead of a single string -- chmod supports applying
  // the same mode to the whole selection, not just one file.
  property var chmodNames: []
  // Immutable snapshots captured when the dialog opens.
  // Each record is { name, path, originalMode }.
  property var chmodRecords: []
  // true if on opening the dialog the selected items did NOT all have
  // the same octal mode -- chmodMode is left blank in that case (it does not
  // make sense to preload the mode of "any one" of them) and the UI
  // warns that it is a mixed selection.
  property bool chmodMixed: false
  property string chmodMode: ""
  // true if at least one of the selected is a folder -- controls
  // whether the "Apply to subfolders" toggle is shown (chmod -R has
  // nothing to offer over a files-only selection).
  property bool chmodHasDir: false
  property bool chmodRecursive: false
  // Undo restores each selected item's own mode. Recursive descendant modes are
  // not captured because walking and storing the full tree would be unbounded.
}

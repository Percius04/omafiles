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
  // Legacy name-keyed view retained for dialog compatibility. Execution and
  // history use chmodRecords, whose absolute paths cannot drift after navigation.
  // { "<name>": "<previous octal mode>" }, captured by PropertiesLoader
  // on opening the dialog -- so it can be undone. It restores only the mode of
  // the selected item itself, NOT that of its content if applied with -R --
  // capturing the whole tree before changing anything would be much more expensive
  // (recursive find+stat) for what the real gap asked (chmod was,
  // together with bulk rename, the only risky action without any undo).
  property var chmodOriginalModes: ({})
}

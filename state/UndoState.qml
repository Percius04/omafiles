pragma Singleton
import QtQuick

// Undo/redo stacks (Ctrl+Z / Ctrl+Shift+Z) -- third singleton
// of the state/ layer, same pattern validated with SelectionState/
// ClipboardState. Reversible actions: rename, new folder/file,
// delete (to trash), no-overwrite move (cut+paste/drag), bulk
// rename, chmod and link. Copy/compress/overwrite moves are left out --
// undoing them is more ambiguous (delete the copy? what if it was already
// moved/edited?) than losing by mistake something renamed/moved/deleted/with
// changed permissions. The logic that manipulates them stays in logic/ActionEngine.qml.
QtObject {
  property var undoStack: []
  // redoFn is optional -- only the entries that carry it appear in
  // Ctrl+Shift+Z. Any NEW action (a real pushUndo, not a
  // redo/undo of an existing one) invalidates the pending redo, same
  // behaviour as any text editor.
  property var redoStack: []
}

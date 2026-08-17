pragma Singleton
import QtQuick

// State of the six conflict dialogs (rename/paste/extract/
// compress/bulk-rename/drop) -- fourth singleton of the
// state/ layer, same pattern validated with Selection/Clipboard/Undo. The logic
// that decides when to open them and what to do on confirm stays in
// logic/ConflictActions.qml (and in RenameOps/ClipboardOps/ArchiveActions/
// FileOps/DragDropOps for the conflict-free case).
QtObject {
  property var pendingRename: null // { oldPath, newPath, newName }

  property var pendingNewFile: null // { path, name }
  property bool newFileConflictOpen: false

  property var pendingNewFolder: null // { path, name }
  property bool newFolderConflictOpen: false

  property var pasteConflictNames: []
  property bool pasteConflictOpen: false

  property var pendingExtract: null // { entry, cmd }
  property var extractConflictNames: []
  property bool extractConflictOpen: false

  property var pendingCompress: null // { archiveName, finalPath, stagePath, cmd }
  property bool compressConflictOpen: false

  property var pendingBulkRename: null // [{ oldName, newName, oldPath, newPath }]
  property int bulkRenameInternalDupes: 0
  property int bulkRenameConflictCount: 0
  property bool bulkRenameConflictOpen: false

  // ---------- Drag and drop ----------
  // Deliberately separate from the Ctrl+C/X/V clipboard (see
  // state/ClipboardState.qml) -- a drag must not clobber what the user
  // has copied by hand. Internal (same app) = move; from outside (another
  // app) = copy, decided by DragEvent.source (null if the drag comes
  // from outside).
  property var dropPendingSources: []
  property string dropTargetDir: ""
  property bool dropIsMove: false
  property var dropConflictNames: []
  property bool dropConflictOpen: false
}

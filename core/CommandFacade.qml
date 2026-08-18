import "../shared/Utils.js" as Utils
import QtQuick
import "../state"
import Omafiles.Backend as Backend

// CommandFacade -- operational facade (menus, command palette, breadcrumbs).
Item {
  id: commandFacade

  property Item root
  property var mountOps
  property var propertiesLoader
  property var searchOps
  property var tabOps
  property var customActions
  property var navController
  property var actionEngine
  property var openProc

  function paletteCommands() {
    var hasSelection = SelectionState.selectedIndices.length > 0
    var entry = SelectionState.selectedIndices.length === 1 ? NavState.visibleEntries[SelectionState.selectedIndex] : null
    var cmds = [
      { label: "New folder", run: function () { actionEngine.startNewFolder() } },
      { label: "New file", run: function () { actionEngine.startNewFile() } },
      { label: "Rename", enabled: SelectionState.selectedIndices.length === 1, run: function () { actionEngine.startRename(SelectionState.selectedIndex) } },
      { label: "Copy", enabled: hasSelection, run: function () { actionEngine.copySelected() } },
      { label: "Cut", enabled: hasSelection, run: function () { actionEngine.cutSelected() } },
      { label: "Copy path", enabled: hasSelection, run: function () { actionEngine.copyPathAbsoluteFor(SelectionState.selectedEntries()) } },
      { label: "Paste", enabled: ClipboardState.clipboardPaths.length > 0, run: function () { actionEngine.paste() } },
      { label: "Delete", enabled: hasSelection, run: function () { actionEngine.requestDelete() } },
      { label: "Select all", run: function () { SelectionState.selectedIndices = Array.from({ length: NavState.visibleEntries.length }, function (_, i) { return i }) } },
      { label: "Select none", enabled: hasSelection, run: function () { SelectionState.selectNone() } },
      { label: "Invert selection", run: function () { SelectionState.invertSelection() } },
      { label: NavState.showHidden ? "Hide dotfiles" : "Show dotfiles", run: function () { searchOps.toggleHidden() } },
      { label: "Refresh", run: function () { if (navController) navController.refresh(); mountOps.refreshMounts(); mountOps.refreshNetworkMounts() } },
      { label: "Sort by name", run: function () { SortState.setSort("name") } },
      { label: "Sort by size", run: function () { SortState.setSort("size") } },
      { label: "Sort by date", run: function () { SortState.setSort("mtime") } },
      { label: "Sort by type", run: function () { SortState.setSort("type") } },
      { label: "Reverse order", run: function () { SortState.reverseSort() } },
      { label: "List view", run: function () { ViewState.setView("list") } },
      { label: "Table view", run: function () { ViewState.setView("table") } },
      { label: "Icons view", run: function () { ViewState.setView("grid") } },
      { label: UndoState.undoStack.length > 0 ? "Undo: " + UndoState.undoStack[UndoState.undoStack.length - 1].label : "Undo",
        enabled: UndoState.undoStack.length > 0, run: function () { if (actionEngine) actionEngine.undoLast() } },
      { label: UndoState.redoStack.length > 0 ? "Redo: " + UndoState.redoStack[UndoState.redoStack.length - 1].label : "Redo",
        enabled: UndoState.redoStack.length > 0, run: function () { if (actionEngine) actionEngine.redoLast() } },
      { label: "Terminal here", run: function () { Backend.TerminalResolver.launchTerminal(NavState.currentPath) } },
      { label: "Go to Home", run: function () { if (navController) navController.navigateTo(Paths.homeDir) } },
      { label: "Connect to server...", run: function () { mountOps.startConnectToServer() } },
      { label: "New panel", run: function () { tabOps.newTab() } },
      { label: "Close this panel", enabled: TabsState.tabs.length > 1, run: function () { tabOps.closeTab() } },
      { label: "Back", enabled: TabsState.navHistoryIndex > 0, run: function () { if (navController) navController.navBack() } },
      { label: "Forward", enabled: TabsState.navHistoryIndex < TabsState.navHistory.length - 1, run: function () { if (navController) navController.navForward() } },
      { label: "Edit path", run: function () { searchOps.startEditPath() } },
      { label: "Search", run: function () { searchOps.startSearch() } },
      { label: "Compress to .zip", enabled: hasSelection, run: function () { actionEngine.compressSelected() } },
      { label: "Bulk rename...", enabled: SelectionState.selectedIndices.length > 1, run: function () { actionEngine.startBulkRename() } },
      { label: "Permissions...", enabled: hasSelection, run: function () { propertiesLoader.startChmod(SelectionState.selectedEntries()) } },
      { label: "Make link", enabled: !!entry, run: function () { if (entry) actionEngine.makeLinkFor(entry) } },
      { label: "Properties", enabled: hasSelection, run: function () { propertiesLoader.showPropertiesForSelection() } },
      { label: "Keyboard shortcuts", run: function () { DialogsState.shortcutsHelpOpen = true } }
    ]
    if (NavState.currentPath === Paths.trashDir) {
      cmds.push({ label: "Empty trash", run: function () { if (actionEngine) actionEngine.emptyTrash() } })
      cmds.push({ label: "Restore", enabled: hasSelection, run: function () { actionEngine.restoreFromTrash() } })
    }
    if (entry && entry.type !== "dir" && actionEngine.isArchive(entry)) {
      cmds.push({ label: "Extract here", run: function () { actionEngine.extractHere(entry) } })
    }
    if (entry && actionEngine.isIso(entry)) {
      cmds.push({ label: "Mount ISO", run: function () { mountOps.mountIso(entry) } })
    }
    if (entry) {
      var fullPath = Utils.joinPath(NavState.currentPath, entry.name)
      if (!BookmarksState.isBookmarked(fullPath)) {
        cmds.push({ label: "Add to bookmarks", run: function () { BookmarksState.addBookmark(fullPath, entry.name, entry.type) } })
      }
      if (entry.type === "dir") {
        cmds.push({ label: "Open in new tab", run: function () { tabOps.openInNewTab(fullPath) } })
      }
    }
    if (ArchiveState.inArchive) {
      var archiveBlocked = ["New folder", "New file", "Rename", "Copy", "Cut", "Copy path", "Paste", "Delete",
        "Compress to .zip", "Bulk rename...", "Permissions...", "Make link", "Properties",
        "Search", "Add to bookmarks", "Open in new tab", "Extract here", "Mount ISO", "Empty trash", "Restore"]
      cmds = cmds.filter(function (c) { return archiveBlocked.indexOf(c.label) < 0 })
    }
    if (!ArchiveState.inArchive && customActions) {
      cmds = cmds.concat(customActions.paletteEntries(SelectionState.selectedEntries()))
    }
    return cmds
  }

  function filteredPaletteCommands() {
    var all = paletteCommands()
    if (!PaletteState.paletteQuery) return all
    var q = PaletteState.paletteQuery.toLowerCase()
    return all.filter(function (c) { return c.label.toLowerCase().indexOf(q) >= 0 })
  }

  function openPalette() {
    if (customActions) customActions.reload()
    PaletteState.paletteQuery = ""
    PaletteState.paletteIndex = 0
    PaletteState.paletteOpen = true
  }

  function closePalette() {
    PaletteState.paletteOpen = false
  }

  function runPaletteCommand(index) {
    var cmds = filteredPaletteCommands()
    if (index < 0 || index >= cmds.length) return
    var cmd = cmds[index]
    if (cmd.enabled === false) return
    closePalette()
    cmd.run()
  }

  function openContextMenu(x, y, actions) {
    ContextMenuState.contextMenuActions = actions
    ContextMenuState.contextMenuX = Math.min(x, 680)
    ContextMenuState.contextMenuY = y
    ContextMenuState.contextMenuOpen = true
  }

  function itemActions() {
    if (customActions) customActions.reload()
    var entries = SelectionState.selectedEntries()
    if (entries.length === 0) return []
    if (ArchiveState.inArchive) {
      if (entries.length !== 1) return []
      return [{ label: entries[0].type === "dir" ? "Open" : "Open (extracts a temp copy)", action: function () { if (navController) navController.enter(entries[0]) } }]
    }
    var multi = entries.length > 1
    var suffix = multi ? " (" + entries.length + ")" : ""
    var inTrash = NavState.currentPath === Paths.trashDir
    var actions = []

    if (inTrash) {
      actions.push({ label: "Restore" + suffix, action: function () { actionEngine.restoreFromTrash() } })
      actions.push({ label: "Delete permanently" + suffix, destructive: true, action: function () { actionEngine.requestDelete() } })
      return actions
    }

    if (!multi) {
      actions.push({ label: "Open", action: function () { if (navController) navController.enter(entries[0]) } })
      if (entries[0].type === "dir") {
        var dirFullPath = Utils.joinPath(NavState.currentPath, entries[0].name)
        actions.push({ label: "Open in new tab", action: function () {
          tabOps.openInNewTab(dirFullPath)
        } })
      } else {
        actions.push({ label: "Open with...", action: function () { commandFacade.showOpenWith(entries[0]) } })
      }
    }

    actions.push({ label: "Copy" + suffix, action: function () { actionEngine.copySelected() } })
    actions.push({ label: "Cut" + suffix, action: function () { actionEngine.cutSelected() } })
    actions.push({ label: "Copy path" + suffix, action: function () { actionEngine.copyPathAbsoluteFor(entries) } })
    actions.push({ label: "Copy relative path" + suffix, action: function () { actionEngine.copyPathRelativeFor(entries) } })
    actions.push({ label: "Copy URI" + suffix, action: function () { actionEngine.copyPathUriFor(entries) } })
    if (ClipboardState.clipboardPaths.length > 0) actions.push({ label: "Paste here", action: function () { actionEngine.paste() } })

    if (!multi) {
      actions.push({ label: "Rename", action: function () { actionEngine.startRename(SelectionState.selectedIndex) } })
      actions.push({ label: "Make link", action: function () { actionEngine.makeLinkFor(entries[0]) } })
      var fullPath = Utils.joinPath(NavState.currentPath, entries[0].name)
      if (!BookmarksState.isBookmarked(fullPath)) {
        actions.push({ label: "Add to bookmarks", action: function () { BookmarksState.addBookmark(fullPath, entries[0].name, entries[0].type) } })
      }
      actions.push({ label: "Compress to .zip", action: function () { actionEngine.compressSelected() } })
      if (actionEngine.isArchive(entries[0])) {
        actions.push({ label: "Extract here", action: function () { actionEngine.extractHere(entries[0]) } })
      }
      if (actionEngine.isIso(entries[0])) {
        actions.push({ label: "Mount", action: function () { mountOps.mountIso(entries[0]) } })
      }
    } else {
      actions.push({ label: "Bulk rename...", action: function () { actionEngine.startBulkRename() } })
      actions.push({ label: "Compress to .zip", action: function () { actionEngine.compressSelected() } })
    }

    actions.push({ label: "Permissions...", action: function () { propertiesLoader.startChmod(entries) } })
    actions.push({ label: "Delete" + suffix, destructive: true, action: function () { actionEngine.requestDelete() } })
    actions.push({ label: "Properties" + suffix, action: function () { propertiesLoader.showPropertiesForSelection() } })
    actions.push({ label: NavState.showHidden ? "Hide dotfiles" : "Show dotfiles", action: function () { searchOps.toggleHidden() } })
    if (customActions) {
      actions = actions.concat(customActions.menuActions(entries))
    }
    return actions
  }

  function emptyAreaActions() {
    var actions = []
    if (NavState.currentPath === Paths.trashDir) {
      actions.push({ label: "Empty trash", destructive: true, action: function () { if (actionEngine) actionEngine.emptyTrash() } })
    } else if (!ArchiveState.inArchive) {
      actions.push({ label: "New folder", action: function () { actionEngine.startNewFolder() } })
      actions.push({ label: "New file", action: function () { actionEngine.startNewFile() } })
      actions.push({ label: "Paste", enabled: ClipboardState.clipboardPaths.length > 0, action: function () { actionEngine.paste() } })
    }
    actions.push({ label: NavState.showHidden ? "Hide dotfiles" : "Show dotfiles", action: function () { searchOps.toggleHidden() } })
    actions.push({ label: "Refresh", action: function () { if (navController) navController.refresh(); mountOps.refreshMounts(); mountOps.refreshNetworkMounts() } })
    return actions
  }

  function openBookmark(bookmark) {
    if (bookmark.type === "file") {
      var slash = bookmark.path.lastIndexOf("/")
      NavState.pendingSelectNames = [bookmark.path.substring(slash + 1)]
      if (navController) navController.navigateTo(slash > 0 ? bookmark.path.substring(0, slash) : "/")
    } else {
      if (navController) navController.navigateTo(bookmark.path)
    }
  }

  function openRecent(item) {
    var slash = item.path.lastIndexOf("/")
    NavState.pendingSelectNames = [item.name]
    if (navController) navController.navigateTo(slash > 0 ? item.path.substring(0, slash) : "/")
  }

  function launchRecent(item) {
    if (navController) navController.openWithDefault(item.path)
    BookmarksState.addRecent(item.path, item.name)
  }

  function bookmarkActions(bookmark) {
    var actions = [
      { label: "Open", action: function () { openBookmark(bookmark) } }
    ]
    if (bookmark.type !== "file") {
      actions.push({ label: "Open in new tab", action: function () { tabOps.openInNewTab(bookmark.path) } })
    }
    if (bookmark.path === Paths.trashDir) {
      actions.push({ label: "Empty trash", destructive: true, action: function () { if (actionEngine) actionEngine.emptyTrash() } })
    } else {
      actions.push({ label: "Remove bookmark", destructive: true, action: function () { BookmarksState.removeBookmark(bookmark.path) } })
    }
    return actions
  }

  function networkMountActions(mount) {
    return [
      { label: "Open", action: function () { navController.navigateTo(mount.path) } },
      { label: "Open in new tab", action: function () { tabOps.openInNewTab(mount.path) } },
      { label: "Disconnect", destructive: true, action: function () { mountOps.disconnectNetworkMount(mount) } }
    ]
  }

  function showOpenWith(entry) {
    if (!entry || entry.type === "dir") return
    PreviewState.openWithEntry = entry
    var openPath = Utils.entryPath(NavState.currentPath, entry)
    PreviewState.openWithApps = Backend.MimeResolver.getAppsForFile(openPath)
    PreviewState.openWithOpen = true
  }

  function launchWith(desktopId) {
    if (PreviewState.openWithEntry) {
      var openPath = Utils.entryPath(NavState.currentPath, PreviewState.openWithEntry)
      Backend.MimeResolver.launchApp(desktopId, openPath)
      BookmarksState.addRecent(openPath, PreviewState.openWithEntry.name)
    }
    PreviewState.openWithOpen = false
    PreviewState.openWithEntry = null
  }

  function mountActions(mount) {
    if (!mount.mounted) {
      return [{ label: "Mount", action: function () { mountOps.mountDevice(mount) } }]
    }
    var actions = [
      { label: "Open", action: function () { if (navController) navController.navigateTo(mount.path) } },
      { label: "Open in new tab", action: function () { tabOps.openInNewTab(mount.path) } }
    ]
    if (!BookmarksState.isBookmarked(mount.path)) {
      actions.push({ label: "Add to bookmarks", action: function () { BookmarksState.addBookmark(mount.path, mount.label, "dir") } })
    }
    if (mount.removable) {
      actions.push({ label: "Eject", destructive: true, action: function () { mountOps.ejectMount(mount) } })
    }
    return actions
  }

  function pathSegments() {
    if (!ArchiveState.inArchive) return pathSegmentsFor(NavState.currentPath)
    var segs = pathSegmentsFor(NavState.currentPath)
    var archiveName = ArchiveState.archivePath.substring(ArchiveState.archivePath.lastIndexOf("/") + 1)
    var parts = ArchiveState.archiveSubPath ? ArchiveState.archiveSubPath.split("/") : []
    var isLast = parts.length === 0
    segs.push({ label: archiveName, path: isLast ? NavState.currentPath : "" })
    for (var i = 0; i < parts.length; i++) {
      segs.push({ label: parts[i], path: (i === parts.length - 1) ? NavState.currentPath : "" })
    }
    return segs
  }

  function pathSegmentsFor(targetPath) {
    if (targetPath === "/") return [{ label: "/", path: "/" }]
    var parts = targetPath.split("/").filter(function (p) { return p.length > 0 })
    var acc = ""
    var segs = [{ label: "/", path: "/" }]
    for (var i = 0; i < parts.length; i++) {
      acc += "/" + parts[i]
      segs.push({ label: parts[i], path: acc })
    }
    return segs
  }
}

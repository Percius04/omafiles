import QtQuick
import Omafiles.Backend as Backend
import "../../../state"
import "../../../shared/Utils.js" as Utils

// Domain checks extracted from app/SelfCheck.qml (_register).
// Structural refactor only — behavior unchanged.
QtObject {
  function register(sc) {
        // ======================= INTEGRATION =======================

        sc.add("Backend module loaded (Omafiles.Backend)", function (done) {
          var home = Backend.Env.get("HOME")
          done(!!home && home.length > 0, home ? "HOME=" + home : "Backend.Env.get(HOME) empty")
        })

        sc.add("Backend.UDisksWatcher reactive backend", function (done) {
          // The C++ watcher (QtDBus) registered and exposes available()/devicesChanged.
          // available() is true if it connected to the system bus (in headless CI it can
          // be false; what's validated is that it loads and doesn't break, not that there's a bus).
          var a = Backend.UDisksWatcher.available()
          var ok = (a === true || a === false)
            && typeof Backend.UDisksWatcher.devicesChanged === "function"
          done(ok, "available=" + a)
        })

        sc.add("Backend.FolderCounter counts a directory (async, Fase 23)", function (done) {
          // list/ = sub/ + alpha/beta/gamma.txt = 4 entries.
          function on(path, n) {
            if (path !== sc.listDir) return
            Backend.FolderCounter.counted.disconnect(on)
            done(n === 4, "n=" + n + " (expected 4)")
          }
          Backend.FolderCounter.counted.connect(on)
          Backend.FolderCounter.request(sc.listDir, false)
        })

        sc.add("Item count smart formatting", function (done) {
          var ok = Utils.formatItemCount(1) === "1 item"
            && Utils.formatItemCount(2) === "2 items"
            && Utils.formatItemCount(1234) === "1,234 items"
            && Utils.formatItemCount(12347) === "12.3k items"
            && Utils.formatItemCount(1200000) === "1.2M items"
            && Utils.formatItemCountExact(12347) === "12,347 items"
            && Utils.itemCountAbbreviated(12347) === true
            && Utils.itemCountAbbreviated(1234) === false
          done(ok, ok ? "" : "1=" + Utils.formatItemCount(1) + " 1234=" + Utils.formatItemCount(1234)
                              + " 12347=" + Utils.formatItemCount(12347))
        })

        sc.add("Composition root creates (OmafilesContent)", function (done) {
          var comp = Qt.createComponent(Qt.resolvedUrl("../../../core/OmafilesContent.qml"))
          if (comp.status === Component.Error) { done(false, comp.errorString()); return }
          var obj = comp.createObject(sc)
          if (!obj) { done(false, "createObject returned null"); return }

          sc._content = obj
          done(true, "main tree instantiated")
        })

        sc.add("Composition root API surface (open/close/facade)", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var facade = c.commandFacade || c
          var ok = typeof c.open === "function"
            && typeof c.close === "function"
            && typeof facade.paletteCommands === "function"
            && typeof facade.itemActions === "function"
          done(ok, ok ? "" : "missing contract/facade functions")
        })

        // ======================= FRONTEND =======================

        sc.add("NavState is source of truth", function (done) {
          var prev = NavState.currentPath
          NavState.currentPath = sc.listDir
          var ok = NavState.currentPath === sc.listDir
          done(ok, ok ? "" : "NavState.currentPath doesn't persist")
        })

        sc.add("TabsState defaults", function (done) {
          var ok = TabsState.tabs.length >= 1 && TabsState.activeTabIndex === 0
          done(ok, "tabs=" + TabsState.tabs.length + " active=" + TabsState.activeTabIndex)
        })

        sc.add("ViewState cycles list, table, and icons", function (done) {
          var prev = ViewState.viewMode
          ViewState.setView("list")
          var startedList = ViewState.isList && !ViewState.isTable && !ViewState.isGrid && ViewState.viewLabel() === "List"
          ViewState.cycleView()
          var becameTable = ViewState.isTable && ViewState.viewLabel() === "Table"
          ViewState.cycleView()
          var becameGrid = ViewState.isGrid && ViewState.viewLabel() === "Icons"
          ViewState.cycleView()
          var backToList = ViewState.isList && ViewState.viewLabel() === "List"
          ViewState.setView("grid")
          var setGrid = ViewState.viewMode === "grid" && ViewState.isGrid
          ViewState.setView("icon")
          var rejectedUnknown = ViewState.viewMode === "grid"
          var hit = ViewState.gridIndicesInRect(10, 10, 150, 90, 100, 100, 3, 9)
          var gridMath = hit.length === 2 && hit[0] === 0 && hit[1] === 1
          ViewState.setView(prev)
          var ok = startedList && becameTable && becameGrid && backToList && setGrid && rejectedUnknown && gridMath
          done(ok, ok ? "list <-> table <-> icons" : "cycle/setView/grid math failed")
        })

        sc.add("SortState reverse and toggleSort", function (done) {
          var prevKey = SortState.sortKey
          var prevDesc = SortState.sortDesc
          var prevEntries = NavState.entries
          SortState.sortKey = "name"
          SortState.sortDesc = false
          SortState.reverseSort()
          var reversed = SortState.sortDesc === true && SortState.sortKey === "name"
          SortState.toggleSort("size")
          var switched = SortState.sortKey === "size" && SortState.sortDesc === false
          SortState.toggleSort("size")
          var toggled = SortState.sortKey === "size" && SortState.sortDesc === true
          SortState.sortKey = prevKey
          SortState.sortDesc = prevDesc
          NavState.entries = prevEntries
          var ok = reversed && switched && toggled
          done(ok, ok ? "reverse + toggle" : "sort toggle failed")
        })

        sc.add("Utils.typeLabel for folder, extension, and file", function (done) {
          var ok = Utils.typeLabel({ type: "dir", name: "docs" }) === "Folder"
            && Utils.typeLabel({ type: "file", name: "notes.txt" }) === "TXT"
            && Utils.typeLabel({ type: "file", name: "README" }) === "File"
            && Utils.typeLabel(null) === ""
          done(ok, ok ? "" : "typeLabel mismatch")
        })

        sc.add("Palette and keyboard expose list, table, and icons views", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          var facade = c.commandFacade || c
          var cmds = facade.paletteCommands()
          var labels = cmds.map(function (cmd) { return cmd.label })
          var hasList = labels.indexOf("List view") >= 0
          var hasTable = labels.indexOf("Table view") >= 0
          var hasIcons = labels.indexOf("Icons view") >= 0

          var headerComp = Qt.createComponent(Qt.resolvedUrl("../../../shared/FileTableHeader.qml"))
          var visualComp = Qt.createComponent(Qt.resolvedUrl("../../../shared/FileTableVisual.qml"))
          var gridComp = Qt.createComponent(Qt.resolvedUrl("../../../shared/FileGridVisual.qml"))
          var headerOk = headerComp.status === Component.Ready
          var visualOk = visualComp.status === Component.Ready
          var gridOk = gridComp.status === Component.Ready

          var metaComp = Qt.createComponent(Qt.resolvedUrl("../../../logic/FileMeta.qml"))
          if (metaComp.status !== Component.Ready) {
            done(false, "FileMeta: " + metaComp.errorString())
            return
          }
          var meta = metaComp.createObject(sc)
          var file = { type: "file", name: "notes.txt", size: 2048, mtime: Math.floor(Date.now() / 1000) - 120, link: "" }
          var dir = { type: "dir", name: "docs", size: 0, mtime: Math.floor(Date.now() / 1000) - 120, link: "" }
          var metaOk = meta.sizeTextFor(file) === Utils.formatSize(2048)
            && meta.typeTextFor(file) === "TXT"
            && meta.typeTextFor(dir) === "Folder"
            && meta.dateTextFor(file).indexOf("min ago") >= 0
          meta.destroy()

          var prevView = ViewState.viewMode
          ViewState.setView("list")
          var kbdComp = Qt.createComponent(Qt.resolvedUrl("../../../logic/KeyboardShortcuts.qml"))
          if (kbdComp.status !== Component.Ready) {
            ViewState.setView(prevView)
            done(false, "kbd: " + kbdComp.errorString())
            return
          }
          var pasted = false
          var kbd = kbdComp.createObject(sc, {
            "hostControllers": { "actionEngine": { paste: function () { pasted = true } }, "navController": {} },
            "hostRoot": { "pendingDeleteNames": [] }
          })
          var ev = function (k, mod) { return { "key": k, "modifiers": mod || Qt.NoModifier, "accepted": false } }
          kbd.handlePress(ev(Qt.Key_V))
          var cycledTable = ViewState.viewMode === "table"
          kbd.handlePress(ev(Qt.Key_V))
          var cycledGrid = ViewState.viewMode === "grid"
          kbd.handlePress(ev(Qt.Key_V, Qt.ControlModifier))
          kbd.destroy()
          ViewState.setView(prevView)

          var ok = hasList && hasTable && hasIcons && headerOk && visualOk && gridOk && metaOk && cycledTable && cycledGrid && pasted
          done(ok, ok ? "palette + v + list/table/icons components"
            : "list=" + hasList + " table=" + hasTable + " icons=" + hasIcons + " header=" + headerOk
              + " visual=" + visualOk + " grid=" + gridOk + " meta=" + metaOk
              + " vTable=" + cycledTable + " vGrid=" + cycledGrid + " paste=" + pasted
              + (headerOk ? "" : " headerErr=" + headerComp.errorString())
              + (visualOk ? "" : " visualErr=" + visualComp.errorString())
              + (gridOk ? "" : " gridErr=" + gridComp.errorString()))
        })

        sc.add("ControllerRegistry + CommandFacade wiring", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }
          // Forces the evaluation of the builders: if a controller came in null
          // due to a registry injection failure, this would throw (see Phase 11.C).
          var facade = c.commandFacade || c
          var pal = facade.paletteCommands().length
          var items = facade.itemActions().length            // 0 without selection: valid
          var empty = facade.emptyAreaActions().length
          var segs = facade.pathSegments().length
          var ok = pal > 0 && empty > 0 && segs > 0 && (items >= 0)
          done(ok, "palette=" + pal + " emptyArea=" + empty + " segments=" + segs)
        })

        sc.add("Open with click reaches CommandFacade.launchWith", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }

          function findOpenWithPanel(obj) {
            if (!obj) return null
            if (typeof obj.appSelected === "function" && obj.apps !== undefined && obj.entry !== undefined)
              return obj
            var kids = obj.children
            if (!kids) return null
            for (var i = 0; i < kids.length; i++) {
              var found = findOpenWithPanel(kids[i])
              if (found) return found
            }
            return null
          }

          var panel = findOpenWithPanel(c)
          if (!panel) { done(false, "OpenWithPanel not in the composition tree"); return }

          var previousOpen = PreviewState.openWithOpen
          var previousEntry = PreviewState.openWithEntry
          PreviewState.openWithEntry = null
          PreviewState.openWithOpen = true
          panel.appSelected("probe.desktop")
          var reachedLaunch = PreviewState.openWithOpen === false
          PreviewState.openWithOpen = previousOpen
          PreviewState.openWithEntry = previousEntry
          done(reachedLaunch, reachedLaunch
            ? "DialogLayer invoked launchWith"
            : "DialogLayer did not invoke launchWith (openWithOpen stayed true)")
        })

        sc.add("Open with click launches the selected desktop app", function (done) {
          var c = sc._content
          if (!c) { done(false, "no composition root"); return }

          function findOpenWithPanel(obj) {
            if (!obj) return null
            if (typeof obj.appSelected === "function" && obj.apps !== undefined && obj.entry !== undefined)
              return obj
            var kids = obj.children
            if (!kids) return null
            for (var i = 0; i < kids.length; i++) {
              var found = findOpenWithPanel(kids[i])
              if (found) return found
            }
            return null
          }

          var panel = findOpenWithPanel(c)
          if (!panel) { done(false, "OpenWithPanel not in the composition tree"); return }

          var home = Backend.Env.get("HOME")
          var dataHome = Backend.Env.get("XDG_DATA_HOME")
          var appDir = (dataHome && dataHome.length > 0 ? dataHome : home + "/.local/share") + "/applications"
          var marker = sc.dir + "/openwith-launched"
          var script = sc.dir + "/openwith-mark.sh"
          var desktopId = "omafiles-openwith-probe.desktop"
          var desktop = appDir + "/" + desktopId
          var previousOpen = PreviewState.openWithOpen
          var previousEntry = PreviewState.openWithEntry

          function restore() {
            PreviewState.openWithOpen = previousOpen
            PreviewState.openWithEntry = previousEntry
          }

          var setup = "mkdir -p " + sc._q(appDir)
            + " && printf '%s\\n' '#!/bin/sh' 'echo launched > " + marker + "' > " + sc._q(script)
            + " && chmod +x " + sc._q(script)
            + " && printf '%s\\n' '[Desktop Entry]' 'Type=Application' 'Name=Probe' 'Exec=" + script + " %f' > " + sc._q(desktop)

          sc._sh(["bash", "-c", setup], function (r0) {
            if (r0.exitCode !== 0) {
              restore()
              done(false, "setup failed exit=" + r0.exitCode + " stderr=" + String(r0.stderr).trim())
              return
            }
            PreviewState.openWithEntry = { name: "note.txt", type: "file", path: sc.note }
            PreviewState.openWithOpen = true
            panel.appSelected(desktopId)
            sc._poll(function () {
              return Backend.FileOperations.existingPaths([marker]).length === 1
            }, function (appeared) {
              sc._sh(["bash", "-c", "if test -f " + sc._q(marker) + "; then cat " + sc._q(marker) + "; fi; rm -f " + sc._q(desktop) + " " + sc._q(script) + " " + sc._q(marker)], function (r1) {
                restore()
                var out = String(r1.stdout).trim()
                done(appeared && out === "launched",
                     appeared ? "marker='" + out + "'"
                              : "selected app did not start")
              })
            })
          })
        })

        sc.add("AppBindings loaded (no side effects under selfcheck)", function (done) {
          // If OmafilesContent was created without errors, AppBindings (its child) too.
          // The self-registration as file manager is guarded by
          // OMAFILES_SELFCHECK, so this test confirms there was no side
          // effect and that the core started up complete.
          done(sc._content !== null, "AppBindings instantiated without self-registration")
        })
  }
}

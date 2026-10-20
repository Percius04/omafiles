import QtQuick
import QtTest
import Omafiles.Backend as Native
import Omafiles.SearchTests 1.0
import "../logic"
import "../panels"
import "../state"

TestCase {
    id: test
    name: "HybridSearch"
    property string fixture: Native.Env.get("HOME") + "/hybrid-fixture"
    property var searcher
    property var snapshots: []
    Component { id: factory; SearchBackend {} }
    WorkerGate { id: workers }
    property var ops: null
    property var opsBackend: null
    property var opsSnapshots: []
    property var searchBar: null
    Item { id: navStub; function refresh() {} }
    ListView {
        id: resultList
        width: 200; height: 24
        model: NavState.visibleEntries
        delegate: Item { width: 200; height: 24 }
        function setContentY(y) { contentY = y }
        function firstVisibleIndex() { return 0 }
        function firstVisibleOffset() { return 0 }
        function positionAtIndexWithOffset(i, offset) { contentY = i * 24 + offset }
    }
    Item {
        id: rootStub
        property var tabEntriesCache: ({})
        property bool loaded: true
        property bool hasPendingEdit: false
        property bool hasBlockingOverlay: false
        property bool suppressListFade: false
        property real _pendingScrollY: -1
        property int _pendingScrollIndex: -1
        property real _pendingScrollOffset: 0
    }
    NavigationController { id: actualNav; root: rootStub; list: resultList }
    TabOps { id: actualTabs; root: rootStub; list: resultList; navController: actualNav }
    Component { id: opsFactory; SearchOps { list: resultList; navController: navStub } }
    Component { id: barFactory; SearchBar { list: resultList; searchOps: test.ops; navController: actualNav } }
    Connections {
        target: test.opsBackend
        function onResults(entries, truncated, complete) {
            var next = test.opsSnapshots.slice()
            next.push({ entries: entries, complete: complete })
            test.opsSnapshots = next
        }
    }
    function startOps(script, rootPath, query) {
        NavState.currentPath = rootPath || fixture + "/local"
        NavState.searching = true
        NavState.searchQuery = query || "ORBIT"
        NavState.entries = []
        SelectionState.selectOnly(-1)
        ops = opsFactory.createObject(test)
        opsBackend = ops.children.filter(function(c) { return typeof c.search === "function" })[0]
        opsBackend.indexScript = fixture + "/" + script
        ops.runDeepSearch()
    }
    function selectedPaths() {
        return SelectionState.selectedEntries().map(function(e) { return e.path })
    }
    function test_opsBusyUntilBothSourcesComplete_data() {
        return [{tag: "index-first-local-active", indexFirst: true},
                {tag: "local-first-index-active", indexFirst: false}]
    }
    function test_opsBusyUntilBothSourcesComplete(data) {
        if (data.indexFirst) verify(workers.hold())
        startOps(data.indexFirst ? "fast.sh" : "slow.sh")
        tryVerify(function() { return NavState.entries.length === (data.indexFirst ? 1 : 2) }, 2000)
        compare(NavState.searchBusy, true, "first snapshot is not completion of both sources")
        workers.release()
        tryVerify(function() { return NavState.entries.length === 3 }, 2000)
        tryCompare(NavState, "searchBusy", false, 2000)
    }
    function test_opsOriginTransitionCancelsDelayedSources_data() {
        return [{tag: "query", transition: "query"}, {tag: "root-round-trip", transition: "root"},
                {tag: "same-root-query-tabs", transition: "tab"}, {tag: "close-same-index-root-query", transition: "close"}]
    }
    function test_opsOriginTransitionCancelsDelayedSources(data) {
        verify(workers.hold())
        startOps("slow.sh")
        var marker = [{name: "ORBIT-owned-by-destination", path: fixture + "/destination/ORBIT"}]
        TabsState.tabs = [{path: NavState.currentPath}, {path: NavState.currentPath,
            searching: true, searchQuery: "ORBIT", searchEntries: marker}]
        TabsState.activeTabIndex = 0
        if (data.transition === "query") {
            NavState.searchQuery = "different"
            NavState.searchQuery = "ORBIT"
        } else if (data.transition === "root") {
            actualNav._goToPath(fixture + "/outside")
            actualNav._goToPath(fixture + "/local")
        } else if (data.transition === "tab") {
            actualTabs.switchToTab(1)
        } else {
            actualTabs.closeTab()
        }
        NavState.entries = marker
        workers.release()
        wait(650)
        compare(NavState.entries, marker, "origin search must not overwrite destination, even after returning to identical root/query")
        compare(NavState.searchBusy, false)
    }
    function test_opsLateLocalPreservesSelectedPathAndScroll() {
        verify(workers.hold())
        startOps("fast.sh")
        tryVerify(function() { return NavState.entries.length === 1 }, 2000)
        compare(selectedPaths(), [fixture + "/outside/ORBIT"])
        workers.release()
        tryVerify(function() { return NavState.entries.length === 3 }, 2000)
        compare(selectedPaths(), [fixture + "/outside/ORBIT"])
        compare(NavState.visibleEntries[SelectionState.selectedIndex].path, fixture + "/outside/ORBIT")
        // Exercise the real Enter/reveal action, without launching any file.
        actualNav.enter(NavState.visibleEntries[SelectionState.selectedIndex])
        compare(NavState.currentPath, fixture + "/outside")
        compare(NavState.pendingSelectNames, ["ORBIT"])
    }
    function test_opsLateIndexPreservesMultipleSelectionAndScroll() {
        startOps("selection.sh")
        tryVerify(function() { return NavState.entries.length === 2 }, 2000)
        SelectionState.selectOnly(0)
        SelectionState.toggleSelect(1)
        var selected = selectedPaths()
        var primary = NavState.visibleEntries[SelectionState.selectedIndex].path
        resultList.setContentY(12)
        tryVerify(function() { return NavState.entries.length === 4 }, 2000)
        compare(selectedPaths(), selected)
        compare(NavState.visibleEntries[SelectionState.selectedIndex].path, primary)
        compare(resultList.contentY, 12)
    }
    function test_opsEmptyFirstSnapshotSelectsDescendantAndEnterReveals() {
        verify(workers.hold())
        startOps("none.sh", fixture + "/local", "ORBITdeep")
        tryVerify(function() { return opsSnapshots.length > 0 }, 2000)
        compare(opsSnapshots[0].entries.length, 0, "unavailable index publishes an empty snapshot")
        compare(NavState.searchBusy, true)
        compare(SelectionState.selectedIndex, -1)
        workers.release()
        tryCompare(NavState, "searchBusy", false, 2000)
        verify(opsSnapshots.length >= 3)
        compare(opsSnapshots[1].entries.length, 0, "local root publishes before the descendant is found")
        compare(NavState.visibleEntries.length, 1)
        compare(NavState.visibleEntries[0].path, fixture + "/local/sub/ORBITdeep.pdf")
        compare(SelectionState.selectedIndex, 0, "first nonempty snapshot must select the first result")
        compare(selectedPaths(), [fixture + "/local/sub/ORBITdeep.pdf"])
        compare(SelectionState.anchorIndex, 0)
        // Dispatch the real SearchBar key handler to the production reveal action.
        searchBar = barFactory.createObject(test)
        verify(searchBar !== null)
        var field = searchBar.children.filter(function(c) { return c.placeholderText === "Search files…" })[0]
        verify(field !== undefined)
        field.forceActiveFocus()
        tryCompare(field, "activeFocus", true, 1000)
        keyClick(Qt.Key_Return)
        compare(NavState.currentPath, fixture + "/local/sub")
        tryVerify(function() {
            var selected = SelectionState.selectedEntries()
            return selected.length === 1 && selected[0].name === "ORBITdeep.pdf"
        }, 2000, "Enter must reveal and select the descendant in its parent folder")
        compare(NavState.searching, false)
    }
    function test_opsLateSnapshotPreservesDeliberateDeselection() {
        verify(workers.hold())
        startOps("fast.sh")
        tryVerify(function() { return NavState.visibleEntries.length === 1 }, 2000)
        compare(SelectionState.selectedIndex, 0)
        SelectionState.selectNone()
        resultList.setContentY(12)
        workers.release()
        tryCompare(NavState, "searchBusy", false, 2000)
        compare(NavState.visibleEntries.length, 3)
        compare(SelectionState.selectedIndex, -1)
        compare(SelectionState.selectedIndices, [])
        compare(SelectionState.anchorIndex, -1)
        compare(resultList.contentY, 12)
    }
    Connections {
        target: test.searcher
        function onResults(entries, truncated, complete) {
            var next = test.snapshots.slice()
            next.push({ entries: entries, truncated: truncated, complete: complete })
            test.snapshots = next
        }
    }
    function init() {
        TabsState.activeTabIndex = 0
        NavState.showHidden = false
        snapshots = []
        opsSnapshots = []
        searcher = factory.createObject(test)
        searcher.indexScript = fixture + "/fast.sh"
    }
    function cleanup() {
        workers.release()
        if (searchBar) { searchBar.destroy(); searchBar = null }
        if (ops) { ops.cancelSearch(); ops.destroy(); ops = null; opsBackend = null }
        NavState.searching = false
        NavState.searchBusy = false
        searcher.cancel()
        searcher.destroy()
        searcher = null
        wait(20)
    }
    function latest() { return snapshots.length ? snapshots[snapshots.length - 1] : { entries: [] } }
    function paths() { return latest().entries.map(function(e) { return e.path }) }
    function test_freshHomeAndDownloadsSameBasenameAreBothFound() {
        searcher.search("ORBIT", false, fixture + "/home-case")
        tryVerify(function() { return latest().complete === true }, 2000)
        compare(paths(), [fixture + "/home-case/ORBITreview.pdf",
                          fixture + "/home-case/Downloads/ORBITreview.pdf", fixture + "/outside/ORBIT"])
    }
    function test_noIndexStillHasLiveMatches_data() {
        return [ {tag: "unavailable", script: "none.sh"},
                 {tag: "empty", script: "empty.sh"},
                 {tag: "error", script: "error.sh"},
                 {tag: "failed-to-start", script: "missing.sh"} ]
    }
    function test_noIndexStillHasLiveMatches(data) {
        searcher.indexScript = fixture + "/" + data.script
        searcher.search("orbit", false, fixture + "/local/")
        tryVerify(function() { return latest().complete === true }, 2000)
        compare(paths().length, 2)
        compare(paths()[0], fixture + "/local/ORBITreview.pdf")
        verify(paths().every(function(p) { return p.charAt(0) === "/" && p.indexOf("outside-link/") < 0 }))
        compare(latest().truncated, false)
    }
    function test_localArrivesBeforeIndexAndIsRetained() {
        searcher.indexScript = fixture + "/slow.sh"
        searcher.search("ORBIT", false, fixture + "/local")
        tryVerify(function() { return paths().length === 2 }, 2000)
        compare(paths().length, 2)
        verify(paths().indexOf(fixture + "/outside/ORBIT") < 0)
        tryVerify(function() { return latest().complete === true }, 2000)
        compare(paths().length, 3)
        compare(paths()[0], fixture + "/local/ORBITreview.pdf")
        compare(paths()[2], fixture + "/outside/ORBIT")
    }
    function test_indexArrivesBeforeLocalAndIsRetained() {
        verify(workers.hold())
        searcher.search("ORBIT", false, fixture + "/large")
        tryVerify(function() { return snapshots.length >= 1 }, 2000)
        compare(snapshots[0].entries.length, 1)
        compare(snapshots[0].entries[0].path, fixture + "/outside/ORBIT")
        workers.release()
        tryVerify(function() { return latest().complete === true }, 3000)
        compare(paths(), [fixture + "/large/ORBIT-fresh.pdf", fixture + "/outside/ORBIT"])
    }
    function test_exactly200UniquePathsAreNotTruncatedAfterDeduplication() {
        searcher.indexScript = fixture + "/exactly-duplicates.sh"
        searcher.search("ORBIT", false, fixture + "/exactly")
        tryVerify(function() { return latest().complete === true }, 2000)
        compare(paths().length, 200)
        compare(latest().truncated, false)
    }
    function test_unionCapKeepsLocalAheadOfOutside() {
        searcher.indexScript = fixture + "/many.sh"
        searcher.search("ORBIT", false, fixture + "/local")
        tryVerify(function() { return latest().complete === true }, 2000)
        compare(paths().length, 200)
        compare(latest().truncated, true)
        compare(paths()[0], fixture + "/local/ORBITreview.pdf")
        compare(paths()[1], fixture + "/local/sub/ORBITdeep.pdf")
    }
    function test_scopeUsesDirectoryBoundaryNotStringPrefix() {
        searcher.indexScript = fixture + "/scope.sh"
        searcher.search("ORBIT", false, fixture + "/local")
        tryVerify(function() { return latest().complete === true }, 2000)
        compare(paths(), [fixture + "/local/ORBITreview.pdf", fixture + "/local/sub/ORBITdeep.pdf",
                          fixture + "/local-neighbor/ORBIT"])
    }
    function test_cancelSuppressesAllLaterPublications() {
        searcher.indexScript = fixture + "/slow.sh"
        searcher.search("ORBIT", false, fixture + "/large")
        searcher.cancel()
        var count = snapshots.length
        wait(600)
        compare(snapshots.length, count)
    }
    function test_rapidQueriesOnlyPublishLatest() {
        searcher.indexScript = fixture + "/query.sh"
        searcher.search("ORBIT", false, fixture + "/large")
        searcher.search("wrong", true, fixture + "/local")
        searcher.search("content.txt", false, fixture + "/local")
        tryVerify(function() { return latest().complete === true }, 2000)
        wait(300)
        for (var i = 0; i < snapshots.length; ++i)
            verify(snapshots[i].entries.every(function(e) { return e.name === "content.txt" }))
        verify(paths().indexOf(fixture + "/local/content.txt") >= 0)
        verify(paths().indexOf(fixture + "/outside/content.txt") >= 0)
    }
    function test_contentModeDoesNotMergeFilenameIndex() {
        searcher.indexScript = fixture + "/query.sh"
        searcher.search("ORBIT", false, fixture + "/large")
        searcher.search('content:"fixture needle here"', false, fixture + "/local")
        tryVerify(function() { return snapshots.length >= 1 }, 2000)
        wait(300)
        compare(paths(), [fixture + "/local/content.txt"])
        compare(latest().entries[0].line, 2)
        compare(latest().entries[0].snippet, "fixture needle here")
        compare(latest().truncated, false)
        compare(snapshots.length, 1)
    }
    function test_shortContentQueryClearsPreviousWork() {
        searcher.search("ORBIT", false, fixture + "/large")
        searcher.search("content:x", false, fixture + "/local")
        wait(300)
        compare(snapshots.length, 1)
        compare(paths().length, 0)
        compare(latest().truncated, false)
    }
    function test_newLocalQueryDoesNotWaitForOldIndexExit() {
        searcher.indexScript = fixture + "/stubborn.sh"
        searcher.search("ORBIT", false, fixture + "/local")
        tryVerify(function() { return snapshots.length >= 1 }, 2000)
        wait(30) // allow the shell's TERM trap to become active
        snapshots = []
        searcher.search("content.txt", false, fixture + "/local")
        try {
            tryVerify(function() { return paths().indexOf(fixture + "/local/content.txt") >= 0 }, 300,
                      "latest local search must not wait for a cancelled index process")
        } finally {
            wait(2200) // allow both deliberately stubborn fixture processes to finish
        }
    }
    function test_bestLocalMatchBeyondCapIsRankedFirst() {
        searcher.indexScript = fixture + "/empty.sh"
        searcher.search("ORBIT", false, fixture + "/ranked")
        tryVerify(function() { return latest().complete === true }, 2000)
        compare(paths().length, 200)
        compare(latest().truncated, true)
        compare(paths()[0], fixture + "/ranked/ORBIT")
    }
    function test_liveWalkPrunesDependencyAndCacheTrees() {
        searcher.indexScript = fixture + "/none.sh"
        searcher.search("ORBIT", true, fixture + "/local")
        tryVerify(function() { return latest().complete === true }, 2000)
        compare(paths().filter(function(p) { return p.indexOf("ORBITnoise") >= 0 }).length, 0)
        verify(paths().indexOf(fixture + "/local/.ORBIT-secret") >= 0)
        verify(paths().indexOf(fixture + "/local/.hidden/ORBIThidden.pdf") >= 0)
    }
    function test_duplicatePathsAreMergedBeforeCap() {
        searcher.indexScript = fixture + "/duplicates.sh"
        searcher.search("ORBIT", false, fixture + "/local")
        tryVerify(function() { return latest().complete === true }, 2000)
        compare(paths().filter(function(p) { return p === fixture + "/local/ORBITreview.pdf" }).length, 1)
        verify(latest().entries.filter(function(e) {
            return e.path === fixture + "/local/ORBITreview.pdf"
        })[0].size > 0) // retain live metadata rather than indexed placeholder zeros
        compare(latest().truncated, false)
    }
    function test_freshLocalWithNonemptyIndex() {
        searcher.search("ORBIT", false, fixture + "/local")
        tryVerify(function() { return paths().indexOf(fixture + "/local/ORBITreview.pdf") >= 0 }, 2000,
                  "fresh local filename must appear even when global index returns matches")
        tryVerify(function() { return paths().indexOf(fixture + "/outside/ORBIT") >= 0 }, 2000)
        compare(paths()[0], fixture + "/local/ORBITreview.pdf")
        compare(paths()[1], fixture + "/local/sub/ORBITdeep.pdf")
        compare(latest().truncated, false)
    }
}

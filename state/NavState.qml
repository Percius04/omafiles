pragma Singleton
import QtQuick
import Omafiles.Backend as Backend

// Hot navigation state: the current path, its
// listing and the visible search filter. It was the main coupling
// between logic/ and root -- currentPath (59 reads), visibleEntries (24) and
// Central navigation and directory listing state.
// logic layer, always via `property Item root`. Moving them to a singleton
// lets logic/ read/write NavState.* directly and lets root keep
// only thin compatibility bindings for the visual tree (still not
// split). See ARCHITECTURE.md (state/ layer) and the 2026-08-09 audit.
//
// The initial value of currentPath is just a placeholder: open() always
// rewrites it before the user sees anything (real payload or session
// restoration via Persistence), like TabsState.
QtObject {
  property string currentPath: Backend.Env.get("HOME")

  // Listing of the current folder, already sorted (DirectoryModel in C++
  // returns it by naturalCompare; logic/ only re-sorts if the user requested
  // another criterion -- see SortOps.isDefaultOrder). Source of truth; root.
  // entries is a binding to this.
  property var entries: []

  property bool showHidden: false

  // Text of the active panel's quick search (substring filter over
  // the current folder, not a recursive search). Empty = no filter.
  property string searchQuery: ""

  // Visible subset of `entries` after applying the quick filter. Derived
  // (readonly): previously it was computed in root.visibleEntries and read by 24
  // sites of logic/. Same expression, now next to its data source.
  // The NAME search filters the listing by the term (match in the
  // basename). The CONTENT search (`content:`) is NOT filtered: its
  // results are matches inside files and their name does not contain the
  // prefix, so filtering would hide them all.
  readonly property var visibleEntries: (searchQuery && searchQuery.indexOf("content:") !== 0)
    ? entries.filter(function (e) { return e.name.toLowerCase().indexOf(searchQuery.toLowerCase()) >= 0 })
    : entries

  // ---------- Runtime navigation/search state ----------
  // They were mutable properties of OmafilesContent that did not belong to the
  // composition root: they are all hot state of the same domain (nav +
  // search) that this singleton already governs. logic/ and the visual layer
  // read/write them directly via NavState.*, without `property Item root`.

  // Search mode open (Phase 19: the top bar's magnifier is
  // expanded; the search field is visible). Reused as an
  // "expanded" flag to not duplicate state -- there is no separate searchExpanded.
  property bool searching: false
  // A recursive search (SearchWorker) is in flight -- triggers the magnifier's
  // spinner. It is set in runDeepSearch() and cleared in onResults/restore.
  property bool searchBusy: false
  // The recursive search was cut to the first 200 results (a warning to the
  // user that items are missing; see SearchOps/search-recursive.sh).
  property bool searchTruncated: false
  // Suppresses the magnifier's expand/collapse animation during a tab
  // change (TabOps sets it while changing): on moving the cursor to another tab,
  // `searching` changes because it adopts THAT tab's state, not because the user
  // opened/closed the search -- without this, the tab you arrive at replays the
  // minimize/expand animation of the bar, which looks bad (same reason as
  // suppressListFade for the list fade).
  property bool suppressSearchAnim: false
  // Message if the listing of currentPath failed (permissions, folder deleted
  // between navigating and listing...). Empty = no error or listing in progress.
  property string currentPathError: ""
  // Names to highlight as soon as the next listing finishes (ShowItems case
  // of org.freedesktop.FileManager1: several URIs of a folder at once).
  property var pendingSelectNames: []
  // FileManager1 action to apply once the asynchronous listing has selected
  // pendingSelectNames. Empty and show-items only select; show-properties also
  // opens Properties exactly once after selection is ready.
  property string pendingFileManagerAction: ""
  // Counter that forces a refresh of the background panels (signal, not data):
  // ActionEngine/RenameOps/SearchOps increment it after mutating disk.
  property int refreshTick: 0
}

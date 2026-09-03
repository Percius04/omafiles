pragma Singleton
import QtQuick
import "../shared/Utils.js" as Utils

// Current sort criterion (name/size/modified/created/type, asc/desc) --
// thirteenth singleton of the state/ layer. Includes sorting logic directly,
// eliminating the need for SortOps.qml.
QtObject {
  property string sortKey: "name"
  property bool sortDesc: false

  readonly property var sortKeys: ["name", "size", "mtime", "btime", "type"]
  readonly property var sortKeyLabels: ({ name: "Name", size: "Size", mtime: "Modified", btime: "Created", type: "Type" })

  readonly property bool isDefaultOrder: sortKey === "name" && !sortDesc

  // aKey/bKey: precomputed a.name.toLowerCase()/b.name.toLowerCase(), for
  // sortEntries()'s hot path below (cleanup pass -- name is the tie-break
  // for every sort key, and the ONLY comparison for the default "name"
  // sort, so calling toLowerCase() twice per comparator invocation instead
  // of once per entry was the same repeated-per-comparison cost the C++
  // side already fixed once for the exact same reason, see
  // backend/DirectoryModel.cpp's Schwartzian-transform comment). Optional
  // so compareEntries(a, b) alone still works for any other caller.
  function compareEntries(a, b, aKey, bKey) {
    var result = 0
    if (sortKey === "size") {
      result = a.size - b.size
    } else if (sortKey === "mtime") {
      result = a.mtime - b.mtime
    } else if (sortKey === "btime") {
      // btime is 0 where the filesystem reports no birth time, and absent
      // on entries that never came from DirectoryModel (archive listings):
      // both fall through to the name tie-break.
      result = (a.btime || 0) - (b.btime || 0)
    } else if (sortKey === "type") {
      var ea = Utils.extOf(a.name), eb = Utils.extOf(b.name)
      result = ea < eb ? -1 : (ea > eb ? 1 : 0)
    }
    if (result === 0) {
      result = Utils.naturalCompare(aKey !== undefined ? aKey : a.name.toLowerCase(),
                                     bKey !== undefined ? bKey : b.name.toLowerCase())
    }
    return sortDesc ? -result : result
  }

  function sortEntries(list) {
    function decorate(e) { return { e: e, k: e.name.toLowerCase() } }
    function cmp(x, y) { return compareEntries(x.e, y.e, x.k, y.k) }
    function undecorate(d) { return d.e }
    var dirs = list.filter(function (e) { return e.type === "dir" }).map(decorate)
    var files = list.filter(function (e) { return e.type !== "dir" }).map(decorate)
    dirs.sort(cmp)
    files.sort(cmp)
    return dirs.map(undecorate).concat(files.map(undecorate))
  }

  function sortLabel() {
    return sortKeyLabels[sortKey] + (sortDesc ? " ↓" : " ↑")
  }

  function setSort(key) {
    sortKey = key
    NavState.entries = sortEntries(NavState.entries)
  }

  function cycleSort() {
    var idx = sortKeys.indexOf(sortKey)
    setSort(sortKeys[(idx + 1) % sortKeys.length])
  }

  function reverseSort() {
    sortDesc = !sortDesc
    NavState.entries = sortEntries(NavState.entries)
  }
}


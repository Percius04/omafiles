pragma Singleton
import QtQuick
import "../shared/Utils.js" as Utils

// Current sort criterion (name/size/date/type, asc/desc) --
// thirteenth singleton of the state/ layer. Includes sorting logic directly,
// eliminating the need for SortOps.qml.
QtObject {
  property string sortKey: "name"
  property bool sortDesc: false

  readonly property var sortKeys: ["name", "size", "mtime", "type"]
  readonly property var sortKeyLabels: ({ name: "Name", size: "Size", mtime: "Date", type: "Type" })

  readonly property bool isDefaultOrder: sortKey === "name" && !sortDesc

  function compareEntries(a, b) {
    var result = 0
    if (sortKey === "size") {
      result = a.size - b.size
    } else if (sortKey === "mtime") {
      result = a.mtime - b.mtime
    } else if (sortKey === "type") {
      var ea = Utils.extOf(a.name), eb = Utils.extOf(b.name)
      result = ea < eb ? -1 : (ea > eb ? 1 : 0)
    }
    if (result === 0) {
      result = Utils.naturalCompare(a.name.toLowerCase(), b.name.toLowerCase())
    }
    return sortDesc ? -result : result
  }

  function sortEntries(list) {
    var dirs = list.filter(function (e) { return e.type === "dir" })
    var files = list.filter(function (e) { return e.type !== "dir" })
    dirs.sort(compareEntries)
    files.sort(compareEntries)
    return dirs.concat(files)
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

  // Click the same column to reverse; click another column to sort
  // that field ascending. Used by the table header.
  function toggleSort(key) {
    if (sortKey === key) {
      reverseSort()
      return
    }
    sortDesc = false
    setSort(key)
  }
}


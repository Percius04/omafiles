import QtQuick
import Omafiles.Backend as Backend

// Filename search combines a fresh current-folder walk with the fast global
// index. Either may arrive first; each publication is the merged snapshot.
Item {
  id: backend
  property string indexScript: ""
  property string contentScript: ""
  signal results(var entries, bool truncated, bool complete)
  readonly property int maxResults: 200

  property string _query: ""
  property string _root: ""
  property bool _hidden: false
  property string _mode: "name"
  property bool _active: false
  property var _localEntries: []
  property var _indexedEntries: []
  property bool _localTruncated: false
  property bool _localDone: true
  property bool _indexDone: true

  // ProcessRunner refuses a second start until cancellation finishes. Only the
  // newest INDEX request is retained. The local walk starts immediately even
  // if a cancelled index script is slow to exit.
  property bool _pending: false

  function search(query, showHidden, fallbackRoot) {
    _pending = false
    if (indexProc.busy)
      indexProc.cancel()
    recursive.cancel()
    _active = true
    _query = query
    _root = fallbackRoot.replace(/\/+$/, "") || "/"
    _hidden = showHidden
    _localEntries = []
    _indexedEntries = []
    _localTruncated = false
    _localDone = false
    _indexDone = false
    if (query.indexOf("content:") === 0) {
      _mode = "content"
      _indexDone = true
      var term = query.substring(8)
      if ((term.charAt(0) === '"' && term.charAt(term.length - 1) === '"')
          || (term.charAt(0) === "'" && term.charAt(term.length - 1) === "'"))
        term = term.substring(1, term.length - 1)
      if (term.length < 2) {
        _localDone = true
        backend.results([], false, true)
        return
      }
      recursive.searchContent(_root, term, showHidden)
      return
    }
    _mode = "name"
    recursive.search(_root, query, showHidden)
    if (indexProc.busy)
      _pending = true
    else
      _startIndex()
  }

  function _startIndex() {
    indexProc.start([indexScript, _query, String(maxResults + 1), _hidden ? "1" : "0"])
  }

  function cancel() {
    _active = false
    _localDone = true
    _indexDone = true
    _pending = false
    indexProc.cancel()
    recursive.cancel()
  }

  Backend.ProcessRunner {
    id: indexProc
    onFinished: function(result) {
      if (backend._pending) {
        backend._pending = false
        backend._startIndex()
        return
      }
      if (result.cancelled || !backend._active || backend._mode !== "name")
        return
      backend._indexDone = true
      backend._indexedEntries = backend._parse(String(result.stdout || ""))
      backend._publish()
    }
  }

  Backend.SearchWorker {
    id: recursive
    onSnapshot: function(entries, truncated, complete) {
      if (!backend._active)
        return
      backend._localDone = complete
      if (backend._mode === "content") {
        backend.results(entries, truncated, complete)
        return
      }
      backend._localEntries = entries.map(function(e) {
        var copy = Object.assign({}, e)
        copy.path = e.path || (backend._root === "/" ? "/" : backend._root + "/") + e.name
        var slash = copy.path.lastIndexOf("/")
        copy.name = copy.path.substring(slash + 1)
        copy.parent = copy.path.substring(0, slash) || "/"
        return copy
      })
      backend._localTruncated = truncated
      backend._publish()
    }
  }

  function _parse(stdout) {
    var entries = []
    var lines = stdout.split("\n")
    for (var i = 0; i < lines.length; ++i) {
      var tab = lines[i].indexOf("\t")
      if (tab < 0)
        continue
      var path = lines[i].substring(tab + 1)
      if (path.charAt(0) !== "/")
        continue
      var slash = path.lastIndexOf("/")
      entries.push({type: lines[i].substring(0, tab), path: path,
                    name: path.substring(slash + 1), parent: path.substring(0, slash) || "/",
                    size: 0, mtime: 0, link: false})
    }
    return entries
  }

  function _publish() {
    var q = _query.toLowerCase()
    var prefix = _root === "/" ? "/" : _root + "/"
    // Prefer live metadata when the same absolute path is also indexed.
    var seen = Object.create(null)
    var entries = _localEntries.concat(_indexedEntries).filter(function(e) {
      if (seen[e.path]) return false
      seen[e.path] = true
      return true
    })
    for (var i = 0; i < entries.length; ++i) {
      var e = entries[i]
      var name = e.name.toLowerCase()
      e._scope = e.path.indexOf(prefix) === 0 ? 0 : 1
      e._score = name === q ? 0 : name.indexOf(q) === 0 ? 1 : name.indexOf(q) >= 0 ? 2 : 3
    }
    entries.sort(function(a, b) {
      if (a._scope !== b._scope) return a._scope - b._scope
      if (a._score !== b._score) return a._score - b._score
      if (a.path.length !== b.path.length) return a.path.length - b.path.length
      return a.name.localeCompare(b.name)
    })
    backend.results(entries.slice(0, maxResults), _localTruncated || entries.length > maxResults, _localDone && _indexDone)
  }
}

import QtQuick
import "../state"
import Omafiles.Backend as Backend
import "../shared/Utils.js" as Utils

// File metadata: row subtitle (size + date, or trash
// info) and audio info for the preview -- twenty-second
// component extracted from core.
Item {
  property Item root: null

  function parseAudioInfo(text) {
    var out = []
    var data
    try { data = JSON.parse(text) } catch (e) { return out }
    var fmt = (data && data.format) || {}
    var stream = (data && data.streams && data.streams[0]) || {}
    var dur = parseFloat(fmt.duration || stream.duration || 0)
    if (dur > 0) {
      var mins = Math.floor(dur / 60)
      var secs = Math.round(dur % 60)
      out.push({ label: "Duration", value: mins + ":" + (secs < 10 ? "0" : "") + secs })
    }
    if (stream.codec_name) out.push({ label: "Codec", value: String(stream.codec_name).toUpperCase() })
    if (fmt.bit_rate) out.push({ label: "Bitrate", value: Math.round(fmt.bit_rate / 1000) + " kbps" })
    if (stream.sample_rate) out.push({ label: "Sample rate", value: Math.round(stream.sample_rate / 1000) + " kHz" })
    if (stream.channels) {
      out.push({ label: "Channels", value: stream.channels === 1 ? "Mono" : stream.channels === 2 ? "Stereo" : String(stream.channels) })
    }
    var tags = fmt.tags || {}
    if (tags.artist) out.push({ label: "Artist", value: tags.artist })
    if (tags.title) out.push({ label: "Title", value: tags.title })
    if (tags.album) out.push({ label: "Album", value: tags.album })
    return out
  }

  // Row subtitle -- size + relative date for files, only
  // date for folders (same spirit as the "Connected" of the real
  // composed-row examples of Omarchy: name + one line of context).
  // basePath: the path of the panel painting this row -- by
  // default NavState.currentPath (active panel), but a background panel must
  // pass its own (bgPanel.modelData.path) or the "in the
  // trash" notice would come out according to the ACTIVE panel's folder, not this
  // panel's (same kind of bug already documented for thumbKeyFor/etc.).
  // TrashState.trashInfo is shared between the active panel and all the background
  // ones (see bgTrashInfoProc in BackgroundPanel.qml) -- whoever
  // fills it first (active or any background panel) serves them all,
  // so this function always reads the same copy regardless of who
  // paints the row.
  function metaFor(entry, basePath) {
    if (entry.link === "broken") return "Broken link"
    // CONTENT search result (ripgrep, Beta 3): the subtitle is the
    // LINE + the snippet of the match (what you searched for), not size/date
    // nor the path -- the path goes in the tooltip (metaTooltipFor). It is what is useful here.
    if (entry.snippet !== undefined) return "L" + (entry.line || 0) + "  " + entry.snippet
    // GLOBAL search result (SearchBackend): the entry carries an absolute
    // path of any other folder, so the subtitle gives the CONTEXT
    // (where it lives), not size/date -- like Nautilus/Spotlight. `parent`
    // already comes computed; we abbreviate the home to "~" so it fits and reads.
    if (entry.path && entry.parent) {
      var home = Paths.homeDir
      return (entry.parent.indexOf(home) === 0)
        ? "~" + entry.parent.substring(home.length)
        : entry.parent
    }
    var atPath = basePath !== undefined ? basePath : NavState.currentPath
    if (atPath === Paths.trashDir) {
      var parts = []
      if (entry.type !== "dir") parts.push(Utils.formatSize(entry.size))
      var info = TrashState.trashInfo[entry.path]
      if (info) {
        var rel = Utils.relativeTime(info.epoch)
        parts.push(rel ? "Deleted " + rel : "Deleted")
        if (info.origPath) {
          var slash = info.origPath.lastIndexOf("/")
          parts.push("from " + (slash > 0 ? info.origPath.substring(0, slash) : "/"))
        }
      }
      return parts.join(" · ")
    }
    var parts = []
    if (entry.type !== "dir") {
      parts.push(Utils.formatSize(entry.size))
    } else {
      // Item counter: occupies the "size slot" in the
      // folders. It comes from the async FolderCountState cache (the visible
      // row requests it); while it has not arrived (or -1 = no access) nothing
      // is shown, so the row does not jump.
      var fc = FolderCountState.counts[Utils.joinPath(atPath, entry.name)]
      if (typeof fc === "number" && fc >= 0) parts.push(Utils.formatItemCount(fc))
    }
    var rel = Utils.relativeTime(entry.mtime)
    if (rel) parts.push(rel)
    return parts.join(" · ")
  }

  // Subtitle tooltip: the EXACT value of the counter only when it is shown
  // abbreviated (12.3k -> "12,347 items"); "" otherwise (no tooltip).
  function metaTooltipFor(entry, basePath) {
    // Content result: the tooltip shows the file's full PATH
    // (the subtitle replaced it with the snippet).
    if (entry.snippet !== undefined) return entry.path || ""
    // Global result: the tooltip shows the FULL parent path (without abbreviating
    // the home), which in the subtitle may go trimmed.
    if (entry.path && entry.parent) return entry.parent
    if (entry.type !== "dir") return ""
    var atPath = basePath !== undefined ? basePath : NavState.currentPath
    var fc = FolderCountState.counts[Utils.joinPath(atPath, entry.name)]
    if (typeof fc === "number" && Utils.itemCountAbbreviated(fc)) return Utils.formatItemCountExact(fc)
    return ""
  }

  // Async path of the folder counter: the backend counts on a
  // thread and responds via counted(); here it is dumped to the reactive cache, which
  // re-evaluates the subtitles. A single point (FileMeta is instantiated once).
  Connections {
    target: Backend.FolderCounter
    function onCounted(path, n) { FolderCountState.set(path, n) }
  }
}

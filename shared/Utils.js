.pragma library

// Common pure utility functions.

function formatSize(bytes) {
  if (bytes < 1024) return bytes + " B"
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " K"
  if (bytes < 1024 * 1024 * 1024) return (bytes / 1024 / 1024).toFixed(1) + " M"
  return (bytes / 1024 / 1024 / 1024).toFixed(1) + " G"
}

// Thousands separator: 1234 -> "1,234".
function _withThousands(n) {
  return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

// Smart formatting of the per-folder item counter:
//   <10k -> exact with thousands separator (1 item / 2 items / 1,234 items)
//   <1M  -> abbreviated 12.3k items
//   >=1M -> abbreviated 1.2M items
function formatItemCount(n) {
  if (typeof n !== "number" || n < 0) return ""
  if (n < 10000) return _withThousands(n) + (n === 1 ? " item" : " items")
  if (n < 1000000) return (n / 1000).toFixed(1).replace(/\.0$/, "") + "k items"
  return (n / 1000000).toFixed(1).replace(/\.0$/, "") + "M items"
}

// EXACT value (with thousands separator) for the tooltip when the counter is
// shown abbreviated: 12,347 items.
function formatItemCountExact(n) {
  if (typeof n !== "number" || n < 0) return ""
  return _withThousands(n) + (n === 1 ? " item" : " items")
}

// Is the displayed format abbreviated (k/M) and therefore worth a tooltip
// with the exact value?
function itemCountAbbreviated(n) {
  return typeof n === "number" && n >= 10000
}

function relativeTime(epochSeconds) {
  if (!epochSeconds) return ""
  var diff = Math.floor(Date.now() / 1000) - epochSeconds
  if (diff < 60) return "just now"
  if (diff < 3600) return Math.floor(diff / 60) + " min ago"
  if (diff < 86400) return Math.floor(diff / 3600) + " h ago"
  if (diff < 86400 * 30) return Math.floor(diff / 86400) + " d ago"
  if (diff < 86400 * 365) return Math.floor(diff / (86400 * 30)) + " mo ago"
  return Math.floor(diff / (86400 * 365)) + " yr ago"
}

// Compares numbers as numbers, not letter by letter.
function naturalCompare(a, b) {
  var ax = [], bx = []
  a.replace(/(\d+)|(\D+)/g, function (_, d, s) { ax.push([d || Infinity, s || ""]) })
  b.replace(/(\d+)|(\D+)/g, function (_, d, s) { bx.push([d || Infinity, s || ""]) })
  while (ax.length && bx.length) {
    var an = ax.shift(), bn = bx.shift()
    var nn = (an[0] - bn[0]) || an[1].localeCompare(bn[1])
    if (nn) return nn
  }
  return ax.length - bx.length
}

// Joins a base directory and a name into an absolute path, treating "/"
// as a special case (avoids "//name").
function joinPath(base, name) {
  return base === "/" ? "/" + name : base + "/" + name
}

// Basenames accepted by Linux file operations in the UI. The C++ rename
// boundary repeats this check. Spaces, leading dashes and Unicode are valid.
function validBasename(name) {
  var s = String(name === undefined || name === null ? "" : name)
  return s.length > 0 && s !== "." && s !== ".." && s.indexOf("/") < 0
      && s.indexOf(String.fromCharCode(0)) < 0
}

function basenamePathMatches(name, path) {
  if (!validBasename(name) || !path) return false
  var parent = String(path).substring(0, String(path).lastIndexOf("/"))
  return joinPath(parent || "/", String(name)) === String(path)
}

// Absolute path of an entry. In a normal listing (or recursive search)
// the entry carries `name` relative to `base`. In indexed global search
// the entry carries an absolute `path`.
function entryPath(base, entry) {
  return entry && entry.path ? entry.path : joinPath(base, entry.name)
}

// In-memory key of the VideoThumbState.videoThumbReady dict (path|mtime).
function thumbKeyFor(entry, basePath) {
  return joinPath(basePath, entry.name) + "|" + entry.mtime
}

// Compares two entry lists by content, O(n) without allocations.
function entriesEqual(a, b) {
  if (a === b) return true
  if (!a || !b || a.length !== b.length) return false
  for (var i = 0; i < a.length; i++) {
    var x = a[i], y = b[i]
    if (x.name !== y.name || x.type !== y.type || x.size !== y.size
        || x.mtime !== y.mtime || x.link !== y.link) return false
  }
  return true
}

// Decodes a device label from findmnt raw format.
function decodeDeviceLabel(s) {
  var raw = String(s || "")
  var pct = raw.replace(/\\x([0-9A-Fa-f]{2})/g, "%$1")
  try {
    return decodeURIComponent(pct)
  } catch (e) {
    return raw.replace(/\\x([0-9A-Fa-f]{2})/g, function (_, h) {
      return String.fromCharCode(parseInt(h, 16))
    })
  }
}

function parseMounts(text) {
  var lines = String(text || "").split("\n").filter(function (l) { return l.length > 0 })
  return lines.map(function (l) {
    var parts = l.split("\t")
    return { label: decodeDeviceLabel(parts[0]), path: decodeDeviceLabel(parts[1]), device: parts[2] || "", removable: parts[3] === "1", mounted: parts[4] !== "0", fstype: parts[5] || "" }
  })
}

// File type extension lists and glyph/type helpers
var IMAGE_EXTS = ["jpg", "jpeg", "png", "gif", "webp", "bmp"]
var VIDEO_EXTS = ["mp4", "mkv", "webm", "avi", "mov", "flv", "m4v"]
var AUDIO_EXTS = ["mp3", "flac", "wav", "ogg", "m4a", "opus"]
var ARCHIVE_EXTS = ["zip", "tar", "gz", "xz", "rar", "7z", "bz2", "zst"]
var CODE_EXTS = ["js", "ts", "py", "lua", "sh", "c", "cpp", "h", "rs", "go", "html", "css", "json", "qml", "md", "yml", "yaml", "toml"]

function extOf(name) {
  var idx = (name || "").lastIndexOf(".")
  return idx > 0 ? name.substring(idx + 1).toLowerCase() : ""
}

function iconFor(entry) {
  if (!entry) return "󰈤"
  var ext = extOf(entry.name)
  if (ext === "iso") return "󰗮"
  if (IMAGE_EXTS.indexOf(ext) >= 0) return "󰺰"
  if (VIDEO_EXTS.indexOf(ext) >= 0) return "󰸬"
  if (AUDIO_EXTS.indexOf(ext) >= 0) return "󰸪"
  if (ARCHIVE_EXTS.indexOf(ext) >= 0) return "󰗄"
  if (ext === "pdf") return "󰈦"
  if (CODE_EXTS.indexOf(ext) >= 0) return "󱀫"
  return "󰈤"
}

function isImage(entry) {
  return !!entry && entry.type === "file" && IMAGE_EXTS.indexOf(extOf(entry.name)) >= 0
}

function isVideo(entry) {
  return !!entry && entry.type === "file" && VIDEO_EXTS.indexOf(extOf(entry.name)) >= 0
}

function isAudio(entry) {
  return !!entry && entry.type === "file" && AUDIO_EXTS.indexOf(extOf(entry.name)) >= 0
}

function isPdf(entry) {
  return !!entry && entry.type === "file" && extOf(entry.name) === "pdf"
}

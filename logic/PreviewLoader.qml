import "../shared/Utils.js" as Utils
import QtQuick
import "../state"
import Omafiles.Backend as Backend

// Preview loading (Space) -- seventeenth component extracted from
// core. PreviewPanel.qml paints PreviewContentState.previewText/
// previewHighlighted/previewPdfImage/previewImage/previewAudioInfo; this
// component is the one that fills them.
//
//   - Plain text & Syntax Highlighting: PreviewProvider.requestText + SyntaxHighlighter
//     (in-process C++, async with cancellation) -- sub-millisecond, no subprocesses.
//   - Image and PDF: ThumbnailProvider at preview size (QImageReader/
//     QPdfDocument + on-disk cache).
// Video thumbnail uses ffmpegthumbnailer and audio metadata uses ffprobe.
Item {
  property Item root: null

  property Item videoThumbs: null
  property Item fileMeta: null

  // Max side (px) of the image/PDF render of the preview -- generous so it
  // looks sharp in the panel (≈45% width) of a large monitor.
  readonly property int previewSize: 1600

  Connections {
    target: SelectionState
    function onSelectedIndexChanged() {
      if (PreviewState.previewOpen) {
        var idx = SelectionState.selectedIndex
        if (idx >= 0 && idx < NavState.visibleEntries.length && NavState.visibleEntries[idx].type !== "dir") {
          loadPreview(NavState.visibleEntries[idx])
        } else {
          PreviewState.previewOpen = false
        }
      }
    }
  }

  function togglePreview() {
    if (PreviewState.previewOpen) {
      PreviewState.previewOpen = false
      return
    }
    if (SelectionState.selectedIndex < 0 || SelectionState.selectedIndex >= NavState.visibleEntries.length) return
    loadPreview(NavState.visibleEntries[SelectionState.selectedIndex])
  }

  function loadPreview(entry) {
    // A directory (or no entry) has no preview: bail WITHOUT leaving the
    // previous file's preview state behind. In particular previewIsText must
    // be reset, otherwise a later directory listing keeps the old file's text
    // ghosted behind it (the third-column dir listing is not a text entry but
    // would still render as text because isTextEntry checks previewIsText).
    if (!entry || entry.type === "dir") {
      PreviewContentState.previewIsText = false
      PreviewContentState.previewText = ""
      PreviewContentState.previewHighlighted = ""
      return
    }
    PreviewContentState.previewRequestId += 1
    var reqId = PreviewContentState.previewRequestId
    PreviewContentState.previewEntry = entry
    PreviewState.previewOpen = true
    var ext = Utils.extOf(entry.name)
    var path = Utils.entryPath(NavState.currentPath, entry)
    var isImg = Utils.isImage(entry)
    var isPdf = Utils.isPdf(entry)
    var isVid = Utils.isVideo(entry)
    var isAud = Utils.isAudio(entry)
    var isTxt = (FileTypeConfig.codeExt.indexOf(ext) >= 0 || ext === "txt" || ext === "conf" || ext === "") && !isImg

    PreviewContentState.previewIsText = isTxt

    if (isTxt) {
      PreviewContentState._previewTextOwner = reqId
      Backend.PreviewProvider.requestText(path)
    } else {
      PreviewContentState.previewText = ""
      PreviewContentState.previewHighlighted = ""
    }

    if (isImg) {
      PreviewContentState._previewImageOwner = reqId
      var img = Backend.ThumbnailProvider.request(path, previewSize)
      PreviewContentState.previewImage = img || ""
    } else {
      PreviewContentState.previewImage = ""
    }

    if (isPdf) {
      PreviewContentState._previewPdfOwner = reqId
      var pdf = Backend.ThumbnailProvider.request(path, previewSize)
      PreviewContentState.previewPdfImage = pdf || ""
    } else {
      PreviewContentState.previewPdfImage = ""
    }

    if (isVid) {
      videoThumbs.requestVideoThumb(entry)
    }

    if (isAud) {
      PreviewContentState._previewAudioOwner = reqId
      Backend.PreviewProvider.requestAudio(path)
    } else {
      PreviewContentState.previewAudioInfo = []
    }
  }

  // Plain text & syntax highlighted & audio metadata ready (PreviewProvider).
  Connections {
    target: Backend.PreviewProvider
    function onTextReady(path, content, highlighted, encoding, bytes, lines, truncated) {
      if (PreviewContentState._previewTextOwner === PreviewContentState.previewRequestId) {
        PreviewContentState.previewText = content
        PreviewContentState.previewHighlighted = highlighted
      }
    }
    function onAudioReady(path, info) {
      if (PreviewContentState._previewAudioOwner === PreviewContentState.previewRequestId) {
        PreviewContentState.previewAudioInfo = info
      }
    }
  }

  // Image/PDF thumbnail at preview size ready.
  Connections {
    target: Backend.ThumbnailProvider
    function onReady(path, thumbPath) {
      var e = PreviewContentState.previewEntry
      if (!e || path !== Utils.entryPath(NavState.currentPath, e)) return
      if (Utils.isImage(e) && PreviewContentState._previewImageOwner === PreviewContentState.previewRequestId) {
        var p = Backend.ThumbnailProvider.request(path, previewSize)
        if (p) PreviewContentState.previewImage = p
      } else if (Utils.isPdf(e) && PreviewContentState._previewPdfOwner === PreviewContentState.previewRequestId) {
        var q = Backend.ThumbnailProvider.request(path, previewSize)
        if (q) PreviewContentState.previewPdfImage = q
      }
    }
  }
}

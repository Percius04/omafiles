import QtQuick
import Omafiles.Backend as Backend
import "../../../state"
import "../../../shared/Utils.js" as Utils

// Domain checks extracted from app/SelfCheck.qml (_register).
// Structural refactor only — behavior unchanged.
QtObject {
  function register(sc) {
        sc.add("Backend.ThumbnailProvider PNG", function (done) {
          var immediate = Backend.ThumbnailProvider.request(sc.png, 128)
          if (immediate && immediate.length > 0) { done(true, "cache hit"); return }
          function onReady(path, thumbPath) {
            if (path !== sc.png) return
            Backend.ThumbnailProvider.ready.disconnect(onReady)
            done(thumbPath.length > 0, thumbPath ? "" : "thumbPath empty")
          }
          Backend.ThumbnailProvider.ready.connect(onReady)
        })

        sc.add("Backend.ThumbnailProvider PDF (qpdf plugin)", function (done) {
          var immediate = Backend.ThumbnailProvider.request(sc.pdf, 128)
          if (immediate && immediate.length > 0) { done(true, "cache hit"); return }
          function onReady(path, thumbPath) {
            if (path !== sc.pdf) return
            Backend.ThumbnailProvider.ready.disconnect(onReady)
            done(thumbPath.length > 0, thumbPath ? "" : "no thumbnail (is qpdf missing?)")
          }
          Backend.ThumbnailProvider.ready.connect(onReady)
        })

        // Canonical cache hash: Backend.ThumbnailProvider.cacheKey is the
        // ONLY scheme (SHA-1 hex), shared by the image/PDF thumbnails
        // (internal to request()), the video ones (VideoThumbnails) and the
        // extraction cache (ArchiveActions). It's anchored against the known SHA-1 of a
        // fixed entry so that any scheme change (which would invalidate the whole
        // on-disk cache) breaks the harness instead of going unnoticed.
        sc.add("Thumbnail cache key is canonical SHA-1 (B1)", function (done) {
          var k = Backend.ThumbnailProvider.cacheKey("omafiles-b1|42")
          var expected = "244adfd729888c0a4499250ebb2e9f41d7243600" // sha1("omafiles-b1|42")
          var hexOk = /^[0-9a-f]{40}$/.test(k)
          var stable = Backend.ThumbnailProvider.cacheKey("omafiles-b1|42") === k
          done(hexOk && stable && k === expected,
               "cacheKey=" + k + (k === expected ? "" : " (expected " + expected + ")"))
        })

        // Thumbnail cache pruning. Exercises pruneCacheDir over
        // a temp dir (the real cache is NOT touched: the constructor's auto-prune
        // is skipped under --selfcheck) with the four policies: legacy orphan,
        // safety (foreign files intact), age and size.
        sc.add("Thumbnail cache pruning: orphans, safety, age, size (O1)", function (done) {
          var TP = Backend.ThumbnailProvider
          var pd = sc.dir + "/prunecache-" + Date.now()
          var h1 = Backend.ThumbnailProvider.cacheKey("o1-a")   // valid 40-hex name
          var h2 = Backend.ThumbnailProvider.cacheKey("o1-b")
          var BIG_AGE = 999999999, BIG_SIZE = 999999999999
          var mk = function (name) { return function () { Backend.FileOperations.copy(sc.note, pd + "/" + name) } }

          Backend.FileOperations.mkdir(pd)
          sc._fileOp(done, function () {
            sc._seqOps([
              mk(h1 + ".png"),      // current thumbnail (.png)
              mk(h2 + ".jpg"),      // current thumbnail (.jpg)
              mk("deadbe.jpg"),     // legacy base36 orphan (.jpg, 6 chars) -> delete
              mk("notahash.png"),   // non-hex .png -> foreign, leave (safety)
              mk("readme.txt")      // non-image -> leave (safety)
            ], done, function () {
              // (1) large thresholds -> only the legacy orphan.
              var r1 = TP.pruneCacheDir(pd, BIG_AGE, BIG_SIZE)
              sc._listOnce(pd, function (e1) {
                var ok1 = r1 === 1 && !sc._has(e1, "deadbe.jpg")
                  && sc._has(e1, h1 + ".png") && sc._has(e1, h2 + ".jpg")
                  && sc._has(e1, "notahash.png") && sc._has(e1, "readme.txt")
                if (!ok1) { done(false, "orphan/safety: removed=" + r1 + " entries=" + e1.length); return }
                // (2) age: maxAge=0 -> deletes the 2 current thumbnails; leaves foreign ones.
                var r2 = TP.pruneCacheDir(pd, 0, BIG_SIZE)
                sc._listOnce(pd, function (e2) {
                  var ok2 = r2 === 2 && !sc._has(e2, h1 + ".png") && !sc._has(e2, h2 + ".jpg")
                    && sc._has(e2, "notahash.png") && sc._has(e2, "readme.txt")
                  if (!ok2) { done(false, "age: removed=" + r2 + " entries=" + e2.length); return }
                  // (3) size: recreates 2 current ones and prunes with maxBytes=0 -> deletes them
                  // by the size policy (ordered by age).
                  sc._seqOps([mk(h1 + ".png"), mk(h2 + ".jpg")], done, function () {
                    var r3 = TP.pruneCacheDir(pd, BIG_AGE, 0)
                    sc._listOnce(pd, function (e3) {
                      var ok3 = r3 === 2 && !sc._has(e3, h1 + ".png") && !sc._has(e3, h2 + ".jpg")
                      done(ok3, ok3 ? "orphan+safety+age+size OK"
                                    : "size: removed=" + r3 + " entries=" + e3.length)
                    })
                  })
                })
              })
            })
          })
        })

        sc.add("Backend.PreviewProvider text", function (done) {
          function onText(path, content, highlighted, enc, bytes, lines, trunc) {
            if (path !== sc.note) return
            Backend.PreviewProvider.textReady.disconnect(onText)
            var ok = content.indexOf("hello selfcheck") >= 0
            done(ok, ok ? enc + ", " + lines + " lines" : "unexpected content")
          }
          Backend.PreviewProvider.textReady.connect(onText)
          Backend.PreviewProvider.requestText(sc.note, 65536)
        })

        sc.add("Backend.PreviewProvider native syntax highlighting", function (done) {
          var cppSample = "#include <iostream>\nint main() { return 0; }\n"
          var pySample = "def hello():\n    print('world')\n"
          var qmlSample = "import QtQuick\nItem { id: root; property int count: 42 }\n"

          var cppHtml = Backend.PreviewProvider.highlightCode(cppSample, "main.cpp")
          var pyHtml = Backend.PreviewProvider.highlightCode(pySample, "script.py")
          var qmlHtml = Backend.PreviewProvider.highlightCode(qmlSample, "App.qml")

          var cppOk = cppHtml.indexOf("<pre style=\"white-space:pre-wrap; word-break:break-word\">") >= 0
                   && cppHtml.indexOf("color:#fb4934") >= 0 // keyword (int, return)
                   && cppHtml.indexOf("color:#8ec07c") >= 0 // preproc (#include)

          var pyOk = pyHtml.indexOf("color:#fb4934") >= 0 // def
                  && pyHtml.indexOf("color:#b8bb26") >= 0 // string ('world')

          var qmlOk = qmlHtml.indexOf("color:#fb4934") >= 0 // import, property
                   && qmlHtml.indexOf("color:#d3869b") >= 0 // number 42

          var supported = Backend.PreviewProvider.isHighlightable("test.cpp")
                       && Backend.PreviewProvider.isHighlightable("test.py")
                       && Backend.PreviewProvider.isHighlightable("test.rs")
                       && !Backend.PreviewProvider.isHighlightable("test.unknownext123")

          var allOk = cppOk && pyOk && qmlOk && supported
          done(allOk, allOk ? "C++, Python, QML highlighting OK" : "highlighting check failed")
        })

        sc.add("Backend.PreviewProvider native audio metadata", function (done) {
          var syncInfo = Backend.PreviewProvider.audioMetadata(sc.wav)
          var hasWav = syncInfo.length > 0

          function onAudio(path, info) {
            if (path !== sc.wav) return
            Backend.PreviewProvider.audioReady.disconnect(onAudio)
            var ok = info && info.length > 0
            var codecOk = false
            for (var i = 0; i < info.length; ++i) {
              if (info[i].label === "Codec" && info[i].value === "WAV") codecOk = true
            }
            var pass = hasWav && ok && codecOk
            done(pass, pass ? "WAV metadata parsed: items=" + info.length : "audio metadata extraction failed")
          }

          Backend.PreviewProvider.audioReady.connect(onAudio)
          Backend.PreviewProvider.requestAudio(sc.wav)
        })

        sc.add("Backend.PreviewProvider info", function (done) {
          var info = Backend.PreviewProvider.info(sc.note)
          var ok = info && typeof info === "object" && Object.keys(info).length > 0
          done(ok, ok ? "keys=[" + Object.keys(info).join(",") + "]" : "info empty")
        })
  }
}

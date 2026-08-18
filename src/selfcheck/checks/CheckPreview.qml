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

        // Regression for P0-4 (forensic audit 2026-08-16): scripts/runtime/
        // thumbnail-video.sh only checked `[[ -f "$dest" ]]` before letting
        // ffmpegthumbnailer write to $dest -- a DANGLING symlink pre-planted at
        // that fully predictable (unsalted SHA-1) cache path made `-f` false
        // (correctly: nothing real is there YET) but ffmpegthumbnailer's own
        // `open()` follows the link anyway, creating a brand-new file at
        // whatever the symlink points to instead of a fresh, contained cache
        // entry. Plants that exact dangling symlink and asserts the target
        // never gets created and $dest ends up a real file, not a symlink.
        sc.add("thumbnail-video.sh: pre-planted dangling symlink at dest is not followed (P0-4 regression)", function (done) {
          var video = sc.opsDir + "/p04-src.mp4"
          var dest = sc.opsDir + "/p04-thumb.jpg"
          var victimTarget = sc.opsDir + "/p04-victim-target.jpg" // must NOT exist beforehand
          var setup = "rm -f " + sc._q(video) + " " + sc._q(dest) + " " + sc._q(victimTarget)
            + " && ffmpeg -y -f lavfi -i color=c=blue:s=64x64:d=1 -frames:v 5 -pix_fmt yuv420p "
            + sc._q(video) + " -loglevel quiet"
            + " && ln -s " + sc._q(victimTarget) + " " + sc._q(dest)
          sc._sh(["bash", "-c", setup], function (setupResult) {
            if (setupResult.exitCode !== 0) { done(false, "fixture setup failed: " + setupResult.stderr); return }
            sc._sh(["bash", sc.resourceRoot + "/scripts/runtime/thumbnail-video.sh", video, dest], function () {
              var check = "test -L " + sc._q(dest) + " && echo DEST_IS_SYMLINK; "
                + "test -e " + sc._q(victimTarget) + " && echo VICTIM_CREATED; "
                + "test -f " + sc._q(dest) + " && echo DEST_IS_REGULAR_FILE; "
                + "command -v ffmpegthumbnailer >/dev/null && echo HAVE_THUMBNAILER"
              sc._sh(["bash", "-c", check], function (checkResult) {
                var out = String(checkResult.stdout)
                var stillSymlink = out.indexOf("DEST_IS_SYMLINK") >= 0
                var victimCreated = out.indexOf("VICTIM_CREATED") >= 0
                var destIsRegular = out.indexOf("DEST_IS_REGULAR_FILE") >= 0
                var haveThumbnailer = out.indexOf("HAVE_THUMBNAILER") >= 0
                // The two SECURITY properties -- the planted symlink was
                // destroyed rather than written through, and its target was
                // never created -- hold whether or not a thumbnail was
                // actually produced. destIsRegular is a FUNCTIONAL check on
                // top, and it can only be true if ffmpegthumbnailer is
                // installed; it is an optional dependency (README), so
                // requiring it unconditionally made this check report
                // "VULNERABLE" on any machine without it, while the machine
                // was in fact perfectly safe.
                var secure = !stillSymlink && !victimCreated
                var safe = secure && (destIsRegular || !haveThumbnailer)
                done(safe, safe
                  ? (destIsRegular
                     ? "dest is a genuine regular file; the dangling symlink's target was never created"
                     : "symlink safety verified (planted link destroyed, target never created); "
                       + "thumbnail write not exercised -- ffmpegthumbnailer not installed")
                  : (secure
                     ? "thumbnail-video.sh did not produce a regular file at dest despite "
                       + "ffmpegthumbnailer being installed (symlink safety itself held)"
                     : "VULNERABLE: dest still a symlink=" + stillSymlink
                       + " victim target created=" + victimCreated
                       + " dest is a regular file=" + destIsRegular))
              })
            })
          })
        })

        // Regression for P0 concurrency audit (forensic audit 2026-08-16):
        // ThumbnailProvider had NO lifetime guard at all -- no destructor,
        // no Life/mutex, nothing. Its pool worker called
        // QMetaObject::invokeMethod(this, ...) completely unguarded, so
        // closing the app while a thumbnail was still generating was a
        // confirmed use-after-free that crashed Qt's own event delivery
        // (reproduced with AddressSanitizer: SEGV inside
        // QCoreApplicationPrivate::notify_helper, 8/8 iterations before the
        // fix, 0/8 after). ThumbnailProvider is a QML_SINGLETON, so this
        // can't destroy it mid-generate the way the SearchWorker regression
        // test does -- instead this fires many concurrent, DISTINCT
        // requests (distinct cache keys, so none short-circuit on the
        // m_inflight dedup) and confirms every one delivers exactly once,
        // no crash, no stuck "already generating" state left behind.
        sc.add("ThumbnailProvider: many concurrent distinct requests all deliver exactly once (P0 regression)", function (done) {
          var n = 12
          var buildCmd = "for i in $(seq 1 " + n + "); do cp -- " + sc._q(sc.png)
            + " " + sc._q(sc.opsDir) + "/p0-thumb-$i.png; done"
          sc._sh(["bash", "-c", buildCmd], function (buildResult) {
            if (buildResult.exitCode !== 0) { done(false, "fixture build failed: " + buildResult.stderr); return }
            var paths = []
            for (var k = 1; k <= n; k++) paths.push(sc.opsDir + "/p0-thumb-" + k + ".png")
            var delivered = {}
            var extraCalls = 0
            function onReady(path, thumbPath) {
              if (paths.indexOf(path) < 0) return // unrelated thumbnail from another test
              if (delivered[path]) { extraCalls++; return } // would indicate a duplicate/corrupted delivery
              delivered[path] = thumbPath
            }
            Backend.ThumbnailProvider.ready.connect(onReady)
            paths.forEach(function (p) { Backend.ThumbnailProvider.request(p, 128) })
            sc._poll(function () { return Object.keys(delivered).length === n }, function (ok) {
              Backend.ThumbnailProvider.ready.disconnect(onReady)
              var allNonEmpty = ok && paths.every(function (p) { return delivered[p] && delivered[p].length > 0 })
              done(allNonEmpty && extraCalls === 0,
                allNonEmpty && extraCalls === 0
                  ? n + " concurrent distinct requests all delivered exactly once"
                  : "delivered=" + Object.keys(delivered).length + "/" + n + " extraCalls=" + extraCalls)
            })
          })
        })

        // Canonical cache hash: Backend.ThumbnailProvider.cacheKey is the
        // ONLY scheme (SHA-1 hex), shared by the image/PDF thumbnails
        // (internal to request()), the video ones (VideoThumbnails) and the
        // extraction cache (logic/ArchiveBrowser.qml's openFile()). It's
        // anchored against the known SHA-1 of a fixed entry so that any
        // scheme change (which would invalidate the whole on-disk cache)
        // breaks the harness instead of going unnoticed.
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

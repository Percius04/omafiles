import QtQuick
import Omafiles.Backend as Backend
import "../../state"
import "../../shared/Utils.js" as Utils
import "."

// SelfCheck -- reproducible functional validation harness of Omafiles (Phase
// 12, josema). It's loaded from main.cpp when the standalone executable
// Starts with `--selfcheck`, headless (offscreen) functional verification test harness.
// the main subsystems of backend, frontend and integration over
// deterministic fixtures (mounted by main.cpp in a QTemporaryDir that
// removes itself) and ends with Qt.exit(number of failures): 0 = all PASS.
//
// Design: a sequential, asynchronous runner. Each test is
//   add(name, function(done){ ... done(pass, message) })
// and can resolve synchronously or when a signal arrives; a per-test
// timeout avoids hangs. Extensible: adding tests = adding add(...) in
// _register(). It doesn't use QtTest nor touch the normal behavior of the app.
//
// Base for Phase 13 (migrate FileOperations from shell to the C++ backend):
// these same checks will run before and after each
// operation to shield that migration.
QtObject {
  id: sc

  // Temporary directory with fixtures, injected by main.cpp. Fallback in
  // case it's loaded by hand (it shouldn't be).
  readonly property string dir: (typeof selfCheckTmpDir !== "undefined" && selfCheckTmpDir)
    ? selfCheckTmpDir : "/tmp/omafiles-selfcheck"

  // ---- fixture paths (see writeSelfCheckFixtures in main.cpp) ----
  readonly property string listDir: dir + "/list"
  readonly property string watchDir: dir + "/watch"
  readonly property string opsDir: dir + "/ops"
  readonly property string jsonFile: dir + "/json/t.json"
  readonly property string png: dir + "/img.png"
  readonly property string pdf: dir + "/doc.pdf"
  readonly property string wav: dir + "/audio.wav"
  readonly property string note: dir + "/note.txt"

  // ---- runner state ----
  property var checks: []
  property int idx: -1
  property int passes: 0
  property int fails: 0
  property real _startedAt: 0
  property bool _settled: false

  // DirectoryModel factory for the existence/listing checks
  // (non-singleton service wrapped over the C++ backend).
  property Component _dmFactory: Component { Backend.DirectoryModel {} }

  // SearchWorker factory (native backend, non-singleton) for the
  // recursive search test.
  property Component _searchFactory: Component { Backend.SearchWorker {} }

  // hostPanelsRow stub for the background panel test: BackgroundPanel reads
  // slotX(index)/slotWidth/height for its geometry. slotWidth/height 0 => the
  // ListView doesn't instantiate delegates (no null visual dependencies).
  // height/width are built-in Item properties (default 0); only
  // slotX()/slotWidth are added, which BackgroundPanel expects from hostPanelsRow.
  property Component _panelsRowStub: Component {
    Item { function slotX(i) { return 0 } property real slotWidth: 0 }
  }

  // Composition root created in the corresponding test and reused by
  // the facade ones.
  property var _content: null

  property Timer _timeout: Timer {
    interval: 8000
    onTriggered: sc._done(false, "timeout (" + _timeout.interval + "ms)")
  }

  function add(name, fn) { checks.push({ name: name, fn: fn }) }

  function _run() {
    idx++
    if (idx >= checks.length) { _report(); return }
    _settled = false
    _startedAt = Date.now()
    _timeout.restart()
    try {
      checks[idx].fn(function (pass, msg) { sc._done(pass, msg) })
    } catch (e) {
      _done(false, "exception: " + e)
    }
  }

  function _done(pass, msg) {
    if (_settled) return
    _settled = true
    _timeout.stop()
    var ms = Date.now() - _startedAt
    if (pass) passes++; else fails++
    SelfCheckOut.line((pass ? "[PASS] " : "[FAIL] ") + checks[idx].name
      + " (" + ms + "ms)" + (msg ? " — " + msg : ""))
    Qt.callLater(_run)
  }

  function _report() {
    SelfCheckOut.line("")
    SelfCheckOut.line("── selfcheck: " + passes + " passed, " + fails
      + " failed, " + checks.length + " total ──")
    Qt.exit(fails > 0 ? 1 : 0)
  }

  // Lists a directory once and returns its entries via callback.
  function _listOnce(path, cb) {
    var m = _dmFactory.createObject(sc)
    var fired = false
    function h() {
      if (fired) return
      fired = true
      m.listed.disconnect(h)
      var e = m.entries
      cb(e)
      Qt.callLater(function () { m.destroy() })
    }
    m.listed.connect(h)
    m.list(path, true)
  }

  function _has(entries, name) {
    for (var i = 0; i < entries.length; i++)
      if (entries[i].name === name) return true
    return false
  }

  // Runs a list of FileOperations operations IN SEQUENCE (each
  // `start` launches an op; its finished is awaited before the next). If
  // any fails -> done(false, ...). When all finish -> onAllDone(). For
  // multi-step tests (trash/restore) without nesting ten _fileOp.
  function _seqOps(starts, done, onAllDone) {
    var i = 0
    function step() {
      if (i >= starts.length) { onAllDone(); return }
      var start = starts[i++]
      _fileOp(done, function () { step() })
      start()
    }
    step()
  }

  // Runs a FileOperations operation and calls then(path) on its first
  // finished signal, or done(false, ...) on error. Since the runner is
  // sequential, there is only one operation in flight.
  function _fileOp(done, then) {
    function ok(op, path) { cleanup(); then(op, path) }
    function bad(op, path, msg) { cleanup(); done(false, op + " error: " + msg) }
    function cleanup() {
      Backend.FileOperations.finished.disconnect(ok)
      Backend.FileOperations.error.disconnect(bad)
    }
    Backend.FileOperations.finished.connect(ok)
    Backend.FileOperations.error.connect(bad)
  }

  property Timer _pollTimer: Timer { interval: 16; repeat: true }

  // Polls cond() every 16 ms (wall-clock, not event loop passes) until it
  // is true or the budget runs out (~4 s, comfortable under the 8 s per-test
  // timeout). To wait for an async effect that doesn't expose a public signal
  // to hook onto (e.g. the re-listing of a background panel, whose
  // DirLister is internal and delivers via invokeMethod from a pool thread).
  // The real interval gives clock time to the worker, avoiding the race of a
  // Qt.callLater loop that spins faster than the thread can
  // respond. The runner is sequential: there is only one _poll in flight.
  function _poll(cond, cb) {
    if (cond()) { cb(true); return }
    var n = 0
    function tick() {
      if (cond()) { done(); cb(true) }
      else if (++n > 250) { done(); cb(false) }
    }
    function done() { _pollTimer.stop(); _pollTimer.triggered.disconnect(tick) }
    _pollTimer.triggered.connect(tick)
    _pollTimer.restart()
  }

  // ---- BUG-02: process runner for the .sh script smoke tests ----
  // Backend.ProcessRunner (real QProcess) delivers {exitCode,stdout,stderr}.
  property Component _procFactory: Component { Backend.ProcessRunner {} }
  // Resource root (where the .sh live), derived from this file's URL:
  readonly property string resourceRoot: Qt.resolvedUrl("../../").toString().replace(/^file:\/\//, "").replace(/\/+$/, "")

  // POSIX quoting to embed paths in a setup `bash -c`.
  function _q(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }
  // Runs argv and delivers the result via callback. Sequential runner: there is only
  // one _sh in flight (like the rest of the harness).
  function _sh(argv, cb) {
    var p = _procFactory.createObject(sc)
    function on(result) {
      p.finished.disconnect(on)
      cb(result)
      Qt.callLater(function () { p.destroy() })
    }
    p.finished.connect(on)
    p.start(argv, false)
  }


  property SelfCheckRegistry selfCheckRegistry: SelfCheckRegistry {}


  Component.onCompleted: {
    selfCheckRegistry.registerAll(sc)
    SelfCheckOut.line("── omafiles --selfcheck · fixtures in " + dir + " ──")
    _run()
  }
}

import QtQuick
import Omafiles.Backend as Backend
import "../../../state"

// Custom keybindings (P2.5, 2026-08-17): state/KeyboardDefaults.qml +
// logic/KeybindingResolver.qml + logic/KeyboardShortcuts.qml's
// resolver-driven dispatch. See docs/audits/P2_5_CUSTOM_KEYBINDINGS_AUDIT.md
// and its IMPLEMENTATION_REPORT.
//
// These tests write to the REAL ~/.config/omafiles/keybindings.toml (same
// contract as actions.toml -- there's no test-only override for Paths.qml),
// so the very first check backs up any pre-existing file and the very last
// one restores it -- every other test that writes a config also removes it
// and reload()s again before finishing, so each test starts from a clean
// slate regardless of what ran before it.
//
// Note: a config with a conflicting/unknown/invalid entry makes the real
// KeybindingResolver call Backend.Notifier.notify() (a real notify-send
// desktop popup) exactly like it would for an actual user -- the
// conflict/invalid/unknown-action cases are deliberately combined into one
// config file below so that happens once, not three times.
QtObject {
  function register(sc) {
    var kbPath = Paths.keybindingsFile
    var kbBackupPath = kbPath + ".selfcheck-backup"
    var hadPreexisting = false

    function writeKb(text, cb) {
      var cmd = "mkdir -p -- " + sc._q(Paths.configDir)
        + " && cat > " + sc._q(kbPath) + " <<'SELFCHECK_KB_EOF'\n" + text + "\nSELFCHECK_KB_EOF"
      sc._sh(["bash", "-c", cmd], cb)
    }
    function removeKb(cb) {
      sc._sh(["bash", "-c", "rm -f -- " + sc._q(kbPath)], cb)
    }
    function resolver() { return sc._content.controllers.keybindingResolver }
    function reload() { resolver().reload() }

    // Independent (not reusing KeybindingResolver's own _namedKeys) so this
    // actually exercises the resolver's canonicalization instead of just
    // agreeing with itself.
    var NAMED_KEYS = {
      "return": Qt.Key_Return, "backspace": Qt.Key_Backspace, "space": Qt.Key_Space,
      "/": Qt.Key_Slash, ":": Qt.Key_Colon, "?": Qt.Key_Question, "\\": Qt.Key_Backslash,
      // Must be named here rather than falling through to qtKeyFor()'s
      // single-character arithmetic (Qt.Key_A + charCode - 'a'), which for
      // "." yields Qt.Key_A - 51 -- a nonsense code that resolves to null.
      ".": Qt.Key_Period,
      "down": Qt.Key_Down, "up": Qt.Key_Up, "left": Qt.Key_Left, "right": Qt.Key_Right,
      "f2": Qt.Key_F2, "f5": Qt.Key_F5, "delete": Qt.Key_Delete, "tab": Qt.Key_Tab
    }
    function qtKeyFor(name) {
      if (NAMED_KEYS[name] !== undefined) return NAMED_KEYS[name]
      if (name.length === 1) return Qt.Key_A + (name.charCodeAt(0) - "a".charCodeAt(0))
      return null
    }
    function qtModFor(mod) {
      if (mod === "any" || mod === "none") return Qt.NoModifier
      var m = Qt.NoModifier
      if (mod.indexOf("ctrl") >= 0) m |= Qt.ControlModifier
      if (mod.indexOf("shift") >= 0) m |= Qt.ShiftModifier
      if (mod.indexOf("alt") >= 0) m |= Qt.AltModifier
      return m
    }
    function ev(keyName, mod) {
      return { key: qtKeyFor(keyName), modifiers: qtModFor(mod || "none"), accepted: false }
    }

    // ---------- 0. Preflight: don't clobber a real user config ----------
    sc.add("Keybindings: preflight backs up any real keybindings.toml", function (done) {
      sc._sh(["bash", "-c",
        "if [ -f " + sc._q(kbPath) + " ]; then mv -- " + sc._q(kbPath) + " " + sc._q(kbBackupPath) + " && echo BACKED_UP; else echo NONE; fi"
      ], function (r) {
        hadPreexisting = String(r.stdout || "").trim() === "BACKED_UP"
        reload()
        done(r.exitCode === 0, hadPreexisting
          ? "an existing keybindings.toml was backed up for the duration of these tests"
          : "no pre-existing keybindings.toml (nothing to back up)")
      })
    })

    // ---------- 1. Defaults exactly preserved with no config file ----------
    sc.add("Keybindings: no config file -> every default key resolves to its original action", function (done) {
      var r = resolver()
      if (JSON.stringify(KeyboardDefaults.overrides) !== "{}") { done(false, "overrides not empty: " + JSON.stringify(KeyboardDefaults.overrides)); return }
      var bad = []
      for (var i = 0; i < KeyboardDefaults.actions.length; i++) {
        var a = KeyboardDefaults.actions[i]
        for (var k = 0; k < a.keys.length; k++) {
          var spec = a.keys[k]
          var got = r.actionFor(ev(spec.key, spec.mod))
          if (got !== a.id) bad.push(a.id + " key#" + k + " (" + spec.mod + "+" + spec.key + ") -> " + got)
        }
      }
      done(bad.length === 0, bad.length === 0 ? "all " + KeyboardDefaults.actions.length + " actions' default keys resolve correctly" : bad.join("; "))
    })

    // ---------- 2. Custom navigation, all 4 directions, arbitrary keys (Colemak-style) ----------
    // This app is a single-column list (no left/right cursor movement), so
    // the closest real equivalent of "4 directional keys" is move_down/
    // move_up (vertical cursor) plus go_up/open (the h/l "back a level" /
    // "into a level" pair) -- all four are real, independently rebindable
    // actions. Picks keys that don't collide with any OTHER default.
    sc.add("Keybindings: custom navigation (all 4 directions) via config file, zero code changes", function (done) {
      writeKb('[keybindings]\nmove_down = "n"\nmove_up = "e"\ngo_up = "m"\nopen = "i"\n', function (w) {
        if (w.exitCode !== 0) { done(false, "couldn't write config: " + w.stderr); return }
        reload()
        var r = resolver()
        var checks = [
          ["n", "none", "move_down"], ["e", "none", "move_up"], ["m", "none", "go_up"], ["i", "none", "open"],
          // full-replacement policy: the OLD default keys must stop working once overridden
          ["j", "none", null], ["down", "any", null], ["k", "none", null], ["up", "any", null],
          ["h", "none", null], ["backspace", "any", null], ["l", "none", null], ["return", "shift", "open_terminal"]
        ]
        var bad = []
        for (var i = 0; i < checks.length; i++) {
          var got = r.actionFor(ev(checks[i][0], checks[i][1]))
          if (got !== checks[i][2]) bad.push(checks[i][0] + "/" + checks[i][1] + " -> " + got + " (expected " + checks[i][2] + ")")
        }
        removeKb(function (rm) {
          reload()
          done(bad.length === 0 && rm.exitCode === 0, bad.length === 0
            ? "n/e/m/i drive move_down/move_up/go_up/open; old j/k/h/l and Down/Up/Backspace no longer do (Return still opens the terminal, untouched)"
            : bad.join("; "))
        })
      })
    })

    // ---------- 3. Fixed shortcuts reject rebinding ----------
    sc.add("Keybindings: fixed action (undo/Ctrl+Z) rejects a config override", function (done) {
      writeKb('[keybindings]\nundo = "u"\n', function (w) {
        if (w.exitCode !== 0) { done(false, "couldn't write config: " + w.stderr); return }
        reload()
        var r = resolver()
        var rejected = KeyboardDefaults.overrides.undo === undefined
        var ctrlZStillUndo = r.actionFor(ev("z", "ctrl")) === "undo"
        var bareUNotUndo = r.actionFor(ev("u", "none")) !== "undo"
        removeKb(function (rm) {
          reload()
          var ok = rejected && ctrlZStillUndo && bareUNotUndo && rm.exitCode === 0
          done(ok, ok ? "fixed action ignored the override, Ctrl+Z still undoes" : "fixed action was rebound (should be impossible)")
        })
      })
    })

    // ---------- 3b. Punctuation keys survive the round trip ----------
    // "." used to be unnameable: it is not in KeybindingResolver's _namedKeys,
    // _canonicalKeyName() rejected it, and _eventKeyName() returned null for
    // Qt.Key_Period. A user binding it in keybindings.toml got no warning and
    // no working key -- the entry parsed to null and was dropped as invalid,
    // which is indistinguishable from a typo. "/" is included as the control:
    // it always worked, and must keep working.
    sc.add("Keybindings: a punctuation key (\".\") can be bound from config", function (done) {
      writeKb('[keybindings]\ntoggle_hidden = "."\n', function (w) {
        if (w.exitCode !== 0) { done(false, "couldn't write config: " + w.stderr); return }
        reload()
        var r = resolver()
        var accepted = KeyboardDefaults.overrides.toggle_hidden !== undefined
        var dotWorks = r.actionFor(ev(".", "none")) === "toggle_hidden"
        var oldCtrlHDead = r.actionFor(ev("h", "ctrl")) === null
        var slashStillSearch = r.actionFor(ev("/", "any")) === "search"
        removeKb(function (rm) {
          reload()
          var ok = accepted && dotWorks && oldCtrlHDead && slashStillSearch && rm.exitCode === 0
          done(ok, ok
            ? "\".\" resolved to toggle_hidden, its old Ctrl+H went dead, and \"/\" still searches"
            : "override accepted=" + accepted + " \".\"->toggle_hidden=" + dotWorks
              + " old Ctrl+H dead=" + oldCtrlHDead + " \"/\"->search=" + slashStillSearch)
        })
      })
    })

    // ---------- 4. Conflicting / unknown / invalid entries in one config ----------
    sc.add("Keybindings: conflicting, unknown, and invalid entries fall back to defaults (one warning)", function (done) {
      // search="s" collides with cycle_sort's default bare "s"; totally_made_up_action
      // doesn't exist; move_up gets a key spec that isn't parseable.
      var cfg = '[keybindings]\n'
        + 'search = "s"\n'
        + 'totally_made_up_action = "x"\n'
        + 'move_up = "???not-a-key???"\n'
      writeKb(cfg, function (w) {
        if (w.exitCode !== 0) { done(false, "couldn't write config: " + w.stderr); return }
        var reloadError = null
        try { reload() } catch (e) { reloadError = String(e) }
        var r = resolver()
        var searchRejected = KeyboardDefaults.overrides.search === undefined
        var cycleSortStillS = r.actionFor(ev("s", "none")) === "cycle_sort"
        var searchStillSlash = r.actionFor(ev("/", "none")) === "search"
        var moveUpRejected = KeyboardDefaults.overrides.move_up === undefined
        var moveUpStillUp = r.actionFor(ev("up", "any")) === "move_up"
        removeKb(function (rm) {
          reload()
          var ok = !reloadError && searchRejected && cycleSortStillS && searchStillSlash
            && moveUpRejected && moveUpStillUp && rm.exitCode === 0
          done(ok, ok
            ? "collision kept cycle_sort's default and rejected search's override; unknown action ignored; unparseable key spec ignored; no crash"
            : (reloadError ? "reload() threw: " + reloadError : "one of the fallbacks didn't hold"))
        })
      })
    })

    // ---------- 5. Non-nav action + modifier-combo rebind reach the real handler ----------
    sc.add("Keybindings: rebound action + modifier-combo rebind reach the real handler (full chain)", function (done) {
      writeKb('[keybindings]\nrename = "r"\nrefresh = "ctrl+shift+r"\n', function (w) {
        if (w.exitCode !== 0) { done(false, "couldn't write config: " + w.stderr); return }
        var isolatedResolverComp = Qt.createComponent("../../../logic/KeybindingResolver.qml")
        var kbdComp = Qt.createComponent("../../../logic/KeyboardShortcuts.qml")
        if (isolatedResolverComp.status !== Component.Ready || kbdComp.status !== Component.Ready) {
          removeKb(function () { reload() })
          done(false, "component(s) not ready")
          return
        }
        var isolatedResolver = isolatedResolverComp.createObject(sc) // its Component.onCompleted reload()s from the file just written
        var called = {}
        var stubEngine = { startRename: function () { called.rename = true } }
        var stubNav = { refresh: function () { called.refresh = true } }
        var kbd = kbdComp.createObject(sc, {
          "hostControllers": { "actionEngine": stubEngine, "navController": stubNav, "keybindingResolver": isolatedResolver },
          "hostRoot": {}
        })
        kbd.handlePress(ev("r", "none"))
        kbd.handlePress(ev("f2", "any")) // old default: must NOT also fire rename (full replacement)
        kbd.handlePress(ev("r", "ctrl+shift")) // real handler: refresh, bound to Ctrl+Shift+R
        kbd.destroy()
        isolatedResolver.destroy()
        removeKb(function (rm) {
          reload()
          var ok = called.rename === true && called.refresh === true && rm.exitCode === 0
          done(ok, ok ? "custom \"r\" renamed, Ctrl+Shift+R refreshed, old F2 alone did not also rename" : "expected calls: " + JSON.stringify(called))
        })
      })
    })

    // ---------- 6. Text input is not stolen while editing/renaming ----------
    sc.add("Keybindings: a rename/edit field in progress blocks list shortcuts (text input isn't stolen)", function (done) {
      // mainLayout itself isn't aliased on the composition root, but
      // core/DialogLayer.qml holds the same ActiveFileList instance via its
      // own `list` property (list: mainLayout.list in OmafilesContent.qml),
      // and dialogLayer IS aliased -- so this reaches the real per-pane
      // KeyboardShortcuts instance without adding a new alias.
      var c = sc._content
      if (!c || !c.dialogLayer || !c.dialogLayer.list || !c.dialogLayer.list.keyboardShortcuts) { done(false, "no real tree"); return }
      var before = SelectionState.selectedIndex
      var savedRenaming = EditModeState.renamingIndex
      EditModeState.renamingIndex = 0 // simulate an active rename field
      try {
        c.dialogLayer.list.keyboardShortcuts.handlePress(ev("j", "none")) // default move_down key
      } finally {
        EditModeState.renamingIndex = savedRenaming
      }
      var unchanged = SelectionState.selectedIndex === before
      done(unchanged, unchanged
        ? "move_down's key did nothing to the list while a rename field was active (early-return context gate held)"
        : "selection moved (" + before + " -> " + SelectionState.selectedIndex + ") while a rename field should have owned the keystroke")
    })

    // ---------- 7. Help overlay reflects effective (overridden) bindings ----------
    sc.add("Keybindings: help overlay data (effectiveBindingsList) reflects an active override", function (done) {
      writeKb('[keybindings]\nrename = "r"\n', function (w) {
        if (w.exitCode !== 0) { done(false, "couldn't write config: " + w.stderr); return }
        reload()
        var list = resolver().effectiveBindingsList()
        var row = list.filter(function (x) { return x.action === "Rename" })[0]
        // Bare (no-modifier) single-letter keys display lowercase, matching
        // the existing convention for defaults like "j"/"k"/"s" -- see
        // KeybindingResolver._specLabel().
        var ok = !!row && row.key === "r"
        removeKb(function (rm) {
          reload()
          done(ok && rm.exitCode === 0, ok
            ? "effectiveBindingsList() (the same data dialogs/ShortcutsHelp.qml binds to) shows Rename -> r"
            : "effectiveBindingsList() row for Rename was " + JSON.stringify(row))
        })
      })
    })

    // ---------- 8. Missing config after having had one -> defaults restored ----------
    sc.add("Keybindings: removing the config file restores defaults", function (done) {
      writeKb('[keybindings]\nrename = "r"\n', function (w1) {
        if (w1.exitCode !== 0) { done(false, "couldn't write config: " + w1.stderr); return }
        reload()
        var overriddenOk = resolver().actionFor(ev("r", "none")) === "rename"
        removeKb(function (rm) {
          reload()
          var r = resolver()
          var backToDefault = JSON.stringify(KeyboardDefaults.overrides) === "{}"
            && r.actionFor(ev("f2", "any")) === "rename"
            && r.actionFor(ev("r", "none")) === null
          done(overriddenOk && backToDefault && rm.exitCode === 0,
            (overriddenOk && backToDefault) ? "override applied, then removing the file put F2 back and freed \"r\"" : "defaults weren't fully restored")
        })
      })
    })

    // ---------- 9. Cleanup: restore whatever the user actually had ----------
    sc.add("Keybindings: cleanup restores the user's real config state", function (done) {
      var restoreCmd = hadPreexisting
        ? ("mv -f -- " + sc._q(kbBackupPath) + " " + sc._q(kbPath))
        : ("rm -f -- " + sc._q(kbPath))
      sc._sh(["bash", "-c", restoreCmd], function (r) {
        reload()
        done(r.exitCode === 0, hadPreexisting ? "restored the user's original keybindings.toml" : "left no test file behind (there was nothing to restore)")
      })
    })
  }
}

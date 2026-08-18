import QtQuick
import "../state"
import Omafiles.Backend as Backend

// Parses ~/.config/omafiles/keybindings.toml, validates it against
// state/KeyboardDefaults.qml, and resolves a real Keys.onPressed event to a
// semantic action id for logic/KeyboardShortcuts.qml -- P2.5, 2026-08-17
// (docs/audits/P2_5_CUSTOM_KEYBINDINGS_AUDIT.md).
//
// This is the "business logic" half of the split the audit's §14 asked
// for: state/KeyboardDefaults.qml stays a pure property bag (the actions
// list + the resolved overrides map); this file is the one place that
// reads a file, parses it, and makes validation decisions -- orchestration,
// which belongs in logic/ per this project's own architecture rules, not
// in state/.
//
// Registry-owned like every other logic/ controller (core/ControllerRegistry.qml
// instantiates it once); logic/KeyboardShortcuts.qml reaches it via
// hostControllers.keybindingResolver, exactly like it already reaches
// hostControllers.actionEngine/navController/etc. core/DialogLayer.qml reaches
// it via controllers.keybindingResolver to build the "?" help overlay's
// effective-bindings list -- no new cross-layer import edge needed in
// either direction, since both already receive `controllers: registry`.
//
// File format: a single [keybindings] table, flat `action_id = "Key"` pairs
// -- deliberately simpler than actions.toml's [[array-of-tables]] shape,
// since there's no repetition here, just one value per action:
//
//   [keybindings]
//   move_down = "n"
//   move_up   = "e"
//   rename    = "Ctrl+Shift+R"
//
// Same minimal-parser philosophy as logic/CustomActions.qml: no general
// TOML library, comments (#) and blank lines skipped, strict for the one
// schema supported. Missing file -> empty overrides -> every action keeps
// its state/KeyboardDefaults.qml default, unchanged (the audit's §9
// compatibility guarantee). Reload happens on the next relevant use (the
// "?" help overlay opening, mirroring CustomActions.reload()'s "palette/
// menu opening" trigger), not via a file watcher -- see the audit's §12.
Item {
  id: resolver

  Component.onCompleted: reload()

  // Re-reads and re-validates the file. Cheap (tiny file, synchronous
  // read), safe to call as often as convenient.
  function reload() {
    var text = _readFile(Paths.keybindingsFile)
    var raw = _parse(text)          // { actionId: "key spec string" }, no validation yet
    KeyboardDefaults.overrides = _validate(raw)
  }

  // Synchronous file:// read, identical pattern to CustomActions._readFile
  // and qs.Commons/ThemeSource -- "" if the file doesn't exist (no error,
  // no notification: the file is entirely optional).
  function _readFile(path) {
    try {
      var xhr = new XMLHttpRequest()
      xhr.open("GET", "file://" + path, false)
      xhr.send()
      return (xhr.status === 0 || xhr.status === 200) ? String(xhr.responseText || "") : ""
    } catch (e) {
      return ""
    }
  }

  // Minimal parser: one [keybindings] table, flat string key=value pairs.
  // Ignores comments/blank lines and anything before the [keybindings]
  // header (or a different header -- e.g. a stray [action] block from
  // actions.toml pasted into the wrong file by mistake is silently not
  // a [keybindings] entry, not a crash).
  function _parse(text) {
    var out = {}
    var inSection = false
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line === "" || line.charAt(0) === "#")
        continue
      if (line.charAt(0) === "[") {
        inSection = (line === "[keybindings]")
        continue
      }
      if (!inSection)
        continue
      var eq = line.indexOf("=")
      if (eq < 0)
        continue
      var key = line.substring(0, eq).trim()
      var val = _unquote(line.substring(eq + 1).trim())
      if (key && val)
        out[key] = val
    }
    return out
  }

  function _unquote(raw) {
    if (raw.length >= 2) {
      var q = raw.charAt(0)
      if (q === '"' || q === "'") {
        var end = raw.indexOf(q, 1)
        if (end > 0) return raw.substring(1, end)
      }
    }
    var hash = raw.indexOf("#")
    return (hash >= 0 ? raw.substring(0, hash) : raw).trim()
  }

  // ---------- Validation: raw {actionId: "key spec"} -> safe overrides ----------
  //
  // Policy (audit §8, "fail loudly at load time, never silently pick a
  // winner"): every rejection is reported through Backend.Notifier (the
  // same mechanism CustomActions.qml already uses for its own runtime
  // errors) and the affected action simply keeps its default -- never a
  // partial/ambiguous state, never a crash, never silently dropped with no
  // trace.
  function _validate(raw) {
    var byAction = {}          // actionId -> {key,mod} spec that survives validation so far
    var keyToAction = {}       // "canonical spec string" -> actionId, to catch collisions
    var warnings = []

    // Seed keyToAction with every DEFAULT key of every action that is NOT
    // being overridden -- so a user's new key can be checked against
    // "does this silently collide with some OTHER action I didn't even
    // mean to touch" (audit §8).
    var actionsById = {}
    for (var ai = 0; ai < KeyboardDefaults.actions.length; ai++) {
      var a = KeyboardDefaults.actions[ai]
      actionsById[a.id] = a
      if (raw[a.id] === undefined) {
        for (var ki = 0; ki < a.keys.length; ki++) {
          keyToAction[_specString(a.keys[ki])] = a.id
        }
      }
    }

    for (var actionId in raw) {
      if (!raw.hasOwnProperty(actionId)) continue
      var def = actionsById[actionId]
      if (!def) {
        warnings.push("keybindings.toml: unknown action \"" + actionId + "\" -- ignored")
        continue
      }
      if (def.fixed) {
        warnings.push("keybindings.toml: \"" + actionId + "\" (" + raw[actionId] + ") is reserved and cannot be rebound -- kept at its default")
        continue
      }
      var spec = _parseKeySpec(raw[actionId])
      if (!spec) {
        warnings.push("keybindings.toml: couldn't understand key \"" + raw[actionId] + "\" for \"" + actionId + "\" -- kept at its default")
        continue
      }
      var specStr = _specString(spec)
      if (keyToAction[specStr] !== undefined && keyToAction[specStr] !== actionId) {
        warnings.push("keybindings.toml: \"" + raw[actionId] + "\" is already used by \"" + keyToAction[specStr] + "\" -- \"" + actionId + "\" kept at its default")
        continue
      }
      byAction[actionId] = spec
      keyToAction[specStr] = actionId
    }

    if (warnings.length > 0)
      Backend.Notifier.notify(warnings.join("\n"))

    return byAction
  }

  // Canonical string for a {key,mod} spec, used only to detect equality
  // between two specs (not shown to the user) -- "mod" is included so
  // "n" and "Ctrl+n" are correctly treated as different keys.
  function _specString(spec) { return spec.mod + "|" + spec.key.toLowerCase() }

  // ---------- Key-name <-> Qt.Key_* -----------------------------------
  readonly property var _namedKeys: ({
    "return": Qt.Key_Return,
    "escape": Qt.Key_Escape,
    "space": Qt.Key_Space,
    "slash": Qt.Key_Slash, "/": Qt.Key_Slash,
    "colon": Qt.Key_Colon, ":": Qt.Key_Colon,
    "question": Qt.Key_Question, "?": Qt.Key_Question,
    "backspace": Qt.Key_Backspace,
    "delete": Qt.Key_Delete,
    "down": Qt.Key_Down, "up": Qt.Key_Up, "left": Qt.Key_Left, "right": Qt.Key_Right,
    "tab": Qt.Key_Tab,
    "backtab": Qt.Key_Backtab,
    "backslash": Qt.Key_Backslash, "\\": Qt.Key_Backslash,
    "period": Qt.Key_Period, ".": Qt.Key_Period,
    "f2": Qt.Key_F2, "f5": Qt.Key_F5
  })

  // Parses a user-facing key string ("Ctrl+Shift+N", "n", "F2", "/") into
  // {key: "<canonical lowercase name>", mod: "any"|"none"|"ctrl"|"shift"|
  // "alt"|"ctrl+shift"}. Returns null if the trailing key token isn't
  // recognized. A bare letter/symbol with no modifier prefix means
  // "none" (exact no-modifier), matching how the defaults themselves
  // encode plain letter keys (see state/KeyboardDefaults.qml's header).
  function _parseKeySpec(str) {
    var parts = String(str || "").split("+").map(function (p) { return p.trim() }).filter(function (p) { return p.length > 0 })
    if (parts.length === 0) return null
    var keyToken = parts[parts.length - 1]
    var modTokens = parts.slice(0, -1).map(function (m) { return m.toLowerCase() })
    var canonicalKey = _canonicalKeyName(keyToken)
    if (canonicalKey === null) return null
    var mods = []
    if (modTokens.indexOf("ctrl") >= 0 || modTokens.indexOf("control") >= 0) mods.push("ctrl")
    if (modTokens.indexOf("shift") >= 0) mods.push("shift")
    if (modTokens.indexOf("alt") >= 0) mods.push("alt")
    var mod = mods.length > 0 ? mods.join("+") : "none"
    return { key: canonicalKey, mod: mod }
  }

  // A single token ("N", "F2", "Return", "/") -> canonical lowercase name,
  // or null if not recognized. Single letters are accepted case-insensitively.
  function _canonicalKeyName(token) {
    if (token.length === 1 && /[a-zA-Z]/.test(token)) return token.toLowerCase()
    if (token === "/" || token === ":" || token === "?" || token === "\\" || token === ".") return token
    var lower = token.toLowerCase()
    if (lower === "enter") return "return"   // both spellings mean the same physical Return/Enter key -- see _eventKeyName
    if (_namedKeys[lower] !== undefined) return lower
    return null
  }

  // Same canonicalization for a real Keys.onPressed event's Qt.Key_* code
  // -- must produce identical strings to _canonicalKeyName() for the same
  // physical key, since actionFor() compares them directly.
  function _eventKeyName(qtKey) {
    if (qtKey >= Qt.Key_A && qtKey <= Qt.Key_Z) return String.fromCharCode(97 + (qtKey - Qt.Key_A))
    // Qt.Key_Return (main keyboard) and Qt.Key_Enter (numpad) are TWO
    // DISTINCT integer codes -- both must resolve to the same "return"
    // canonical name (matching the original code's `event.key ===
    // Qt.Key_Return || event.key === Qt.Key_Enter`), which is why this is
    // a direct special case rather than a _namedKeys table lookup: that
    // table can only map one Qt.Key_* value per name.
    if (qtKey === Qt.Key_Return || qtKey === Qt.Key_Enter) return "return"
    for (var name in _namedKeys) {
      if (_namedKeys.hasOwnProperty(name) && _namedKeys[name] === qtKey) {
        // Prefer the symbol form for punctuation so it matches what
        // _canonicalKeyName() returns for "/", ":", "?", "\\" (both the
        // word and the symbol map to the same Qt.Key_*, but only ONE
        // string must come out of this function).
        if (name === "slash") return "/"
        if (name === "colon") return ":"
        if (name === "question") return "?"
        if (name === "backslash") return "\\"
        if (name === "period") return "."
        return name
      }
    }
    return null
  }

  // Does {key,mod} spec match this real event? Faithfully replicates the
  // three modifier-matching modes documented in state/KeyboardDefaults.qml
  // (any/none/at-least-these), NOT simple string equality against
  // _modeString() -- "ctrl" must still match Ctrl+Shift held together,
  // exactly like the original `event.modifiers & Qt.ControlModifier`.
  function _specMatchesEvent(spec, eventKeyName, event) {
    if (spec.key !== eventKeyName) return false
    if (spec.mod === "any") return true
    if (spec.mod === "none") return event.modifiers === Qt.NoModifier
    var required = spec.mod.split("+")
    for (var i = 0; i < required.length; i++) {
      var flag = required[i] === "ctrl" ? Qt.ControlModifier : required[i] === "shift" ? Qt.ShiftModifier : Qt.AltModifier
      if ((event.modifiers & flag) === 0) return false
    }
    return true
  }

  // The one function logic/KeyboardShortcuts.qml calls. Returns the
  // matched action id, or null if this event isn't bound to anything (the
  // caller falls through to its own structural handling -- Escape, the
  // "gg" chord, and every context-gate check stay outside this resolver
  // entirely, see the audit's §6/§7).
  function actionFor(event) {
    var eventKeyName = _eventKeyName(event.key)
    if (eventKeyName === null) return null
    var overrides = KeyboardDefaults.overrides
    for (var i = 0; i < KeyboardDefaults.actions.length; i++) {
      var a = KeyboardDefaults.actions[i]
      var override = overrides[a.id]
      if (override) {
        if (_specMatchesEvent(override, eventKeyName, event)) return a.id
        continue // overridden actions ONLY answer to their new key, not their old default(s)
      }
      for (var k = 0; k < a.keys.length; k++) {
        if (_specMatchesEvent(a.keys[k], eventKeyName, event)) return a.id
      }
    }
    return null
  }

  // For dialogs/ShortcutsHelp.qml (via core/DialogLayer.qml): the
  // EFFECTIVE key label for each action (override if set, else the
  // default's own display form), in state/KeyboardDefaults.qml's order.
  function effectiveBindingsList() {
    var out = []
    var overrides = KeyboardDefaults.overrides
    for (var i = 0; i < KeyboardDefaults.actions.length; i++) {
      var a = KeyboardDefaults.actions[i]
      var override = overrides[a.id]
      var keyLabel = override ? _specLabel(override) : a.keys.map(_specLabel).join(" / ")
      out.push({ key: keyLabel, action: a.label })
    }
    return out
  }

  function _specLabel(spec) {
    // Matches the README/help overlay's existing convention: a bare letter
    // (no modifier shown, e.g. "j") stays lowercase, but a letter shown
    // after a modifier prefix is uppercased ("Ctrl+A", not "Ctrl+a") --
    // symbols ("/", ":") are untouched either way. Named multi-char keys
    // get title-cased ("return" -> "Return", "backspace" -> "Backspace").
    var bareLetter = spec.key.length === 1 && (spec.mod === "any" || spec.mod === "none")
    var keyPart = spec.key.length > 1
      ? spec.key.charAt(0).toUpperCase() + spec.key.slice(1)
      : (bareLetter ? spec.key : spec.key.toUpperCase())
    if (spec.mod === "any" || spec.mod === "none") return keyPart
    var mods = spec.mod.split("+").map(function (m) { return m.charAt(0).toUpperCase() + m.slice(1) })
    return mods.join("+") + "+" + keyPart
  }
}

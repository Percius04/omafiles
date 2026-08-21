# Omafiles

A keyboard-first **multi-panel** file manager for [Omarchy](https://omarchy.org), built as a **Qt6 standalone application** (`v1.1.0`). It is not a wrapper around Nautilus/Dolphin/Thunar, and not a layer-shell popup either — it's a real, tileable window that opens and behaves like any other app on your desktop, using Omarchy's own design system (`qs.Commons`/`qs.Ui`) end to end: same typography, same borders, same hover/selection chrome, same Nerd Font icons as the rest of the shell.

![Omafiles screenshot](preview.png)

## Why

Omarchy is opinionated by design — one good default per decision instead of a wall of settings. Omafiles follows the same spirit (and the DHH / 37signals bias toward sharp, un-configurable defaults): no view-mode dropdowns, no icon-size sliders, no settings panel. Sorting is a key that cycles (`s`/`S`), not a combo box. Everything has a keyboard path first; the mouse works too, but it's not the point.

Two ideas shape the whole app:

- **Keyboard first.** Vim-style motion (`j`/`k`, `gg`/`G`, `h`/`l`), a command palette for every action, and a native path bar with completion mean you rarely reach for the mouse.
- **A multi-panel workspace.** Omafiles is not a dual-pane manager with two fixed sides. You open as many **persistent panels** as you want, side by side. Each panel keeps its **own path, scroll position, selection, preview, and back/forward history**, independently. Background panels stay fully alive — switching between them is instant and lossless, so you can keep several working contexts open at once and glance between them like windows in a tiling WM.

Under the hood it's a thin QML front-end over a shared **C++ backend** (`Omafiles.Backend`) that does the heavy lifting natively — directory listing, file operations, search, thumbnails, previews, mount watching — with no shell-out where a native call will do.

## Features

### Navigation

- Vim-style keyboard navigation (`j`/`k`, `gg`/`G`, `h`/`l`) plus arrow keys; `Enter`/`l` opens, `h`/`Backspace` goes up.
- Back/forward navigation history (`Alt+←`/`Alt+→`), tracked **per panel**.
- Breadcrumb path bar; click any segment to jump there, or click the empty area to edit the path by hand.
- Natural-order aware throughout: `file2.txt` sorts before `file10.txt`.

### Multiple persistent panels

- Open as many panels as you like, shown side by side and separated by a hairline divider — not a one-at-a-time switcher.
- Every panel is a live, independent workspace: its **path, scroll, selection, preview, and history are preserved** and never reset when you switch away.
- Background panels stay rendered and up to date; the active panel is simply whichever one has the mouse over it — that's where keyboard shortcuts, selection, and the context menu apply.
- Switching is instant and pixel-exact: a panel comes back exactly where you left it, down to the scroll offset.
- New panels: `Ctrl+T` or `Ctrl+\`. Close the active panel: `Ctrl+W` (or `Escape` when nothing else is open). Cycle: `Ctrl+Tab`.

### Global indexed search

- Search files across the whole system by name (`/` or `Ctrl+F`), backed by the system index — Tracker (`tracker3`) → `plocate`/`locate`, falling back to a native recursive walk from the current folder when no index is installed.
- Results are ranked by relevance (exact → prefix → substring → path-only), and opening one **reveals** it: a folder is entered, a file jumps to its folder with it selected — like Spotlight, not a blind launch.
- Search is **per panel**: it stays open in the panel where you started it and doesn't leak into the others.

### Content search (`content:`)

- Search *inside* files, not just by name — type `content:` followed by your text in the search bar (e.g. `content:TODO`, `content:"struct Foo"`).
- Powered by a native multithreaded C++ search worker (`SearchWorker`), streaming results asynchronously with zero shell-out overhead, binary file auto-detection, line matching, and snippet extraction.
- Each hit shows the file icon, name, parent folder, and the matched **line number + snippet**; opening a result reveals the file with it selected.

### Preview (Quick Look with `Space`)

- Press `Space` to toggle a quick preview of the selected item — the same "peek without opening" flow you'd expect from Quick Look.
- Handles images, inline video/audio **playback** (Qt Multimedia, play/pause, auto-stops when you move to another item) with a video thumbnail fallback, native C++ syntax highlighting (C++, Python, QML, JSON, Shell), first-page PDF rendering (`QQuickPdfDocument`/`pdftoppm`), and native C++ audio/video metadata extraction (`MediaInfo`: duration, bitrate, sample rate, channels, codec).
- Preview state is tracked per panel.

### File operations

- Rename, new folder, new file, make link, delete (to trash), copy / cut / paste, drag-and-drop, compress, extract, and bulk rename.
- Nothing silently clobbers an existing name: copy/cut/paste/drag show a real overwrite / skip / cancel dialog; extract/compress/bulk-rename show their own equivalent; rename asks to confirm an overwrite; new folder / new file / make link refuse with a clear error instead of failing quietly.
- Copy/move show a "still working" indicator with **Cancel** and a real percentage + progress bar (estimated from source size vs. bytes landed — `cp`/`mv` don't report progress themselves), and a cancel leaves no half-written file or tree behind. A second copy/move/compress/extract issued while one is already running is **queued**, not rejected — it's shown as a dimmed "Pending" row (with its own Cancel) above the active one, and starts automatically once its turn comes.
- Compress to `.zip`, `.tar.gz`, or `.7z`; extract `.zip`/`.7z`/`.rar`/the `.tar` family, including multi-volume archives — both directions show a live progress bar.
- Copy/cut sync with the system clipboard (`wl-copy`, `text/uri-list`): paste files copied in Omafiles into another app, or files copied elsewhere into Omafiles (`Ctrl+V` falls back to the system clipboard when nothing's copied inside the app). "Copy path" puts the plain-text path(s) on the clipboard instead.
- Rubber-band selection (drag over empty space; `Ctrl` adds to the selection), range selection with `Shift`+`↑`/`↓`, and drag-and-drop both out to and in from other apps.

### Undo / Redo

- `Ctrl+Z` undo, `Ctrl+Shift+Z` or `Ctrl+Y` redo, with a LIFO stack (up to 20 steps).
- Covers rename, new folder, new file, make link, delete, move, bulk rename, and chmod (chmod undo restores each item's own previous mode).

### Trash

- Aggregates **every** active trash location, not just the one under your home — anything deleted from another mounted drive gets its own trash there, and Omafiles shows them all together in one place.
- Each item shows its original location and deletion time (read from `.trashinfo`); restore puts it back where it came from.

### Reactive drives (UDisks2)

- A mounted-drives sidebar that reacts live to UDisks2 events — mount / eject, distinguishing internal disks from removable/USB by icon, no polling lag.

### ISO images

- Mount `.iso` files (open one, or "Mount ISO" from the context menu / palette) as a real loop-device mount — an installer or any file inside runs/copies exactly as it would from a real disc. It appears in the drives sidebar with its own icon and ejects like any removable drive.

### Network locations (GVfs)

- SFTP / SMB / WebDAV / FTP via GVfs — "Connect…" from the sidebar or command palette; active connections are listed and browsable like any local folder.
- Uses already-cached credentials when available (SSH key, saved keyring entry); otherwise an in-app "Authentication Required" prompt asks for the username/password, with a session-only "remember" option.
- Previously used server URIs are saved as one-click profiles (URI only — never a password) for reconnecting later.
- A reactive watcher picks up mounts/unmounts made from *other* apps (e.g. mounting a share in Nautilus) without polling — the same live behavior local drives already had via UDisks2.

### Archives

- Browse inside a zip / 7z / rar / tar-family archive without extracting it; opening a file inside extracts just that one file to a temp cache and opens it with your default app. Read-only view.

### Notifications

- Real desktop notifications (`org.freedesktop.Notifications` over D-Bus, not `notify-send`) for background events — action failures, finished operations, and the like.
- `Alt+N` opens a recent-notifications panel (session-only history, cleared on restart) in case you missed one.

### Default file manager (`org.freedesktop.FileManager1`)

- Registers itself as the system's default file manager on first launch — both for opening directories (`inode/directory` via `xdg-mime`) and for "Show in file manager" (the `org.freedesktop.FileManager1` D-Bus interface). See [System integration](#system-integration).

### Thumbnails

- Image and video thumbnails (video via `ffmpegthumbnailer`), cached on disk keyed by path + mtime.

### Bulk rename

- Rename a multi-selection with `{name}` / `{ext}` / `{n}` (or `{n:3}` to zero-pad) patterns, plus an optional regex Find/Replace applied to the name first; recent patterns are saved as one-click chips; a live preview shows every resulting name before confirming.

### Permissions (chmod)

- chmod on a multi-selection, with an "Apply to subfolders" toggle for `chmod -R`; handles huge selections natively without hitting `ARG_MAX`.

### Properties

- A read-only Properties panel: real folder size via `du`, permissions, owner, dates — or a combined item count + total size for a multi-selection.

### Custom keybindings (`keybindings.toml`)

- Remap any non-fixed shortcut to a different key — no code changes, useful for Colemak/Dvorak or just personal taste. See [Custom keybindings](#custom-keybindings).

### Custom actions (`actions.toml`)

- Your own commands, surfaced in both the command palette and the item context menu — the escape hatch for anything the manager doesn't ship (open in your editor, optimize an image, upload, run a script). See [Custom actions](#custom-actions).

### Command palette

- `:` or `Ctrl+P` opens a fuzzy-searchable palette listing **every** action — navigation, file ops, sorting, tabs, bookmarks, and your custom actions — so nothing is keyboard-only-if-you-remember-the-shortcut.

### Path autocomplete (`Ctrl+L`)

- The address bar completes paths **natively** (C++ `QDir`, no `ls`/`compgen` shell-out): live suggestions as you type, `Tab` to complete the current segment and descend, `↑`/`↓` to walk the suggestions, `Enter` to go. Resolves `~`, absolute paths, and paths relative to the current folder, with smart-case matching.

### Hyprland / Wayland integration

- A real tiled Wayland window (a Qt `ApplicationWindow`), not a modal overlay or layer-shell popup — it tiles alongside your terminal and editor like any other app.
- A single instance is enforced: a second `omafiles [path]` navigates the running window (raising it) instead of opening a new one.
- The active panel's folder refreshes live (via a native `QFileSystemWatcher`) instead of only on `F5`; drives (UDisks2) and network locations (GVfs) both update reactively too, no polling.
- Every icon is a verified Nerd Font glyph (checked against the installed font's cmap) — no emoji. Broken symlinks are flagged clearly (distinct icon, red name, "Broken link").
- Basic screen-reader support (`Accessible.role`/`Accessible.name`) on the file list, sidebar, nav buttons, text inputs, and dialog buttons.

## Keyboard shortcuts

These are the **defaults**. Every one of them (except the five fixed shortcuts below) can be remapped to any key via `~/.config/omafiles/keybindings.toml` — see [Custom keybindings](#custom-keybindings). The table below, the in-app reference (`?`), and the actual dispatch in `logic/KeyboardShortcuts.qml` all read from one source of truth (`state/KeyboardDefaults.qml`), so they can't drift out of sync; the in-app `?` overlay always reflects your *effective* bindings, defaults or not.

| Key | Action |
| --- | --- |
| `j` / `k` / `↓` / `↑` | Move down / up |
| `Shift`+`↓` / `↑` | Extend selection down / up (arrow keys only — `Shift+j`/`Shift+k` are plain, unbound key presses) |
| `h` / `Backspace` | Go up a directory |
| `l` / `Enter` | Open (enter directory / launch file) |
| `Alt+←` / `Alt+→` | Back / forward (per panel) |
| `gg` / `Shift+G` | Jump to top / bottom |
| `Space` | Toggle preview (Quick Look) |
| `/` / `Ctrl+F` | Search files (name; prefix `content:` to search inside files) |
| `:` / `Ctrl+P` | Command palette |
| `Ctrl+A` | Select all |
| `Ctrl+Shift+A` | Select none |
| `Ctrl+I` | Invert selection |
| `F2` | Rename |
| `Delete` | Delete (to trash) |
| `Ctrl+C` / `Ctrl+X` / `Ctrl+V` *(fixed)* | Copy / cut / paste |
| `Ctrl+Z` *(fixed)* | Undo |
| `Ctrl+Shift+Z` / `Ctrl+Y` | Redo |
| `s` / `Shift+S` | Cycle sort field / reverse order |
| `Ctrl+L` | Edit path (with autocomplete: `Tab` completes, `↑`/`↓` pick, `Enter` goes) |
| `Ctrl+Shift+N` | New folder |
| `Ctrl+N` | New file |
| `Ctrl+T` / `Ctrl+\` | New panel |
| `Ctrl+W` | Close active panel |
| `Ctrl+Tab` *(fixed)* | Next panel |
| `Ctrl+H` | Toggle hidden files |
| `Shift+Enter` | Open a terminal here |
| `F5` | Refresh |
| `?` | Toggle keyboard shortcuts help |
| `Alt+N` | Recent notifications |
| `Escape` | Close search, then preview, then the active panel (with 2+ panels) |

`gg` and `Escape` are handled structurally (a two-key chord and a context-sensitive close, respectively) rather than as single key bindings, so they're not in `keybindings.toml`. `SearchBar` and the command palette have their own independent `↑`/`↓` navigation, unaffected by `move_up`/`move_down` remapping — a known limitation, not a bug.

## Custom keybindings

Drop a TOML file at `~/.config/omafiles/keybindings.toml` to remap any non-fixed shortcut above to a different key — useful for alternative keyboard layouts (Colemak, Dvorak, …) where `hjkl`-style navigation lands on inconvenient physical keys.

```toml
[keybindings]
move_down = "n"
move_up   = "e"
go_up     = "m"
open      = "i"
rename    = "r"
refresh   = "ctrl+shift+r"
```

**Format:** a flat `[keybindings]` table, `action_name = "key"`. The key is a single character (`"n"`) or named key (`"return"`, `"space"`, `"backspace"`, `"delete"`, `"tab"`, `"f2"`, `"f5"`, an arrow name, or a symbol), optionally prefixed with `ctrl+`, `shift+`, and/or `alt+` (e.g. `"ctrl+shift+r"`). Action names match the left column of the table above (snake_case — see the in-app `?` overlay or `state/KeyboardDefaults.qml` for the full id list). Assigning a key **replaces all of that action's default keys** — e.g. overriding `move_down` frees up both `j` and `↓`, not just one of them.

**Fixed shortcuts** (`Ctrl+C`/`Ctrl+X`/`Ctrl+V`/`Ctrl+Z`/`Ctrl+Tab`) can't be remapped — they follow OS/desktop clipboard-undo conventions and the near-universal "next tab" binding, and an entry for one of them in the config is ignored.

**Conflicts and invalid entries never break startup.** If a key is already claimed by another (non-overridden) action, if an action name doesn't exist, or if a key spec can't be parsed, that one entry is ignored and its action keeps its default — you get a desktop notification listing what was skipped, everything else in the file still applies. A missing file (the common case) is silent and identical to having no overrides at all.

Like `actions.toml`, this is hand-edited only — Omafiles never writes it — and is read once at startup (no file watcher); relaunch after editing it.

## Custom actions

Drop a TOML file at `~/.config/omafiles/actions.toml` to add your own commands. They appear in the command palette (`:` / `Ctrl+P`) and in the context menu of the selected file(s).

Each `[[action]]` block:

```toml
[[action]]
label   = "Open in your editor"
command = "$EDITOR {path}"
context = "file"          # optional: any (default) | file | dir

[[action]]
label   = "Optimize PNG"
command = "optipng {path}"
context = "file"

[[action]]
label   = "Open folder in terminal"
command = "kitty --directory {path}"
context = "dir"
```

**Keys:** `label` (shown text, required), `command` (shell command, required), `context` (when to show it: `any` / `file` / `dir`, matched against the current selection).

**Placeholders** in `command`, each shell-quoted automatically so spaces and quotes are safe:

| Placeholder | Expands to |
| --- | --- |
| `{path}` | absolute path of the first selected item |
| `{name}` | its base name |
| `{ext}` | its extension (without the dot) |
| `{dir}` | the folder that contains it |
| `{paths}` | all selected paths, space-separated |

The command runs fire-and-forget with a `cd` into the item's folder. The file is **reloaded automatically** when you open the palette or a context menu — edit it and the changes take effect with no restart. There is no preferences window and no daemon; actions are never shown inside archives or the trash (paths there aren't real on disk).

## Installation

Omafiles is a **Qt6 standalone application** (no longer a Quickshell plugin), fully independent of Omarchy and of this repository. Clone it **anywhere**, build, and install to `~/.local` (no root):

```bash
git clone https://github.com/Percius04/omafiles
cd omafiles
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
ninja -C build
cmake --install build      # binary, backend .so, QML/scripts/assets, icon
```

`cmake --install` deploys everything to standard XDG locations, so **once installed you can delete the cloned repo and Omafiles keeps working**:

- binary → `~/.local/bin/omafiles`
- backend module → `~/.local/lib/qt6/qml/Omafiles/Backend/`
- QML, scripts and assets → `~/.local/share/omafiles/` (`$XDG_DATA_HOME`)
- icon → `~/.local/share/icons/hicolor/scalable/apps/omafiles.svg`

Config lives in `~/.config/omafiles/` (`$XDG_CONFIG_HOME`), persistent state in `~/.local/state/omafiles/` (`$XDG_STATE_HOME`), and caches in `~/.cache/omafiles/` (`$XDG_CACHE_HOME`). Running from a source checkout still loads QML live from the tree, so development iteration is unchanged.

Run it from the terminal (`omafiles`, or `omafiles <folder>`), or bind a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + F", "Omafiles (file manager)", { launch = "omafiles" })
```

### Optional dependencies

Everything below is truly optional in the sense that OmaFiles starts and runs fine without it — but **python-gobject** is the one exception in this table worth calling out on its own: it's not required to *build* or *launch* the app, yet `install-integrations.sh` (which runs automatically, unprompted, on first launch) needs it to self-register as the default file manager / `org.freedesktop.FileManager1` / the FileChooser portal, and that self-registration fails silently without it. Everything else below degrades gracefully or falls back to a different mechanism.

| Tool | Enables |
| --- | --- |
| **tracker3** / **plocate** | Faster global filename search (otherwise falls back to the built-in recursive search engine) |
| **ffmpegthumbnailer** | Video thumbnails |
| **gvfs** / **gvfs-smb** | Network locations (SFTP, FTP, WebDAV, SMB) |
| **python-gobject (Gio)** | D-Bus desktop integration and FileChooser portal support — see the note above, this one silently no-ops rather than degrading gracefully |
| **zip** / **unzip** | Compress / extract `.zip` — unlike the rows above, there's no fallback: without these, Compress and extracting a `.zip` fail with an error notification instead of degrading gracefully |
| **p7zip** | Extract `.7z` archives, and create them via the "Compress to .7z" option (browsing archives, and `.tar`-family extract/compress including `.tar.gz`, don't need this) |
| **unrar** | Extract `.rar` archives |
| **xdg-mime** | Registering Omafiles as the default file manager on first launch, and resolving the default app for "open with default" double-clicks (both best-effort, guarded by `command -v`) |
| **script (util-linux)** | Live intra-file percentage on archive compress/extract progress bars (fakes the TTY the archivers' isatty-gated progress output needs). Note some distros split it out of the core util-linux package — Fedora ships it as `util-linux-script`. Without it, jobs still run and complete normally, just without the live percentage |

**No longer required:** `xdg-terminal-exec`, `gio` (shell commands), `ffprobe`, `python-pygments`, `content-search.sh`, `empty-trash.sh`, and `inotifywait` have all been replaced by native C++ implementations.

## System integration

Omafiles sets itself as the system's default file manager automatically on first launch — nothing to run by hand. It registers both handoff mechanisms Linux apps use:

- **Opening directories** (`xdg-open`, "Open folder" actions): a `~/.local/share/applications/io.github.percius04.omafiles.desktop` (a reverse-DNS ID, required for D-Bus activation) with `MimeType=inode/directory`, set via `xdg-mime default`.
- **"Show in file manager"** (Firefox downloads, GTK/Qt "reveal in folder"): these go over the `org.freedesktop.FileManager1` D-Bus interface, not `.desktop`/`xdg-mime`, and Nautilus normally owns it. Omafiles ships a user-level service file for the same bus name (`~/.local/share/dbus-1/services/`), which takes priority over Nautilus's system one, backed by `scripts/dbus-filemanager1.py`.
- **File Chooser Portal** (Save/Open dialogs from browser and GTK apps): these go over the `org.freedesktop.impl.portal.FileChooser` interface. Omafiles implements this portal backend via a user-level D-Bus service (`scripts/dbus-filechooser.py`), registering it as the preferred backend in `portals.conf` (and desktop-specific files like `hyprland-portals.conf`). Picker dialogs run with window class / `app_id` `omafiles-picker` so window managers can float and center them (e.g. in Hyprland: `windowrulev2 = float, class:^(omafiles-picker)$` and `windowrulev2 = size 900 600, class:^(omafiles-picker)$`).

This is idempotent and only runs once (tracked in `~/.local/state/omafiles/integrations-version`), so it won't fight you if you switch the default back by hand. To undo it: `xdg-mime default nautilus.desktop inode/directory`, then remove the two files above.

Because it's a normal Wayland window, it tiles under Hyprland like any app, opens from other applications' "reveal in folder" actions, and enforces a single instance (a second launch navigates the existing window).

## Architecture

Omafiles is a thin, declarative QML front-end over a shared high-performance native C++ backend:

- **QML (Front-End)** — the UI, split into `core/` (composition root, controller registry, main layout), `panels/` (file lists and background panels), `dialogs/`, `shared/` (reusable visuals), `logic/` (controllers: navigation, selection, search, file ops, custom actions…), and `state/` (singletons holding hot state — current path, entries, selection, tabs…). No monolithic god objects: controllers are owned by a single `ControllerRegistry` and receive explicit dependencies.
- **C++ (`Omafiles.Backend`)** — a shared QML plugin (`libomafiles-backend.so`) doing the heavy lifting natively without shell-out overhead:
  - `DirectoryModel` — asynchronous directory scanning (`readdir`/`stat`) exposing natural-sorted entries and a 64-bit FNV-1a content signature with in-process `QFileSystemWatcher` live reload.
  - `FileOperations` — copy, move, trash, restore, delete, and `emptyTrash` with byte-accurate progress, cancellation, and canonical multi-mount path normalization.
  - `SearchWorker` — native multithreaded recursive name search and in-process content search (`content:`) with binary auto-detection, line matching, and snippet extraction.
  - `PreviewProvider` & `ThumbnailProvider` — asynchronous image/video thumbnail caching and native text previews.
  - `SyntaxHighlighter` — in-process native syntax highlighting for C++, Python, QML, JSON, and Shell scripts.
  - `MediaInfo` — in-process native audio and video metadata extraction (WAV, MP3 ID3v1/ID3v2, FLAC, MP4/MOV, OGG, MKV/WebM) with $< 0.1\text{ ms}$ latency.
  - `UDisksWatcher` & `GvfsWatcher` — reactive local-drive (UDisks2) and network-mount (GVfs, session D-Bus) monitoring, no polling for either; `NetworkMounts` lists the active GVfs mounts themselves.
  - `PathCompleter` — native `QDir`-based path completion for `Ctrl+L`.
  - `MimeResolver`, `TerminalResolver` & `NetworkResolver` — native association, terminal detection, and socket status checks without spawning shell subprocesses.
  - Plus `ProcessRunner`, `ProcessWatcher`, `Detached`, `FolderCounter`, `JsonStore`, `Env`, and `Notifier`.

## Testing & Quality Gates

Omafiles enforces strict automated quality and performance gates before every release:

- **Headless Self-Check Suite:** `omafiles --selfcheck` runs an automated in-memory test suite verifying **146/146** checks across filesystem operations, undo/redo stacks, D-Bus interfaces, keyboard dispatch, and UI instantiation.
- **Performance Regression Gate:** `python3 bench/bench-gate.py --check-gate` validates cold startup, memory usage, large directory listings (up to 100k files), search latency, and I/O throughput against the canonical baseline (`bench/baseline.json`).

## Status

Stable Release (`v1.1.0`) — ready for production use.

## License

MIT — see [LICENSE](LICENSE).

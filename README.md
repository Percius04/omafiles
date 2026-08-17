# Omafiles

A keyboard-first **multi-panel** file manager for [Omarchy](https://omarchy.org), built as a **Qt6 standalone application** (`v0.9.1`). It is not an Omarchy shell plugin and does not wrap Nautilus, Dolphin, or Thunar. It runs as a normal tileable desktop window and uses Omarchy's `qs.Commons` and `qs.Ui` design system.

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
- Handles images, video thumbnails, native C++ syntax highlighting (C++, Python, QML, JSON, Shell), first-page PDF rendering (`QQuickPdfDocument`/`pdftoppm`), and native C++ audio/video metadata extraction (`MediaInfo`: duration, bitrate, sample rate, channels, codec).
- Preview state is tracked per panel.

### File operations

- Rename, new folder, new file, make link, delete (to trash), copy / cut / paste, drag-and-drop, compress, extract, and bulk rename.
- Nothing silently clobbers an existing name: copy/cut/paste/drag show overwrite / skip / cancel choices; extract/compress/bulk-rename show their own conflict flow; rename refuses an existing target; new folder / new file / make link report conflicts.
- Copy and move use native byte progress. Overwrites are staged beside the destination and committed only after the replacement is complete. Cancellation and pre-commit failure preserve the old destination.
- Copy/cut sync through the Qt system clipboard. `Ctrl+V` can also import an external `text/uri-list` through `wl-paste`. "Copy path" puts shell-quoted plain-text paths on the clipboard.
- Rubber-band selection (drag over empty space; `Ctrl` adds to the selection), range selection with `Shift`+`j`/`k`/`↑`/`↓`, and drag-and-drop both out to and in from other apps.

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
- Uses already-cached credentials (SSH key, saved keyring entry) — there's no in-app password prompt yet.

### Archives

- Browse inside a zip / 7z / rar / tar-family archive without extracting it; opening a file inside extracts just that one file to a temp cache and opens it with your default app. Read-only view.

### Default file manager (`org.freedesktop.FileManager1`)

- Optional, explicit integration supports opening directories, "Show in file manager," and portal-based Open/Save dialogs. OmaFiles never changes these defaults on app launch. See [System integration](#system-integration).

### Thumbnails

- Image and video thumbnails (video via `ffmpegthumbnailer`), cached on disk keyed by path + mtime.

### Bulk rename

- Rename a multi-selection with `{name}` / `{ext}` / `{n}` patterns; recent patterns are saved as one-click chips.

### Permissions (chmod)

- chmod on a multi-selection, with an "Apply to subfolders" toggle for `chmod -R`; handles huge selections natively without hitting `ARG_MAX`.

### Properties

- A read-only Properties panel: real folder size via `du`, permissions, owner, dates — or a combined item count + total size for a multi-selection.

### Custom actions (`actions.toml`)

- Your own commands, surfaced in both the command palette and the item context menu — the escape hatch for anything the manager doesn't ship (open in your editor, optimize an image, upload, run a script). See [Custom actions](#custom-actions).

### Command palette

- `:` or `Ctrl+P` opens a fuzzy-searchable palette listing **every** action — navigation, file ops, sorting, tabs, bookmarks, and your custom actions — so nothing is keyboard-only-if-you-remember-the-shortcut.

### Path autocomplete (`Ctrl+L`)

- The address bar completes paths **natively** (C++ `QDir`, no `ls`/`compgen` shell-out): live suggestions as you type, `Tab` to complete the current segment and descend, `↑`/`↓` to walk the suggestions, `Enter` to go. Resolves `~`, absolute paths, and paths relative to the current folder, with smart-case matching.

### Hyprland / Wayland integration

- A real tiled Wayland window (a Qt `ApplicationWindow`), not a modal overlay or layer-shell popup — it tiles alongside your terminal and editor like any other app.
- A single instance is enforced: a second `omafiles [path]` navigates the running window (raising it) instead of opening a new one.
- The active panel refreshes through `QFileSystemWatcher`; drives react to UDisks2 events. Network mounts refresh on app and mount actions.
- Every icon is a verified Nerd Font glyph (checked against the installed font's cmap) — no emoji. Broken symlinks are flagged clearly (distinct icon, red name, "Broken link").
- Basic screen-reader support (`Accessible.role`/`Accessible.name`) on the file list, sidebar, nav buttons, text inputs, and dialog buttons.

## Keyboard shortcuts

Every shortcut below is handled in `logic/KeyboardShortcuts.qml`; the in-app reference (`?`) mirrors this table.

| Key | Action |
| --- | --- |
| `j` / `k` / `↓` / `↑` | Move down / up |
| `Shift`+`j` / `k` / `↓` / `↑` | Extend selection down / up |
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
| `Ctrl+C` / `Ctrl+X` / `Ctrl+V` | Copy / cut / paste |
| `Ctrl+Z` | Undo |
| `Ctrl+Shift+Z` / `Ctrl+Y` | Redo |
| `s` / `Shift+S` | Cycle sort field / reverse order |
| `Ctrl+L` | Edit path (with autocomplete: `Tab` completes, `↑`/`↓` pick, `Enter` goes) |
| `Ctrl+Shift+N` | New folder |
| `Ctrl+N` | New file |
| `Ctrl+T` / `Ctrl+\` | New panel |
| `Ctrl+W` | Close active panel |
| `Ctrl+Tab` | Next panel |
| `Ctrl+H` | Toggle hidden files |
| `Shift+Enter` | Open a terminal here |
| `F5` | Refresh |
| `?` | Toggle keyboard shortcuts help |
| `Escape` | Close search, then preview, then the active panel (with 2+ panels) |

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

OmaFiles is a standalone Qt6 application, not an Omarchy shell plugin. Build and test it before installing to `~/.local`:

```bash
git clone https://github.com/Percius04/omafiles
cd omafiles
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON
cmake --build build
ctest --test-dir build --output-on-failure
cmake --install build
```

The default user install contains:

- `~/.local/bin/omafiles`
- `~/.local/lib/qt6/qml/Omafiles/Backend/`
- `~/.local/share/omafiles/`
- desktop, D-Bus, portal, and icon files under `~/.local/share/`

The installed app does not need the source checkout. Config lives in `~/.config/omafiles/`, state in `~/.local/state/omafiles/`, and caches in `~/.cache/omafiles/`.

Run `omafiles` or `omafiles <folder>`. An Omarchy key binding can launch the installed app:

```lua
o.bind("SUPER + SHIFT + F", "OmaFiles", { launch = "omafiles" })
```

### Runtime dependencies

The Arch package declares the required Qt, Python/GObject, portal, UDisks, clipboard, and archive tools. Optional tools add these features:

| Tool | Enables |
| --- | --- |
| `plocate` | Faster indexed filename search |
| `ffmpegthumbnailer` | Video thumbnails |
| `gvfs` / `gvfs-smb` | Network locations |
| `7zip` / `unrar` | 7z and RAR browsing |
| `libnotify` | Desktop notifications |

## System integration

Installation does **not** change system defaults. Enable full integration only after reviewing the effect:

```bash
~/.local/share/omafiles/scripts/install-integrations.sh --enable
```

This opt-in action:

- sets `inode/directory` to `io.github.percius04.omafiles.desktop`;
- installs a user-level `org.freedesktop.FileManager1` service without replacing Nautilus's package-owned system file;
- selects OmaFiles for the FileChooser portal in the user portal config;
- records exact prior MIME, portal, and user service state under `~/.local/state/omafiles/integrations/`.

Inspect or undo it with:

```bash
~/.local/share/omafiles/scripts/install-integrations.sh --status
~/.local/share/omafiles/scripts/install-integrations.sh --disable
```

Disable restores unchanged managed files to their recorded baseline. If you edit a managed MIME, portal, or D-Bus file after enabling, disable preserves your edit, reports an incomplete rollback, and keeps the enabled marker for review.

Picker windows use app ID `omafiles-picker`. They run outside the normal single-instance socket, bind portal responses to their D-Bus sender, and never save picker navigation or geometry as normal app state.

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
  - `UDisksWatcher` & `NetworkMounts` — reactive drive monitoring and GVfs mount listings.
  - `PathCompleter` — native `QDir`-based path completion for `Ctrl+L`.
  - `MimeResolver`, `TerminalResolver` & `NetworkResolver` — native association, terminal detection, and socket status checks without spawning shell subprocesses.
  - Plus `ProcessRunner`, `ProcessWatcher`, `Detached`, `FolderCounter`, `JsonStore`, `Env`, and `Notifier`.

## Testing and quality gates

Run the complete tracked gate with:

```bash
cmake -S . -B build -G Ninja -DBUILD_TESTING=ON
cmake --build build
ctest --test-dir build --output-on-failure
```

The v0.9.1 gate includes native data-safety tests, Python portal tests, isolated integration lifecycle tests, installed-layout checks, and **96 source plus 96 installed-tree selfchecks**. The installed-tree test stages the app and forces it to run without source-tree resources.

No deterministic performance release gate is currently claimed. `tests/check-benchmark-status.sh` exits nonzero until a maintained benchmark exists.

## Status

`v0.9.1` is validated for local use. The repository tag and package recipe must identify the same tested source before public release.

## License

MIT — see [LICENSE](LICENSE).

# Omafiles

A high-performance, native **Qt6 / QML** file manager for **Arch Linux (Hyprland/Wayland)**.

Omafiles is a fast, keyboard-first file manager with modern expectations: tabs, split
preview, list & grid views, network mounts, archives, a file picker portal, and a
Nautilus-style sidebar — all rendered with Qt Quick and a lightweight C++ backend.

This fork is maintained by **Flaxenox** and adds several reliability, usability, and
stability fixes on top of the upstream project (see [Fixes included](#-fixes-included)).

---

## ✨ Features

- **Tabs & split preview** — open folders in tabs and preview files side-by-side.
- **Dual view modes** — dense *list* view and thumbnailed *grid* view, with a crossfade animation.
- **Sidebar** — bookmarks, recent files, drives/mounts (USB, partitions), and network locations.
- **Network mounts** — SFTP, FTP, WebDAV, SMB via GVfs, with a Nautilus-like connect flow.
- **Native properties** — real `stat`/`du` sizing and a disk-usage bar (no shelling out).
- **Archives** — compress to `.zip`, extract `.zip`/`.7z`/`.rar` (opt-in backends).
- **Duplicate finder** — locate duplicate files by content.
- **Global search** — fast filename search via `tracker3` / `plocate` when installed.
- **File Chooser portal** — integrates as `org.freedesktop.impl.portal.FileChooser` on Hyprland.
- **Mouse side-button navigation** — back/forward history (Nautilus/Finder style).

---

## 🔧 Fixes included

All changes in this fork are tracked as commits on `master` (see the git history).

### 1. Startup crash — use-after-free (fixed)
- **`main.cpp`**: replaced the manual `QMetaObject::Connection` + `disconnect`/`delete` pattern
  (used to log the first rendered frame) with `Qt::SingleShotConnection`, which detaches cleanly
  after the first emission instead of freeing memory mid-dispatch. Fixes the crash on first launch.

### 2. Play it safe by default — always start on `$HOME`
- **`core/OmafilesContent.qml`**: a plain launch now opens a **single tab on `$HOME`** instead of
  restoring the previous session's tabs.
- **`logic/Persistence.qml`** / **`state/TabsState.qml`**: removed the now-unused `loadSession()`
  restore branch (session file is still written for compatibility, just never restored on startup).

### 3. "Open With" actually launches the app
- **`core/DialogLayer.qml`**: `OpenWithPanel.onAppSelected` previously checked
  `controllers.commandFacade`, which does not exist on `ControllerRegistry` — the guard was always
  false and nothing launched. Now it calls `commandFacade.launchWith(appId)` directly.

### 3b. Terminal-only apps (nvim, vim, …) launch inside a terminal
- **`backend/MimeResolver.cpp`**: `launchApp` now reads `Terminal=true` from a `.desktop` file and,
  when set, runs the command inside the user's terminal emulator (`$TERMINAL` → `xdg-terminal-exec`,
  kitty, foot, alacritty, wezterm, ghostty, gnome-terminal, konsole, xfce4-terminal, xterm) instead of
  launching it detached with no TTY — where TUI apps such as Neovim silently refuse to start.

### 4. `--new-window` flag
- **`main.cpp`**: added `--new-window` / `-new-window` so you can open a second/Nth window (e.g. on
  another Hyprland workspace). Such instances skip the single-instance hand-off and skip owning the
  summon socket, keeping "open folder" requests with the primary window.

### 5. XDG `[Removed Associations]` support — no duplicate "Open With" entries
- **`backend/MimeResolver.cpp`**: added `parseRemovedAssociations()` and applied it in
  `getAppsForFile()`, so desktop IDs listed under `[Removed Associations]` in `mimeapps.list`
  are correctly filtered out. Fixes duplicate entries (e.g. two "Zathura" rows).

### 6. Robust app launch
- **`backend/MimeResolver.cpp`**: `launchApp` now checks the `QProcess::startDetached` return value
  and logs a warning if the app could not be started.

### 7. Network mount fixes (SFTP/FTP/WebDAV/SMB)
- **`backend/NetworkMounts.cpp`**: each mount now surfaces a real `uri` (`scheme://host/share`) so
  unmounting works — unmounting by the local gvfs FUSE path failed with "Containing mount doesn't
  exist". Also added a Nautilus-like `homePath` (the mount's default location).
- **`backend/NetworkResolver.cpp` / `.h`**: `mountFinished` now reports a `homePath` (remote `$HOME`
  for SFTP, the reachable root for others), mirroring what a fresh connect opens.
- **`logic/MountActions.qml`**: disconnect uses `mount.uri`; a successful connect navigates to the
  mount's `homePath`.
- **`core/MainLayout.qml`**: opening a network mount from the sidebar goes to `homePath`.

### 8. Mouse back/forward buttons
- **`core/MainLayout.qml`**: added a `MouseArea` (full-window, `z=10000`) that accepts only
  `Qt.BackButton`/`Qt.ForwardButton` and drives the history — disabled while a blocking overlay
  (context menu / dialog / inline edit) is open.

### 9. Scrollable that can't go off-screen (list & sidebar)
- **`panels/Sidebar.qml`**: the left sidebar now scrolls inside a `Flickable` when its sections
  overflow a short/tiled window, with an auto-showing `ScrollBar.vertical`.
- **`panels/ActiveFileList.qml`**: the right file pane gets an auto-showing `ScrollBar.vertical`
  (right-aligned, appears only when rows actually overflow).
- **`dialogs/ContextMenuPanel.qml`**: the right-click context menu is height-capped so it never goes
  off-screen at 1/4 or 1/2 splits, scrolls via a `Flickable` + scrollbar when needed, and the
  backdrop consumes wheel events so scrolling the menu doesn't also scroll the file list behind it.

### 10. Misc reliability
- **`core/MainLayout.qml`**: the wheel-handling `MouseArea` now uses `acceptedButtons: Qt.NoButton`
  and a higher `z` so it reliably receives wheel events without swallowing clicks/drags.
- **`core/ControllerRegistry.qml`**: dropped a stale `navController` injection in the persistence
  controller.

### 11. Background-pane navigation no longer drops saved tab state
- **`logic/TabOps.qml`**: `navigateTabTo`, `navTabBack` and `navTabForward` rebuilt the tab object as a
  fresh literal, silently discarding every other saved field (scroll position, open search, preview,
  archive state). They now `Object.assign({}, tab, {...})` — merging onto what `saveActiveTab()`
  stored, so back/forward/up on a background panel keeps its scroll, search, preview and archive
  context.

### 12. Preview panel no longer ghosts a stale file's text into a directory listing
- **`logic/PreviewLoader.qml`**: `loadPreview()` bailed immediately for a directory without clearing
  the previous file's `previewIsText` / `previewText` / `previewHighlighted`, so a directory's brief
  preview could keep painting the old file's text behind it. It now resets that state.

> Removed debug/instrumentation hooks are also cleaned out, so there are no leftover
> `ReferenceError`-throwing dev hooks in the deployed panels.

---

## 🛠 Dependencies

**Required:**

| Package | Purpose |
|---|---|
| `qt6-base` | Qt6 Core/Gui/Qml/Quick/DBus/Network |
| `qt6-declarative` | Quick/QuickControls2 + QML tooling |
| `qt6-webengine` | Provides `Qt6::Pdf` |
| `glib2` | GIO (GVfs mounting, network) |
| `zip` `unzip` | Compress/Extract (`.zip`, no fallback) |
| `python-gobject` | D-Bus integration scripts |
| `cmake` `ninja` | Build system (build-time) |

**Optional** (each degrades gracefully without it):

| Package | Purpose |
|---|---|
| `tracker3` / `plocate` | faster global filename search |
| `ffmpegthumbnailer` | video thumbnails |
| `gvfs` / `gvfs-smb` | network locations (SFTP/FTP/WebDAV/SMB) |
| `p7zip` / `unrar` | extract `.7z` / `.rar` |
| `xdg-mime` | register as default file manager / resolve "open with default" |

---

## 🚀 Installation

### Option A — Manual build & per-user install (recommended, no root)

```bash
# 1. Install dependencies (Arch)
sudo pacman -S --needed qt6-base qt6-declarative qt6-webengine glib2 zip unzip python-gobject cmake ninja

# 2. Clone this fork
git clone https://github.com/Flaxenox/omafiles.git
cd omafiles

# 3. Configure & build
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build

# 4. Install (to ~/.local — no root needed)
cmake --install build

# 5. Run
omafiles
```

The app registers itself as the default file manager and the FileChooser portal
automatically on first launch (via `scripts/install-integrations.sh`) — no manual step.

> Optional: to launch Omafiles with `SUPER + SHIFT + F` on Hyprland/Omarchy, add to
> `~/.config/hypr/bindings.lua`:
> ```lua
> o.bind("SUPER + SHIFT + F", "OmaFiles", "omafiles --new-window")
> ```

### Option B — Rebuild after pulling changes

```bash
cd omafiles
cmake --build build
cmake --install build     # re-syncs ~/.local/bin/omafiles + backend .so + QML resources
```

> **Note**: QML files are loaded live from the source tree at runtime (when present), so
> `Sidebar.qml`, `ActiveFileList.qml`, `ContextMenuPanel.qml` and other QML fixes take effect on the
> next launch even without a rebuild. C++ changes (e.g. `MimeResolver.cpp`, `main.cpp`,
> `NetworkResolver.cpp`) require the rebuild above.

### Option C — Arch package (PKGBUILD)

A `PKGBUILD` is provided at `packaging/arch/PKGBUILD`:

```bash
cd packaging/arch
makepkg -si
```

---

## 🧭 Usage

| Action | How |
|---|---|
| Navigate | click / arrow keys / mouse back–forward buttons |
| New tab | `Ctrl+T` |
| Preview | select a file, preview opens beside it |
| Toggle view | list ↔ grid |
| Compress | select items → right-click → Compress |
| Connect to server | sidebar **Connect** (SFTP/FTP/WebDAV/SMB) |
| Open with | right-click a file → **Open With** |

Press `/` for the command palette to browse all shortcuts.

---

## 📝 License

MIT — see `LICENSE`. This is a fork of the upstream
[Percius04/omafiles](https://github.com/Percius04/omafiles) project.

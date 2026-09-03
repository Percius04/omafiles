# OmaFiles Changelog

## [Unreleased]

### Sort by creation date

* **`Created` joins the sort cycle** (`s`): Name -> Size -> Modified -> Created -> Type. The former `Date` key is now labelled `Modified`, since there are two dates. Both are in the command palette as "Sort by date modified" / "Sort by date created".
* **Creation time comes from `statx`**, which replaces the `lstat`/`stat` pair in `DirectoryModel` and `FileOperations::statInfo` at the same syscall count. Filesystems that report no birth time (some network mounts, older `ext4` layouts) yield 0 and the sort falls back to name order.
* **Properties shows a `Created` row** when the filesystem reports one; row subtitles show the creation time while the `Created` sort is active.

## [1.2.0] - 2026-08-21

### Grid & List view modes

* **Centered Grid/Icon View (`Ctrl+G`)**: Seamlessly switch between the classic list and a centered grid view mode, with smooth 160ms crossfade animation. View preference is saved in `~/.local/state/omafiles/ui-prefs.json`.
* **Dynamic Grid Zoom**: `Ctrl` + mouse wheel scales cell, icon, and thumbnail sizes dynamically without extra backend overhead.
* **2D Grid Navigation & Selection**: Full keyboard navigation across columns and rows, plus 2D rectangular marquee selection in grid mode.

### Duplicate file finder

* **Native `DuplicateFinder`**: High-performance background duplicate detector using a two-stage *fdupes*-style pruning pipeline (exact byte size -> 64 KB SHA-256 pre-hash -> full SHA-256 validation).
* **Duplicate Cleanup Dialog**: Interactive modal with live progress, "Select all but first per group" (retaining oldest copy by creation/mtime), and direct deletion to trash with full `Ctrl+Z` Undo support.
* **Menu Integration**: Accessible from the command palette (`:`) and folder context menus ("Find duplicates here...").

### Git status integration

* **Asynchronous Git Badges**: Non-blocking background detection via `git rev-parse` and `git status --porcelain=v1 -z`.
* **File & Directory Badges**: Color-coded badges for modified (`M`, amber), added (`A`, green), deleted (`D`, red), conflict (`U`, red), and untracked (`?`, muted) files, with aggregate status propagation on folder items in both List and Grid views.

### Properties & sidebar polish

* **Native `statInfo()` & `requestDirSize()`**: Eliminated shell subprocess invocations (`stat`/`du`) in the Properties panel in favor of native C++ implementations in `FileOperations`.
* **Sidebar Disk Usage Bars**: Live storage usage bars for mounted drives powered by native `LocalMounts` (`QStorageInfo` `usedFraction`).
* **Sidebar UI Polish**: Slightly widened sidebar, improved font sizes and icon hierarchy.

### Performance & architectural improvements

* **Instant Startup via Lazy Loading**: Deferred instantiation of video/audio playback loaders in `PreviewPanel`.
* **Burst Coalescing in `FolderCountState`**: 16ms timer debounce for folder item counts, avoiding $O(N)$ cascading binding re-evaluations.
* **Native Mount Enumeration (`LocalMounts`)**: Replaced `list-mounts.sh` shell pipeline with native C++ enumeration and 4-tier device sorting.
* **Bounded Video Thumbnail Pool**: 3 concurrent thumbnailer slots to prevent CPU/IO saturation on video-heavy folders.

### Bug fixes

* **Search Bar Auto-Collapse**: Fixed search bar remaining open when clicking away with an empty search query.
* **Preview Panel Layout Fix**: Fixed overlap between "No preview available" status text and the filename heading.
* **Torrent Files**: Added dedicated magnet-glyph icon for `.torrent` files.
* **Background Panel Deduping**: Avoided redundant rescans on already current paths.

### Regression coverage

* Headless `--selfcheck` suite expanded from 146 to **160** automated checks, covering duplicate discovery, cancellation, git status, grid navigation, and performance paths.

## [1.1.0] - 2026-08-19

### File transfers & archives

* **Transfers queue instead of rejecting.** A second copy/move/compress/extract issued while one is already running used to be flatly rejected ("still busy — try again"). It's now queued (FIFO) and starts automatically once its turn comes, shown as a dimmed "Pending" row (with its own Cancel) above the active operation. Quick, effectively-instant actions (rename, chmod, mkdir, trash, restore…) deliberately keep the old reject-on-busy behavior — queueing wouldn't be noticeable there.
* **Compress to `.tar.gz` and `.7z`**, alongside the existing `.zip` — plus live progress bars for archive extract/compress (previously only copy/move had one). `.zst`/`.tar.zst` and `.tbz`/`.tbz2` are now consistently recognized as browsable/extractable archives.

### Bulk rename

* **Regex Find/Replace**, applied to the base name before the `{name}`/`{ext}`/`{n}` pattern — supports capture-group backreferences (`$1`); an invalid regex while typing is treated as a no-op instead of breaking the dialog.
* **Zero-padded sequence numbers**: `{n:3}` → `001`, `002`… (`{n}` alone stays unpadded, unchanged).
* **Live preview**: every resulting name is shown, row by row, before confirming — driven by the exact same function the real rename uses, so the preview can never diverge from what actually happens.

### Preview

* Inline **video/audio playback** (Qt Multimedia) in Quick Look — play/pause, auto-stops when you move to another item — instead of a thumbnail/metadata-only view.

### Network locations

* **Reactive GVfs mount watcher**: a network drive mounted or unmounted from another app is now picked up live, the same gap `UDisksWatcher` already closed for local devices.
* **Saved connection profiles** (URI only, never a password) for one-click reconnecting to previously used servers.

### Notifications

* Migrated from `notify-send` to real desktop notifications (`org.freedesktop.Notifications` over D-Bus), plus an `Alt+N` recent-notifications panel (session-only history) in case you missed one.

### Undo / Redo

* Closed a real, previously-documented gap: `undoLast()`/`redoLast()` used to move an entry to the opposite stack (and show "Undoing:"/"Redoing:") as soon as the underlying operation *started*, not once it had genuinely *completed* — a redo pressed right after an undo could fire while that undo was still in flight. Now deferred until real completion; regression-tested against the exact race.

### Bug fixes

* A real, empirically-reproduced ~10% flake in the `.7z` compress/extract selfcheck, root-caused to a guessed fixed-duration settle instead of a deterministic check.
* `main.cpp`'s import-path priority was backwards: a dev build could silently load the stale *installed* backend instead of its own.
* A selfcheck testing its own background-panel refresh logic was polling a bounded (8-entry) LRU cache shared by every background panel in the app — real activity from unrelated tabs could evict its entry within milliseconds under a long test run, a genuine ~15-25% flake unrelated to any real bug. Fixed by observing the panel's own listing state directly instead.
* Dead code removed (`Persistence.saveRecent`/`saveBulkRenameHistory`, `TabOps.closeTabAt`, `FileMeta.parseAudioInfo`), a 4×-duplicated busy guard in `ActionEngine` consolidated, two `toLowerCase()`-in-comparator hot paths hoisted to match an existing C++-side fix.

### Regression coverage

* The headless `--selfcheck` suite grew from 92 to **146**, adding dedicated coverage for the transfer queue (including cross-kind queueing and mid-queue cancellation), bulk rename's regex/padding/preview, drag-and-drop (move+undo/redo, conflict handling, the self-drop guard), and the undo/redo completion-timing fix.

## [1.0.1] - 2026-08-17

Bug-fix-only hotfix release. No new features.

* **Fixed: the app could freeze entering Trash.** Trash-root discovery and `.trashinfo` parsing ran synchronously on the UI thread on every Trash navigation; a slow disk (spun-down mechanical drive) or a stalled network/FUSE mount could block the entire app for as long as that mount took to respond. Both are now handled off the UI thread via the existing async backend pattern. See `docs/audits/V1_1_P0_TRASH_FREEZE_REPORT.md` for the full investigation.
* Hardened Restore/permanent-delete against a related race exposed by the fix above: acting on a Trash item before its metadata has finished loading now notifies instead of silently doing nothing.
* Packaging: fixed `install-integrations.sh` assuming a per-user `$HOME/.local/share` install even when packaged system-wide (e.g. under `/usr`); the app's version is now exposed to QML from the single CMake-authoritative source instead of nowhere.

## [1.0.0] - 2026-08-17

A forensic-audit-driven hardening release on top of v0.9.0's architecture: a full concurrency/security pass (verified with AddressSanitizer, not just code review), a round of architectural cleanup that kept the codebase's size in check instead of letting it grow, a new custom-keybindings system, and a much wider automated regression suite. No new user-facing features beyond custom keybindings and alternating row colors — this release is about correctness and stability on the foundation v0.9.0 already built.

### Filesystem operations & concurrency safety

* **Use-after-free fixes in `FileOperations`, `SearchWorker`, and `ThumbnailProvider`**, each reproduced for real with AddressSanitizer against a standalone repro binary (not just inferred from code review), fixed to match the `Life`+mutex discipline `DirectoryModel` already used correctly, then re-verified clean with the same ASan binary across repeated passes.
* **Per-operation cancellation tokens:** `FileOperations` used to reuse a single shared cancellation flag across every copy/move/remove/trash/restore call. Two operations overlapping in time could silently interfere with each other's cancellation state. Each call now gets its own independent token; re-verified with a targeted ASan stress test (overlapping copy + cancel + immediate second copy, 300 operations across 4 passes, zero violations).
* **Data-integrity and packaging fixes** from the forensic audit pass, including a missing `qt6-webengine` build dependency (`Qt6::Pdf` failed to configure without it) and a symlink-at-cache-path vulnerability in archive file opening (a pre-planted symlink could have redirected an extracted file's write).

### Archive handling

* **`ArchiveBrowser`** extracted from the `ActionEngine` monolith into its own component — the one piece of that file with a genuinely independent lifecycle (browsing vs. mutating), identified by an explicit architectural audit rather than split "because it was large."
* Archive-open path hardened against the symlink vulnerability above; dedicated regression coverage added (none existed before).

### Custom keybindings

* Every keyboard shortcut (except five fixed OS-convention ones: Ctrl+C/X/V/Z, Ctrl+Tab) can now be remapped via `~/.config/omafiles/keybindings.toml` — built specifically for alternative keyboard layouts (Colemak, Dvorak, etc.) where the default `hjkl`-style navigation lands on inconvenient keys.
* One authoritative source of truth (`state/KeyboardDefaults.qml`) now drives the actual dispatch, the in-app `?` help overlay, and the README's shortcut table — replacing three independently-hand-maintained copies that had already drifted out of sync with each other.
* Deterministic conflict handling: a colliding or invalid entry in the config falls back to its default with a warning, never leaves an ambiguous binding.

### Architectural cleanup

* `shared/`'s two known contract violations (`MarqueeCatcher.qml`, `PathCompletionField.qml` importing `state`/`Backend` directly, against this project's own layering rules) fixed — `shared/` is now fully compliant.
* `ActionEngine.qml` audited end to end for further extraction candidates; kept intentionally intact everywhere except the archive-browsing split above, since everything else funnels through one of two shared execution primitives (shell dispatch, native batch dispatch) that must stay co-located.
* Stale comments referencing a pre-Phase-43 file split that no longer exists (`ConflictActions.qml` and five other dissolved filenames) corrected throughout `logic/` and `state/`.
* Alternating row background colors added as an opt-in, zero-behavior-change-by-default property on the shared `CursorSurface` component, applied only to the two file-list row delegates.

### Bug fixes

* **Bulk rename** could produce an empty target filename from a pattern like `{ext}` on an extensionless file (e.g. `mv -n -- file ''`), reached through a misleading "conflict" dialog rather than a clear error. Now validated upfront with a plain rejection notification.
* **A stale, misleading error message** ("Couldn't restore from trash") was shown for *any* failing shell-based action — rename, bulk rename, chmod, compress, extract, make-link — a leftover from before that handler was shared across all of them. Now reports a generic, accurate failure message.
* **The default-file-manager self-registration** (`org.freedesktop.FileManager1` / `inode/directory` `xdg-mime` setup) had been silently broken for several days due to a wrong internal script path — `Backend.Detached.run()` on a missing path fails with no error, no crash, and no visible symptom, so this went undetected through an entire architectural audit pass until the final release audit caught it directly.

### Regression coverage

* The headless `--selfcheck` suite grew from 85 (v0.9.0) to **124**, adding dedicated coverage for: archive browsing, alternating rows, the full custom-keybindings resolver (defaults, overrides, conflicts, invalid config, text-input protection, help-overlay accuracy), bulk rename (pattern substitution, empty-name rejection, collision handling, undo/redo), chmod commit+undo, and a compress→extract round-trip with byte-for-byte content verification.
* A latent race in the selfcheck harness itself (not production code) was found and fixed: a timed-out test's stale signal handler could remain connected to a shared backend singleton and misfire on a later, unrelated test's completion signal under real I/O contention — root-caused by direct inspection, not just reproduction, and fixed by disconnecting stale handlers on timeout.

### Packaging

* `zip` and `unzip` added to the Arch package's runtime dependencies — Compress always produces a `.zip` and Extract needs `unzip` for that same default format; unlike the already-documented optional tools, there's no graceful fallback for either. `p7zip`/`unrar` remain optional (only needed for `.7z`/`.rar`, documented in the README).
* Production-path packaging verified end to end this release: built with the exact install paths `packaging/arch/PKGBUILD` uses, staged to an isolated `DESTDIR`, and the staged binary itself launched and passed the full selfcheck suite from that staged location — not just "the files exist in the right place."

## [0.9.0] - 2026-08-15

OmaFiles v0.9.0 stable is the culmination of the standalone Qt6 generation. This release completely transitions OmaFiles from a shell-integrated prototype into a high-performance native desktop application with zero external shell dependencies in its hot paths.

Following the DHH design philosophy of "less code, fewer abstractions, obvious boundaries," the codebase has been aggressively consolidated.

### Highlights

* **Pure Standalone Qt6 Architecture:** Completely decoupled from external shell runtimes, running natively on standard Qt 6.5+ installations across Wayland and X11.
* **Native C++ Previews & Highlighting:** In-process syntax highlighting (`SyntaxHighlighter`: C++, Python, QML, JSON, Bash) and media metadata parsing (`MediaInfo`: WAV, MP3, FLAC, MP4/MOV, OGG, MKV/WebM) with < 0.1 ms latency and zero UI blocking.
* **Native Multithreaded Content Search:** In-process `SearchWorker` for recursive content searching (`content:`) with streaming matches, binary detection, snippet extraction, and line numbers.
* **Native Filesystem & Trash Operations:** In-process directory monitoring via `QFileSystemWatcher` with 64-bit FNV-1a content signatures. Native cancellable trash operations supporting cross-device mounts according to the FreeDesktop standard.
* **Native Mime & App Resolution (`MimeResolver`):** Replaced shell-based `xdg-mime` lookups with a high-performance C++ backend utilizing `gio-2.0` APIs. Desktop file parsing and associations are native and instant.
* **Native Terminal Detection (`TerminalResolver`):** Eliminated `xdg-terminal-exec` wrappers. Automatically detects and launches available Linux terminals via `QProcess` seamlessly.
* **Intelligent Network Behavior (`NetworkResolver`):** Pure C++ GIO integration for asynchronous mounting of `sftp://`, `smb://`, `dav://` URLs with ephemeral, native auth dialogs without blocking the UI.
* **Architecture Consolidation:** Flatter QML object graph. 11 scattered `*Ops.qml` files were consolidated into a single highly cohesive `ActionEngine.qml`.
* **Zero-Friction UI Audit:**
  - Radically simplified all Empty States with actionable sub-messages ("Drop files here to add them").
  - Stripped "bureaucratic" prefixes from Error Messages ("Permission denied" natively).
  - Hardened interaction consistency across panels, ensuring a 100% keyboard-only workflow without dead ends.
* **85/85 Passing SelfChecks:** Comprehensive automated headless test suite validating filesystem operations, terminal error paths, keyboard routing, undo/redo stacks, and UI instantiation.

### Bug Fixes since RC1

* **Selection:** Fixed an issue where the lasso/marquee selection did not work in the main file lists due to broken `SelectionState` connections in `MarqueeCatcher`.

### Linux & Desktop Integration

* **Desktop File Manager Specification (`org.freedesktop.FileManager1`):** Native implementation of `ShowFolders`, `ShowItems`, and `ShowItemProperties` over the D-Bus session bus.
* **XDG Desktop Portal FileChooser:** Built-in support for `org.freedesktop.impl.portal.FileChooser`, enabling sandboxed Flatpak and native applications to use OmaFiles.
* **Portable Binary Resolution:** D-Bus service scripts dynamically resolve `omafiles` across standard `PATH` and local prefixes.

### Compatibility

* **Qt Version:** Qt 6.5 or later (Core, Gui, Qml, Quick, QuickControls2, DBus, Pdf, Network).
* **Display Servers:** Native Wayland and X11 support.
* **Desktop Environments:** Hyprland, Sway, GNOME, KDE Plasma, XFCE.
* **Build System:** CMake 3.21+ with standard `GNUInstallDirs` conventions.

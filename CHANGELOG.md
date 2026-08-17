# OmaFiles Changelog

## [0.9.3] - 2026-08-17

* Makes restore, overwrite commit, and recursive deletion race-safe with no-replace and descriptor-relative Linux APIs.
* Tracks the exact trash payload through undo and redo, and reports post-commit cleanup as warnings.
* Uses exclusive native file and folder creation; existing entries cannot be replaced.
* Uses confirmed native results for bulk rename history and no-clobber archive operations.
* Makes integration enable recoverable after interruption and authenticates portal frontend request ownership.
* Serializes simultaneous app startup without unlinking a live single-instance socket.
* Implements FileChooser filters, current filter, and choices, plus distinct FileManager1 properties behavior.
* Adds tracked AddressSanitizer and package `check()` gates.
* Current release gate: 82 native safety checks, 28 FileChooser tests, 4 FileManager1 tests, 106 source selfchecks, and 106 installed-tree selfchecks.

## [0.9.2] - 2026-08-17

* Makes no-overwrite copy, move, and rename commits atomic with Linux `renameat2(RENAME_NOREPLACE)`.
* Adds race regressions that prove a destination created during commit is never replaced.
* Removes duplicate picker validation and dead chmod/directory state while preserving trust-boundary checks.
* Clears the remaining strict compiler warnings in `NetworkResolver`.
* Current release gate: 63 native safety checks, 11 portal helper tests, and 96 source plus 96 installed-tree selfchecks.

## [0.9.1] - 2026-08-17

This release hardens data safety, asynchronous action state, trash identity, and desktop integration.

### Safety

* Rejects copy and move targets that equal or sit inside the source.
* Stages overwrite replacements and rolls back failed commits instead of deleting the old destination first.
* Validates mounted trash roots without following symlinked root, `files`, or `info` directories.
* Preserves trash metadata when payload deletion fails.
* Protects preview workers from provider teardown and preserves relative symlink targets.
* Validates rename, new-item, and bulk-rename basenames at UI and backend boundaries.

### Actions and undo

* Correlates native completion signals and serializes mkdir with other native operations.
* Records one undo entry for each completed move or trash item, including partial batches.
* Moves undo and redo entries only after asynchronous success.
* Captures absolute chmod targets so navigation cannot redirect undo.
* Rejects rename-over-existing-item rather than offering an undo that cannot restore displaced data.
* Uses exact mounted-trash payload paths, so duplicate display names cannot target another volume.

### Desktop integration

* Makes default-file-manager and portal setup explicit with `install-integrations.sh --enable`.
* Adds reversible `--disable` and inspectable `--status` flows with baseline and edit preservation.
* Installs layout-correct desktop, D-Bus, and portal descriptors without conflicting with Nautilus's system FileManager1 service.
* Implements encoded local-file URIs and the ordered `SaveFiles` portal contract.
* Binds picker responses to the launched process's D-Bus sender and handles request closure without orphan windows.
* Adds the required Arch runtime dependencies and portable binary lookup.

### Verification

* Restores the tracked selfcheck harness and registers it with CTest.
* Adds native data-safety tests, portal helper tests, reversible integration tests, installed-layout tests, and source/installed-tree selfchecks.
* Current release gate: 61 native safety checks, 11 portal helper tests, and 96 source plus 96 installed-tree selfchecks.

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

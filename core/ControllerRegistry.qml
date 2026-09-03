import QtQuick
import "../logic"
import Omafiles.Backend as Backend

// ControllerRegistry -- SOLE owner of all the logic/ controllers
// (Phase 11.C, josema: eradicate the scattered ownership that the
// 2026-08-09 audit flagged). Before, OmafilesContent instantiated the 22
// controllers + used them by id as a god object; now it instantiates them
// here and receives them by property. The controllers still see
// OmafilesContent as `root` (hot state in NavState + facade by
// delegation) and the active ListView as `list` -- both injected.
//
// `root: registry.root` / `list: registry.list` go QUALIFIED: since
// registry has properties root/list and each controller does too, an
// unqualified `root: root` would self-reference (binding loop -> null,
// same case as MainLayout). The cross references between controllers
// (selectionOps, archiveActions, tabOps...) are ids, not properties, so
// they resolve unambiguously and stay unqualified.
Item {
  id: registry

  property Item root
  property Item list

  readonly property alias videoThumbs: videoThumbs
  readonly property alias searchOps: searchOps
  readonly property alias fileMeta: fileMeta
  readonly property alias tabOps: tabOps
  readonly property alias navController: navController
  readonly property alias archiveBrowser: archiveBrowser
  readonly property alias openProc: openProc
  readonly property alias mountOps: mountOps
  readonly property alias persistence: persistence
  readonly property alias actionEngine: actionEngine
  readonly property alias previewLoader: previewLoader
  readonly property alias propertiesLoader: propertiesLoader
  readonly property alias customActions: customActions
  readonly property alias keybindingResolver: keybindingResolver

  VideoThumbnails {
    id: videoThumbs
    root: registry.root
  }

  SearchOps {
    id: searchOps
    root: registry.root
    list: registry.list
    navController: navController
  }
  FileMeta {
    id: fileMeta
    root: registry.root
  }
  TabOps {
    id: tabOps
    archiveBrowser: archiveBrowser
    root: registry.root
    list: registry.list
    previewLoader: previewLoader
    navController: navController
  }
  NavigationController {
    id: navController
    actionEngine: actionEngine
    archiveBrowser: archiveBrowser
    root: registry.root
    list: registry.list
    mountOps: mountOps
  }
  ArchiveBrowser {
    id: archiveBrowser
    list: registry.list
    navController: navController
  }

  // Shared launcher to open with the default app / open a
  // terminal here.
  Backend.ProcessRunner {
    id: openProc
  }

  MountActions {
    id: mountOps
    root: registry.root
    tabOps: tabOps
    navController: navController
  }

  Persistence {
    id: persistence
    root: registry.root
    tabOps: tabOps
  }

  ActionEngine {
    id: actionEngine
    root: registry.root
    navController: navController
  }


  PreviewLoader {
    id: previewLoader
    root: registry.root
    videoThumbs: videoThumbs
    fileMeta: fileMeta
  }

  PropertiesLoader {
    id: propertiesLoader
    root: registry.root
  }

  CustomActions {
    id: customActions
    root: registry.root
  }

  // No root/list injection needed -- fully self-contained (reads Paths/
  // KeyboardDefaults/Backend.Notifier only). logic/KeyboardShortcuts.qml
  // reaches it via hostControllers.keybindingResolver; core/DialogLayer.qml
  // via controllers.keybindingResolver (P2.5, 2026-08-17).
  KeybindingResolver {
    id: keybindingResolver
  }

  // No root/list injection needed either -- fully self-contained (reacts
  // to NavState.currentPath/refreshTick directly, writes into
  // GitStatusState). FileRowVisual/FileGridCell read the cache straight
  // from GitStatusState, no reference to this controller needed.
  GitStatusBackend {
    id: gitStatusBackend
  }
}

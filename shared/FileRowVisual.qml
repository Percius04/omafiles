import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "GitStatusColors.js" as GitStatusColors

// Visual content of a file/folder row (icon/thumbnail +
// name + subtitle) -- twelfth component extracted from core,
// and the first truly shared between the active panel and the background
// ones. Previously they were two nearly identical blocks (rowContent/thumbSlot/
// nameCol and bgRowContent/bgThumbSlot/bgNameCol) that had been
// desynchronizing several times this session (the bug of the icon not
// aligned with the name, the one of the row height with 1px too much...) --
// a single component for both eliminates that class of bug at its root
// instead of just relocating it.
//
// It deliberately does NOT include the inline rename field (only the
// active panel has it) nor the MouseArea (each panel needs it
// differently: the active one with selection/context menu/shortcuts, the
// background one only double-click + drag) -- both stay in the
// delegate of each panel, anchored with the same known icon width
// (Style.spacing.controlHeight) instead of needing to see the internal
// "thumbSlot" here.
Item {
  id: root

  property string name: ""
  property bool isDir: false
  property bool isBroken: false
  // Equivalent to "rowSurface.current" in the active panel -- the background
  // panel never sets it to true (there is no row selection there).
  property bool highlighted: false
  // Name in grey (pending cut) -- only applies in the active panel.
  property bool dimmed: false
  // Only used when !isDir && !isBroken (root.iconFor(modelData) already
  // resolved by the caller).
  property string fileIconGlyph: ""
  // Thumbnail already resolved (real image or cached video thumbnail) --
  // "" if it does not apply, same ternary as before but computed by the
  // caller (knows basePath/root.currentPath, this component does not).
  property url thumbSource: ""
  property string metaText: ""
  // Exact value for the subtitle tooltip when the counter is
  // abbreviated (12.3k -> "12,347 items"); "" = no tooltip.
  property string metaTooltip: ""
  // Git status letter ("M"/"A"/"D"/"U"/"?"), already resolved by the
  // caller via state/GitStatusState.qml -- "" = clean or not a repo
  // (no badge). See shared/GitStatusColors.js for the color mapping.
  property string gitStatus: ""
  // The active panel's rename field occupies this same slot --
  // it hides the name/subtitle but leaves the icon visible, just as
  // "nameCol.visible: root.renamingIndex !== index" did before.
  property bool showNameText: true

  // DETERMINISTIC row height (option 3, josema): it is NOT computed from the
  // real content (nameCol.implicitHeight comes from Text.height, which varies according to
  // the loading state of the font/thumbnails -> the SAME row measured differently
  // in each panel and the scroll drifted). It is derived from FontMetrics (pure computation
  // of the typeface: identical line height in ALL rows and in both
  // panels, independent of what has loaded). Both lines are ALWAYS reserved
  // (name + subtitle) even if a row has no subtitle, so the
  // height never changes -> position = index * rowHeight + subOffset exact.
  FontMetrics { id: _nameFM; font.family: Style.font.family; font.pixelSize: Style.font.title; font.weight: Font.Medium }
  FontMetrics { id: _metaFM; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
  implicitHeight: Math.max(Style.spacing.controlHeight,
    Math.ceil(_nameFM.height) + Style.spacing.xs + Math.ceil(_metaFM.height))

  Item {
    id: thumbSlot
    // FIXED-size container for the thumbnail: the (asynchronous) image is
    // cropped inside (clip) and NEVER alters the delegate's geometry.
    clip: true
    anchors.left: parent.left
    // Aligned with the name (nameText), not with the full two-line
    // block -- see the long note that already existed next to this
    // same formula before extracting it here: "anchors.verticalCenter:
    // nameText.verticalCenter" did not give the expected result in this
    // file for some reason never fully identified; an explicit "y"
    // from nameCol.y does, and it is verified with a debug
    // overlay.
    y: nameCol.y + (nameText.height - height) / 2
    width: Style.spacing.controlHeight
    height: Style.spacing.controlHeight

    Image {
      id: thumbImage
      anchors.fill: parent
      visible: status === Image.Ready
      source: root.thumbSource
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      sourceSize.width: 32
      sourceSize.height: 32
    }

    OpticalGlyph {
      anchors.fill: parent
      visible: root.isDir && !root.isBroken
      text: "󰉋"
      fontFamily: Style.font.family
      fontSize: Style.font.iconLarge
      color: root.highlighted ? Commons.Color.menu.selectedText : Commons.Color.menu.text
    }

    // Previously it was hidden with "!hasThumb", which decides by EXTENSION -- a
    // real but slow-to-load image (or with corrupt content,
    // status never reaches Ready) had hasThumb=true without the Image
    // above ever becoming visible, so the row was left
    // with no icon at all. It is based on the real loading state of the
    // Image itself.
    OpticalGlyph {
      anchors.fill: parent
      visible: !root.isDir && !thumbImage.visible && !root.isBroken
      text: root.fileIconGlyph
      fontFamily: Style.font.family
      fontSize: Style.font.iconLarge
      color: root.highlighted ? Commons.Color.menu.selectedText : Commons.Color.menu.text
    }

    // Broken symlink (md-link_variant_off, verified against the
    // font's real cmap) -- previously it looked like a normal
    // 0-byte file dated 1970, with no hint that the target
    // no longer exists.
    OpticalGlyph {
      anchors.fill: parent
      visible: root.isBroken
      text: "\u{F033A}"
      fontFamily: Style.font.family
      fontSize: Style.font.iconLarge
      color: Commons.Color.urgent
    }

    // Git status badge (small colored dot, not a font glyph -- avoids
    // any Nerd Font glyph-verification step entirely and reads cleanly
    // at this size). Declared last so it paints on top of the
    // Image/OpticalGlyph siblings above by declaration order, same
    // z-order convention already used for the broken-symlink overlay.
    Rectangle {
      visible: root.gitStatus.length > 0
      width: 8
      height: 8
      radius: width / 2
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      border.width: 1
      border.color: Commons.Color.background
      color: GitStatusColors.colorFor(root.gitStatus, Commons.Color.urgent, Commons.Color.muted)
    }
  }

  // Two-line row (name + size/relative date) -- same pattern
  // as Omarchy's real composed-row example (icon + Column of
  // title/subtitle).
  Column {
    id: nameCol
    visible: root.showNameText
    anchors.left: thumbSlot.right
    anchors.leftMargin: Style.spacing.rowGap
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.spacing.xs

    Text {
      id: nameText
      width: parent.width
      text: root.name + (root.isDir ? "/" : "")
      font.pixelSize: Style.font.title
      font.family: Style.font.family
      font.weight: Font.Medium
      color: root.isBroken ? Commons.Color.urgent
        : root.dimmed ? Qt.darker(Commons.Color.menu.text, 1.6)
        : (root.highlighted ? Commons.Color.menu.selectedText : Commons.Color.menu.text)
      elide: Text.ElideRight
    }

    Text {
      id: metaTextItem
      visible: root.metaText.length > 0
      width: parent.width
      text: root.metaText
      font.pixelSize: Style.font.bodySmall
      font.family: Style.font.family
      color: root.highlighted ? Commons.Color.menu.selectedText : Commons.Color.menu.text
      opacity: Style.emphasis.secondary
      elide: Text.ElideRight

      // Tooltip with the exact value when the counter is shown abbreviated
      // (12.3k items -> 12,347 items). Only if metaTooltip is provided.
      HoverHandler { id: metaHover; enabled: root.metaTooltip.length > 0 }
      PanelToolTip {
        visible: metaHover.hovered && root.metaTooltip.length > 0
        text: root.metaTooltip
      }
    }
  }
}

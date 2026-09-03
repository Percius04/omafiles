import QtQuick
import qs.Commons
import qs.Ui
import "../shared"

Row {
  id: root
  width: parent ? parent.width : 0
  height: Style.spacing.controlHeight
  spacing: Style.spacing.controlGap

  property var modelData: null
  property int index: -1
  property Item hostTabOps: null
  property Item hostCommandFacade: null
  property bool bgSearching: false

  // Same header as the active panel (back/forward/home/up) --
  // josema asked that the two look the same, not just the active panel
  // with full navigation.
  PanelNavButtons {
    id: bgNavButtons
    canGoBack: (root.modelData.historyIndex || 0) > 0
    canGoForward: (root.modelData.historyIndex || 0) < (root.modelData.history || [root.modelData.path]).length - 1
    onBackRequested: root.hostTabOps.navTabBack(root.index)
    onForwardRequested: root.hostTabOps.navTabForward(root.index)
  }

  // Full breadcrumbs, same as in the active panel -- before only
  // the current folder's name was shown, without the rest of the path.
  BreadcrumbSegments {
    id: bgBreadcrumbRow
    // Same width as the active panel's breadcrumb (pathArea in
    // MainLayout): reserves the gap of the collapsed magnifier (collapsedW =
    // controlHeight) + its separation, even though there is NO magnifier here (the search
    // belongs only to the active panel). So the breadcrumb doesn't change width when
    // the panel becomes active -- no horizontal shift when switching
    // panels (Visual Sprint 3, B-06).
    width: parent.width - bgNavButtons.width - bgSearchPlaceholder.width - 2 * Style.spacing.controlGap
    height: parent.height
    segments: root.hostCommandFacade ? root.hostCommandFacade.pathSegmentsFor(root.modelData.path) : []
    activePath: root.modelData.path
  }

  // Single click on a breadcrumb segment navigates this background tab to
  // that folder (background panels are read-only: no edit-on-double-click).
  MouseArea {
    anchors.fill: bgBreadcrumbRow
    cursorShape: Qt.PointingHandCursor
    onClicked: function (mouse) {
      var p = bgBreadcrumbRow.pathAt(mouse.x)
      if (p && root.hostTabOps) root.hostTabOps.navigateTabTo(root.index, p)
    }
  }

  // Magnifier slot. At rest it's empty (it only reserves the width of the collapsed
  // magnifier of the active panel, so the header has the same geometry
  // in both states). If THIS background panel has a search open,
  // it grows into a read-only bar: query + X to close it. It's read-
  // only because to EDIT you activate the panel (by hovering), which already
  // brings the full interactive magnifier.
  Item {
    id: bgSearchPlaceholder
    // Same expanded width as the active SearchBar (core/MainLayout): 300 px
    // literal (NOT Style.space, which would scale it and made it wider than the
    // original), clamped by what's left after reserving 120 px of breadcrumb
    // (pathArea.minPathW). At rest, only the width of the collapsed magnifier.
    width: root.bgSearching
      ? Math.max(Style.spacing.controlHeight, Math.min(300, root.width - bgNavButtons.width - 120 - 2 * Style.spacing.controlGap))
      : Style.spacing.controlHeight
    height: parent.height

    // READ-ONLY indicator of the search open in this background
    // panel (magnifier + query). It carries no controls of its own: with "activate on
    // hover", any button here would become unreachable (the
    // hover would activate the panel and replace this bar with the interactive
    // magnifier before you could press it). To edit or CLOSE the search
    // you activate the panel (by hovering) and use the usual interactive
    // magnifier (Escape, or click on the magnifier itself).
    // Same geometry and tokens as the active SearchBar expanded (background
    // selectedBackground + border menu.border, magnifier CENTERED in a slot of
    // controlHeight, text starting at iconSlot.right + xs) so the two
    // bars look identical -- before the magnifier was stuck to the text and
    // misaligned relative to the original.
    Rectangle {
      anchors.fill: parent
      visible: root.bgSearching
      radius: Style.cornerRadius
      color: Color.menu.selectedBackground
      border.width: Style.spacing.hairline
      border.color: Color.menu.border

      Item {
        id: bgSearchIconSlot
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.spacing.controlHeight
        height: Style.spacing.controlHeight

        OpticalGlyph {
          anchors.centerIn: parent
          text: "\u{F0349}" // nf-md-magnify
          fontFamily: Style.font.family
          fontSize: Style.font.icon
          color: Color.menu.selectedText
        }
      }

      Text {
        anchors.left: bgSearchIconSlot.right
        // The active TextField starts the text at xs + its internal leftPadding
        // (Style.spacing.controlPaddingX). A plain Text has no such padding,
        // so it's replicated here so "steam" starts at the SAME x as in
        // the active bar (otherwise, it's more to the left).
        anchors.leftMargin: Style.spacing.xs + Style.spacing.controlPaddingX
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        text: root.modelData.searchQuery || ""
        elide: Text.ElideRight
        color: Color.menu.selectedText
        font.family: Style.font.family
        font.pixelSize: Style.font.subtitle
      }
    }
  }
}

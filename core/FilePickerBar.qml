import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "../state"
import "../Utils.js" as Utils

// FilePickerBar - visual controls for the FileChooser portal session.
// Shows at the bottom of the window when PickerState.active is true.
Rectangle {
  id: pickerBar
  height: Style.spacing.controlHeight + Style.spacing.panelPadding * 2
  color: Color.menu.background
  border.color: Color.menu.border
  border.width: Style.spacing.hairline
  radius: Style.cornerRadius

  property Item selectionOps: null

  signal responseSubmitted(string requestId, int responseCode, var results)

  function submit() {
    var uris = []
    if (PickerState.mode === "save-file") {
      var name = saveFieldName.text.trim()
      if (name.length > 0) {
        uris.push("file://" + Utils.joinPath(NavState.currentPath, name))
      } else {
        return // don't submit empty name for save
      }
    } else if (PickerState.mode === "open-dir") {
      var selected = selectionOps.selectedEntries()
      if (selected.length > 0) {
        for (var i = 0; i < selected.length; i++) {
          if (selected[i].type === "dir") {
            uris.push("file://" + Utils.joinPath(NavState.currentPath, selected[i].name))
          }
        }
      }
      if (uris.length === 0) {
        uris.push("file://" + NavState.currentPath)
      }
    } else { // open-file
      var selected = selectionOps.selectedEntries()
      for (var i = 0; i < selected.length; i++) {
        uris.push("file://" + Utils.joinPath(NavState.currentPath, selected[i].name))
      }
      // If nothing is explicitly selected but there is a highlighted item, select it
      if (uris.length === 0 && SelectionState.selectedIndex >= 0 && SelectionState.selectedIndex < NavState.visibleEntries.length) {
        var entry = NavState.visibleEntries[SelectionState.selectedIndex]
        uris.push("file://" + Utils.joinPath(NavState.currentPath, entry.name))
      }
    }

    if (uris.length > 0) {
      if (!PickerState.multiple && uris.length > 1) {
        uris = [uris[0]]
      }
      var reqId = PickerState.requestId
      PickerState.active = false
      PickerState.requestId = ""
      responseSubmitted(reqId, 0, uris)
    }
  }

  function cancel() {
    var reqId = PickerState.requestId
    PickerState.active = false
    PickerState.requestId = ""
    responseSubmitted(reqId, 1, [])
  }

  // Monitor suggestedName to keep the TextField updated
  Connections {
    target: PickerState
    function onSuggestedNameChanged() {
      if (PickerState.mode === "save-file") {
        saveFieldName.text = PickerState.suggestedName
      }
    }
    function onActiveChanged() {
      if (PickerState.active && PickerState.mode === "save-file") {
        saveFieldName.text = PickerState.suggestedName
        saveFieldName.forceActiveFocus()
      }
    }
  }

  Row {
    id: leftRow
    anchors.left: parent.left
    anchors.leftMargin: Style.spacing.panelPadding
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.spacing.controlGap

    Text {
      id: modeLabel
      text: PickerState.mode === "save-file" ? "Save as:" : (PickerState.mode === "open-dir" ? "Choose folder:" : "Open:")
      color: Color.menu.text
      font.pixelSize: Style.font.body
      font.family: Style.font.family
      anchors.verticalCenter: parent.verticalCenter
    }

    TextField {
      id: saveFieldName
      visible: PickerState.mode === "save-file"
      width: 300
      anchors.verticalCenter: parent.verticalCenter
      placeholderText: "File name…"
      Accessible.role: Accessible.EditableText
      Accessible.name: "Save file name"
      onVisibleChanged: if (visible) { forceActiveFocus(); selectAll() }
      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          pickerBar.submit()
          event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
          pickerBar.cancel()
          event.accepted = true
        }
      }
    }
  }

  Row {
    id: rightRow
    anchors.right: parent.right
    anchors.rightMargin: Style.spacing.panelPadding
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.spacing.controlGap

    Button {
      text: "Cancel"
      bordered: true
      anchors.verticalCenter: parent.verticalCenter
      onClicked: pickerBar.cancel()
    }

    Button {
      text: PickerState.mode === "save-file" ? "Save" : (PickerState.mode === "open-dir" ? "Choose" : "Open")
      bordered: true
      anchors.verticalCenter: parent.verticalCenter
      onClicked: pickerBar.submit()
    }
  }
}

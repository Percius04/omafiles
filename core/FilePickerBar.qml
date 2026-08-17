import QtQuick
import QtQuick.Controls
import Omafiles.Backend as Backend
import qs.Commons
import qs.Ui
import "../state"
import "../shared/Utils.js" as Utils

// Visual controls for one FileChooser portal session.
Rectangle {
  id: pickerBar
  height: controlsColumn.implicitHeight + Style.spacing.panelPadding * 2
  color: Color.menu.background
  border.color: Color.menu.border
  border.width: Style.spacing.hairline
  radius: Style.cornerRadius

  signal responseSubmitted()

  function pathsMatchActiveFilter(paths) {
    if (PickerState.filters.length === 0 || PickerState.mode === "open-dir") return true
    var filter = PickerState.filters[PickerState.currentFilter]
    for (var i = 0; i < paths.length; i++)
      if (!Backend.MimeResolver.matchesFilter(paths[i], filter.rules)) return false
    return true
  }

  function submit() {
    var uris = []
    var paths = []
    if (PickerState.mode === "save-file") {
      var name = saveFieldName.text
      if (!Utils.validBasename(name)) return
      var savePath = Utils.joinPath(NavState.currentPath, name)
      paths.push(savePath)
      uris.push(Util.fileUrl(savePath))
    } else if (PickerState.mode === "save-files") {
      uris = Util.saveFilesResultUris(NavState.currentPath, PickerState.saveFiles)
      for (var fileIndex = 0; fileIndex < PickerState.saveFiles.length; fileIndex++)
        paths.push(Utils.joinPath(NavState.currentPath, PickerState.saveFiles[fileIndex]))
    } else if (PickerState.mode === "open-dir") {
      var selectedDirectories = SelectionState.selectedEntries()
      for (var dirIndex = 0; dirIndex < selectedDirectories.length; dirIndex++) {
        if (selectedDirectories[dirIndex].type === "dir") {
          var dirPath = Utils.joinPath(NavState.currentPath, selectedDirectories[dirIndex].name)
          paths.push(dirPath)
          uris.push(Util.fileUrl(dirPath))
        }
      }
      if (uris.length === 0) {
        paths.push(NavState.currentPath)
        uris.push(Util.fileUrl(NavState.currentPath))
      }
    } else {
      var selected = SelectionState.selectedEntries()
      for (var i = 0; i < selected.length; i++) {
        if (selected[i].type !== "dir") {
          var selectedPath = Utils.joinPath(NavState.currentPath, selected[i].name)
          paths.push(selectedPath)
          uris.push(Util.fileUrl(selectedPath))
        }
      }
      if (uris.length === 0 && SelectionState.selectedIndex >= 0
          && SelectionState.selectedIndex < NavState.visibleEntries.length) {
        var entry = NavState.visibleEntries[SelectionState.selectedIndex]
        if (entry.type !== "dir") {
          var highlightedPath = Utils.joinPath(NavState.currentPath, entry.name)
          paths.push(highlightedPath)
          uris.push(Util.fileUrl(highlightedPath))
        }
      }
    }

    if (uris.length === 0 || !pathsMatchActiveFilter(paths)) return
    if (PickerState.mode !== "save-files" && !PickerState.multiple && uris.length > 1)
      uris = [uris[0]]
    // PickerResponder keeps the blocking, sender-bound service call. Keep this
    // window open when the backend rejects the structured result.
    if (PickerResponder.submit(0, PickerState.resultMap(uris))) {
      PickerState.active = false
      responseSubmitted()
    }
  }

  function cancel() {
    if (PickerResponder.submit(1, PickerState.resultMap([]))) {
      PickerState.active = false
      responseSubmitted()
    }
  }

  Connections {
    target: PickerState
    function onSuggestedNameChanged() {
      if (PickerState.mode === "save-file") saveFieldName.text = PickerState.suggestedName
    }
    function onActiveChanged() {
      if (PickerState.active && PickerState.mode === "save-file") {
        saveFieldName.text = PickerState.suggestedName
        saveFieldName.forceActiveFocus()
      }
    }
  }

  Column {
    id: controlsColumn
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Style.spacing.panelPadding
    spacing: Style.spacing.controlGap

    Row {
      width: parent.width
      spacing: Style.spacing.controlGap

      Text {
        text: PickerState.mode === "save-file" ? "Save as:"
          : (PickerState.mode === "save-files" ? "Choose destination:"
          : (PickerState.mode === "open-dir" ? "Choose folder:" : "Open:"))
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
            pickerBar.submit(); event.accepted = true
          } else if (event.key === Qt.Key_Escape) {
            pickerBar.cancel(); event.accepted = true
          }
        }
      }

      Item { width: Math.max(0, parent.width - x - actionButtons.width); height: 1 }

      Row {
        id: actionButtons
        spacing: Style.spacing.controlGap
        Button { text: "Cancel"; bordered: true; onClicked: pickerBar.cancel() }
        Button {
          text: PickerState.mode === "save-file" ? "Save"
            : (PickerState.mode === "save-files" || PickerState.mode === "open-dir" ? "Choose" : "Open")
          bordered: true
          onClicked: pickerBar.submit()
        }
      }
    }

    Flickable {
      width: parent.width
      height: optionsRow.implicitHeight
      visible: PickerState.filters.length > 0 || PickerState.choices.length > 0
      contentWidth: optionsRow.implicitWidth
      contentHeight: optionsRow.implicitHeight
      clip: true

      Row {
        id: optionsRow
        spacing: Style.spacing.controlGap

        Row {
          visible: PickerState.filters.length > 0
          spacing: Style.spacing.controlGap
          Text { text: "File type:"; color: Color.menu.text; anchors.verticalCenter: parent.verticalCenter }
          ComboBox {
            id: filterCombo
            model: PickerState.filters
            textRole: "name"
            currentIndex: PickerState.currentFilter
            Accessible.name: "File type filter"
            onActivated: PickerState.currentFilter = currentIndex
          }
        }

        Repeater {
          model: PickerState.choices
          delegate: Row {
            required property var modelData
            property var choiceOptions: modelData.options.length > 0 ? modelData.options
              : [{ id: "false", label: "No" }, { id: "true", label: "Yes" }]
            spacing: Style.spacing.controlGap
            Text { text: modelData.label + ":"; color: Color.menu.text; anchors.verticalCenter: parent.verticalCenter }
            ComboBox {
              model: parent.choiceOptions
              textRole: "label"
              valueRole: "id"
              currentIndex: {
                var selected = String(PickerState.choiceSelections[modelData.id])
                for (var i = 0; i < parent.choiceOptions.length; i++)
                  if (String(parent.choiceOptions[i].id) === selected) return i
                return 0
              }
              Accessible.name: modelData.label
              onActivated: PickerState.setChoiceSelection(modelData.id,
                                                           String(parent.choiceOptions[currentIndex].id))
            }
          }
        }
      }
    }
  }
}

pragma Singleton
import QtQuick

// Holds the state of the active file chooser portal request.
QtObject {
  property bool active: false
  // Remains true after a successful response clears the visible picker. It
  // prevents this short-lived process from writing normal session state.
  property bool sessionActive: false
  property string mode: "open-file" // "open-file" | "open-dir" | "save-file" | "save-files"
  property bool multiple: false
  property string suggestedName: ""
  property var saveFiles: []
  property var filters: []
  property int currentFilter: -1
  property var choices: []
  property var choiceSelections: ({})

  function configureContract(newFilters, selectedFilter, newChoices) {
    filters = newFilters.slice()
    currentFilter = selectedFilter
    choices = newChoices.slice()
    var selections = {}
    for (var i = 0; i < choices.length; i++)
      selections[String(choices[i].id)] = String(choices[i].selected)
    choiceSelections = selections
  }

  function setChoiceSelection(choiceId, value) {
    var selections = {}
    var keys = Object.keys(choiceSelections)
    for (var i = 0; i < keys.length; i++)
      selections[keys[i]] = choiceSelections[keys[i]]
    selections[String(choiceId)] = String(value)
    choiceSelections = selections
  }

  function selectedChoicePairs() {
    var pairs = []
    for (var i = 0; i < choices.length; i++) {
      var id = String(choices[i].id)
      pairs.push([id, String(choiceSelections[id])])
    }
    return pairs
  }

  function resultMap(uris) {
    return {
      uris: uris.slice(),
      currentFilter: currentFilter,
      choices: selectedChoicePairs()
    }
  }

  function resetContract() {
    filters = []
    currentFilter = -1
    choices = []
    choiceSelections = ({})
  }
}

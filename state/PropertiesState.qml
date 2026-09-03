pragma Singleton
import QtQuick

// State of the Properties panel (size/permissions/owner/date) --
// ninth singleton of the state/ layer. dialogs/PropertiesPanel.qml is
// purely presentational (its own local `id: root`, fed by
// binding from core), so it does not need to import this
// directly. The loading itself (stat/du) stays in logic/PropertiesLoader.qml.
QtObject {
  property bool propertiesOpen: false
  property var propertiesEntry: null
  property string propertiesSize: ""
  property bool propertiesSizeLoading: false
  property string propertiesPerms: ""
  property string propertiesOwner: ""
  property string propertiesMtime: ""
  property string propertiesBtime: ""  // "" = filesystem reports no birth time
  // Race guard: showProperties()/showPropertiesForSelection() bump
  // this counter each time the panel is opened for a new item, and
  // record that number as the "owner" of the stat/du they launch. If the user
  // changes selection before a slow "du" of a large folder
  // finishes, the late response no longer matches propertiesRequestId
  // (which by then has already bumped) and is discarded instead of overwriting the
  // size of the item being looked at now with that of a different one.
  property int propertiesRequestId: 0
  property int _propertiesStatOwner: -1
  property int _propertiesDuOwner: -1
  // Multiple selection: no permissions/owner/date (it makes no sense to combine
  // several), only item count and total size.
  property bool propertiesMulti: false
  property int propertiesCount: 0
}

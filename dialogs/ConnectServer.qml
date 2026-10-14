import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../shared"

// "Connect to server" dialog (SFTP/SMB/WebDAV/FTP). Second
// component extracted from core -- a bit more coupled than
// ShortcutsHelp.qml (it has editable text + an intermediate "connecting"
// state with two different cancellations: close the dialog vs.
// abort only the current attempt), so it exposes signals instead of
// calling root functions directly. core is still the
// real owner of connectServerUri/networkConnecting/connectServerError.
//
// The modal wrapper (scrim + card + animation + padding) is
// shared/ModalSurface.qml, common to all dialogs.
Item {
  id: root

  property bool open: false
  property bool connecting: false
  property string uri: ""
  property string errorText: ""
  // Saved connection profiles (V1.1, headline #4) -- just the URIs, no
  // password (NetworkResolver's auth flow, below, is separate and never
  // feeds this list). Fed from core/DialogLayer.qml, same "purely
  // presentational, core owns the state" contract as everything else here.
  property var profiles: []

  // "Connect" pressed (Enter or button) -- the parent decides what to do with
  // the URI (save it + commitConnectToServer()).
  signal connectRequested(string uri)
  // A saved profile's remove ("x") was clicked.
  signal profileRemoveRequested(string uri)
  // Escape while there is an attempt in progress: abort ONLY the attempt,
  // the dialog stays open (like the "Cancel" button).
  signal cancelConnectingRequested()
  // Escape or click outside when there is NO attempt in progress: close the
  // whole dialog.
  signal closeRequested()
  // The text field stops being visible (dialog closed) -- the
  // parent is the one that knows which Item to return focus to (the list).
  signal focusReturnRequested()

    // When auth is requested, hide the URI helper and field
    property bool authRequested: false
    property string authMessage: ""
    property string authUser: ""

    // Auth submission
    signal authSubmitted(string user, string password, bool remember)

    ModalSurface {
      open: root.open
      maxWidth: Style.space(420)
      dismissable: !root.connecting
      onDismissed: root.closeRequested()

      Text {
        width: parent.width
        text: root.authRequested ? "Authentication Required" : "Connect to server"
        font.pixelSize: Style.font.title
        font.family: Style.font.family
        font.bold: true
        color: Commons.Color.menu.text
      }

      Text {
        width: parent.width
        visible: !root.authRequested
        text: "sftp://user@host/path · smb://server/share · dav(s)://host/path · ftp://host/path"
        font.pixelSize: Style.font.bodySmall
        font.family: Style.font.family
        color: Commons.Color.menu.text
        opacity: Style.emphasis.secondary
        wrapMode: Text.Wrap
      }

      Column {
        width: parent.width
        visible: !root.authRequested && root.profiles.length > 0
        spacing: Style.spacing.xs

        Repeater {
          model: root.profiles

          Row {
            id: profileRow
            required property string modelData
            width: parent.width
            spacing: Style.spacing.sm

            Text {
              width: parent.width - removeProfileButton.width - Style.spacing.sm
              text: profileRow.modelData
              font.pixelSize: Style.font.bodySmall
              font.family: Style.font.family
              color: Commons.Color.menu.text
              elide: Text.ElideMiddle
              MouseArea {
                anchors.fill: parent
                onClicked: connectServerField.text = profileRow.modelData
              }
            }

            Text {
              id: removeProfileButton
              text: "×"
              font.pixelSize: Style.font.bodySmall
              font.family: Style.font.family
              color: Commons.Color.menu.text
              opacity: Style.emphasis.secondary
              MouseArea {
                anchors.fill: parent
                onClicked: root.profileRemoveRequested(profileRow.modelData)
              }
            }
          }
        }
      }

      TextField {
        id: connectServerField
        width: parent.width
        visible: !root.authRequested
        Accessible.role: Accessible.EditableText
        Accessible.name: "Server address"
        text: root.uri
        enabled: !root.connecting
        onVisibleChanged: if (visible && !root.authRequested) { forceActiveFocus(); selectAll() } else if (!visible && !root.authRequested) root.focusReturnRequested()
        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.connectRequested(text)
            event.accepted = true
          } else if (event.key === Qt.Key_Escape) {
            if (root.connecting) root.cancelConnectingRequested()
            else root.closeRequested()
            event.accepted = true
          }
        }
      }

      // Authentication Fields
      Text {
        width: parent.width
        visible: root.authRequested
        text: root.authMessage
        font.pixelSize: Style.font.bodySmall
        font.family: Style.font.family
        color: Commons.Color.menu.text
        wrapMode: Text.Wrap
      }

      TextField {
        id: authUserField
        width: parent.width
        visible: root.authRequested
        placeholderText: "Username"
        text: root.authUser
        enabled: !root.connecting
        onVisibleChanged: if (visible) { forceActiveFocus(); selectAll() }
        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            authPasswordField.forceActiveFocus()
            event.accepted = true
          }
        }
      }

      TextField {
        id: authPasswordField
        width: parent.width
        visible: root.authRequested
        placeholderText: "Password"
        echoMode: TextInput.Password
        enabled: !root.connecting
        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.authSubmitted(authUserField.text, authPasswordField.text, rememberSessionCheckbox.checked)
            event.accepted = true
          }
        }
      }

      Row {
        visible: root.authRequested
        spacing: Style.spacing.sm
        Rectangle {
          id: rememberSessionCheckbox
          width: Style.space(20)
          height: Style.space(20)
          color: checked ? Commons.Color.accent : "transparent"
          border.color: Commons.Color.menu.border
          property bool checked: true
          MouseArea {
            anchors.fill: parent
            onClicked: rememberSessionCheckbox.checked = !rememberSessionCheckbox.checked
          }
          Text {
            anchors.centerIn: parent
            visible: rememberSessionCheckbox.checked
            text: "✓"
            color: Commons.Color.menu.background
            font.pixelSize: Style.font.bodySmall
          }
        }
        Text {
          text: "Remember for this session"
          font.pixelSize: Style.font.bodySmall
          color: Commons.Color.menu.text
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Text {
        width: parent.width
        visible: root.errorText.length > 0
        text: root.errorText
        font.pixelSize: Style.font.bodySmall
        font.family: Style.font.family
        color: Commons.Color.urgent
        wrapMode: Text.Wrap
      }

      Row {
        spacing: Style.spacing.sm

        Button {
          text: root.connecting ? "Connecting…" : (root.authRequested ? "Log In" : "Connect")
          bordered: true
          enabled: !root.connecting
          Accessible.role: Accessible.Button
          Accessible.name: text
          onClicked: {
            if (root.authRequested) {
              root.authSubmitted(authUserField.text, authPasswordField.text, rememberSessionCheckbox.checked)
            } else {
              root.connectRequested(connectServerField.text)
            }
          }
        }

        Button {
          text: "Cancel"
          // We always show cancel if we're connecting, or if we're asking for auth (to abort)
          visible: root.connecting || root.authRequested
          Accessible.role: Accessible.Button
          Accessible.name: text
          onClicked: {
            if (root.connecting || root.authRequested) root.cancelConnectingRequested()
            else root.closeRequested()
          }
        }
      }
    }
  }

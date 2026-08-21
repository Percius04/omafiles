import QtQuick
import QtMultimedia
import qs.Commons
import qs.Ui
import "../shared"

// Preview panel (Space). Eleventh component extracted from
// core -- purely read-only (no clicks of its own beyond
// "don't let the tap pass through to what's behind"), so unlike
// Sidebar.qml it doesn't even need a signal: everything that used to be
// calls to root.isImage(root.previewEntry)/etc. repeated several
// times across the file are now already-resolved booleans passed by the
// parent (which is still the only one that sees those functions).
Item {
  id: root

  property bool open: false
  property string entryName: ""
  property bool hasEntry: false
  property bool isImageEntry: false
  property bool isVideoEntry: false
  property bool isTextEntry: false
  property bool isPdfEntry: false
  property bool isAudioEntry: false
  property url imageSource: ""
  property url videoThumbSource: ""
  property url videoSource: ""
  property url audioSource: ""
  property string highlightedText: ""
  property string plainText: ""
  property url pdfImageSource: ""
  property var audioInfo: []
  property string fallbackSizeText: ""

  // Stops any playback in flight when the previewed entry changes (arrow-
  // key navigation to another file) -- without this, the previous video/
  // audio's sound would keep going under the new file's preview.
  onEntryNameChanged: {
    videoPlayer.stop()
    audioPlayer.stop()
  }

  BorderSurface {
    id: previewPanel
    visible: root.open
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.right: parent.right
    width: parent.width * 0.45 - Style.spacing.rowGap
    radius: Style.cornerRadius
    color: Color.menu.selectedBackground
    borderSpec: Border.flat(Color.menu.border, Style.normalBorderWidth)
    padding: Style.spacing.sm

    MouseArea { anchors.fill: parent; onClicked: {} }

    Column {
      id: previewCol
      anchors.fill: parent
      anchors.topMargin: previewPanel.contentTopInset
      anchors.rightMargin: previewPanel.contentRightInset
      anchors.bottomMargin: previewPanel.contentBottomInset
      anchors.leftMargin: previewPanel.contentLeftInset
      spacing: Style.spacing.sm

      Text {
        width: parent.width
        text: root.entryName
        font.pixelSize: Style.font.title
        font.family: Style.font.family
        font.bold: true
        color: Color.menu.text
        elide: Text.ElideMiddle
      }

      PanelSeparator { foreground: Color.menu.text; strength: 0.15 }

      Image {
        visible: root.isImageEntry
        width: parent.width
        height: parent.height - 60
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        cache: true
        source: root.isImageEntry ? root.imageSource : ""
      }

      // Inline video playback (V1.1, headline #3): the static thumbnail
      // stays as the poster shown before playback starts (avoids decoding
      // a stream just to open the preview panel); Video (QtMultimedia,
      // MediaPlayer+VideoOutput+AudioOutput in one) takes over once
      // "Play" is pressed. Reset on every entry change (onVideoSourceChanged
      // below) so arrow-keying to another file doesn't keep the previous
      // one's audio going. Deliberately basic (play/pause only) --
      // scrubbing/waveform/playlists/subtitles are out of scope, see the
      // v1.1 feature inventory's headline #3 MVP note.
      Item {
        id: videoBlock
        visible: root.isVideoEntry
        width: parent.width
        height: parent.height - 60

        Image {
          id: videoPoster
          visible: videoPlayer.playbackState !== MediaPlayer.PlayingState
          anchors.fill: parent
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          cache: true
          // No isVideoEntry guard needed here (cleanup pass): videoThumbSource
          // is already "" whenever isVideoEntry is false (same Utils.isVideo()
          // check computed once in panels/ActiveFileList.qml), so the ternary
          // was checking a condition the source already encodes.
          source: root.videoThumbSource
        }

        Video {
          id: videoPlayer
          visible: playbackState === MediaPlayer.PlayingState
          anchors.fill: parent
          fillMode: VideoOutput.PreserveAspectFit
          source: root.videoSource
        }

        Button {
          text: videoPlayer.playbackState === MediaPlayer.PlayingState ? "Pause" : "Play"
          bordered: true
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.spacing.sm
          Accessible.role: Accessible.Button
          Accessible.name: text
          onClicked: {
            if (videoPlayer.playbackState === MediaPlayer.PlayingState) videoPlayer.pause()
            else videoPlayer.play()
          }
        }
      }

      Flickable {
        visible: root.isTextEntry
        width: parent.width
        height: parent.height - 60
        clip: true
        contentWidth: width
        contentHeight: (root.highlightedText.length > 0 ? previewHighlightedItem : previewTextItem).implicitHeight

        // Syntax highlighting when native SyntaxHighlighter recognized the language.
        // Same Flickable/position as the plain Text below,
        // one of the two is always hidden.
        Text {
          id: previewHighlightedItem
          visible: root.highlightedText.length > 0
          width: parent.width
          textFormat: Text.RichText
          text: root.highlightedText
          font.pixelSize: Style.font.subtitle
          font.family: "monospace"
          color: Color.menu.text
          wrapMode: Text.Wrap
        }

        Text {
          id: previewTextItem
          visible: root.highlightedText.length === 0
          width: parent.width
          text: root.plainText || "(empty)"
          font.pixelSize: Style.font.subtitle
          font.family: "monospace"
          color: Color.menu.text
          wrapMode: Text.Wrap
        }
      }

      Image {
        visible: root.isPdfEntry
        width: parent.width
        height: parent.height - 60
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        cache: true
        source: root.isPdfEntry ? root.pdfImageSource : ""
      }

      // Inline audio playback (V1.1, headline #3) -- same basic play/pause-
      // only scope as the video block above, no VideoOutput needed (audio
      // files have no video track to render).
      Row {
        visible: root.isAudioEntry
        spacing: Style.spacing.sm

        MediaPlayer {
          id: audioPlayer
          // No isAudioEntry guard needed (cleanup pass): audioSource is
          // already "" whenever isAudioEntry is false, see the video
          // block's comment above.
          source: root.audioSource
          audioOutput: AudioOutput {}
        }

        Button {
          text: audioPlayer.playbackState === MediaPlayer.PlayingState ? "Pause" : "Play"
          bordered: true
          Accessible.role: Accessible.Button
          Accessible.name: text
          onClicked: {
            if (audioPlayer.playbackState === MediaPlayer.PlayingState) audioPlayer.pause()
            else audioPlayer.play()
          }
        }
      }

      Column {
        visible: root.isAudioEntry && root.audioInfo.length > 0
        width: parent.width
        spacing: Style.spacing.sm

        Repeater {
          model: root.audioInfo

          Row {
            required property var modelData
            width: parent.width
            spacing: Style.spacing.sm

            Text {
              // 84 didn't reach "Sample rate" (it stuck to
              // the value without a space, confirmed by measuring the
              // font's real glyph) -- 120 leaves plenty of margin
              // for any current label of this
              // table at the app's real font size.
              width: 120
              text: parent.modelData.label
              font.pixelSize: Style.font.subtitle
              font.family: Style.font.family
              color: Color.menu.text
              opacity: Style.emphasis.secondary
            }

            Text {
              width: parent.width - 120 - Style.spacing.sm
              text: parent.modelData.value
              font.pixelSize: Style.font.subtitle
              font.family: Style.font.family
              color: Color.menu.text
              elide: Text.ElideRight
            }
          }
        }
      }

      Column {
        visible: root.hasEntry && !root.isImageEntry && !root.isTextEntry
          && !root.isVideoEntry
          && !(root.isPdfEntry && root.pdfImageSource !== "")
          && !root.isAudioEntry
        width: parent.width
        spacing: Style.spacing.sm

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "No preview available"
          font.pixelSize: Style.font.title
          font.family: Style.font.family
          color: Color.menu.text
          opacity: Style.emphasis.muted
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "Press Enter to open with default app"
          font.pixelSize: Style.font.subtitle
          font.family: Style.font.family
          color: Color.menu.text
          opacity: Style.emphasis.secondary
        }
      }

    }

    // OUTSIDE the Column on purpose. EmptyState positions itself with
    // anchors.centerIn, and an anchored child inside a positioner doesn't
    // just misplace itself -- the Column logs "Column will not function" and
    // PERMANENTLY stops laying out its children. Once "No file selected" had
    // been shown once, every later text preview rendered its Flickable at
    // y:0, painting the file's first line on top of the filename header.
    EmptyState {
      visible: !root.hasEntry
      centerOn: previewCol
      message: "No file selected"
      subMessage: "Select a file to preview its contents"
    }
  }
}

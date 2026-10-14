import QtQuick
import QtMultimedia
import qs.Commons
import qs.Commons as Commons
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

  // Read-only, for the selfcheck regression guarding the lazy-load fix
  // below (V1.2 startup audit) -- nothing else reads these from outside.
  readonly property alias videoLoaderActive: videoLoader.active
  readonly property alias audioLoaderActive: audioLoader.active
  // Exposed for the selfcheck regression guarding the title/content
  // overlap fix below (P2.x, v1.2-dev): nothing else reads these.
  readonly property alias titleTextItem: titleText
  readonly property alias contentAreaItem: contentArea

  // Stops any playback in flight when the previewed entry changes (arrow-
  // key navigation to another file) -- without this, the previous video/
  // audio's sound would keep going under the new file's preview.
  onEntryNameChanged: {
    if (videoLoader.item) videoLoader.item.stop()
    if (audioLoader.item) audioLoader.item.player.stop()
  }

  // V1.2 startup audit (docs/audits/V1_2_STARTUP_PERFORMANCE_REPORT.md):
  // QtMultimedia's MediaPlayer does expensive one-time backend init
  // (measured ~900ms of the ~1050ms engine.load() spent constructing the
  // WHOLE app QML tree) the first time ANY MediaPlayer-family object is
  // constructed in the process -- and `Video`/`MediaPlayer` below used to
  // be plain, always-present children, so every single launch paid that
  // cost regardless of whether the user ever previews a video or audio
  // file. videoLoader/audioLoader defer that construction to the first
  // real need. "Touched" latches permanently once true (rather than
  // tracking isVideoEntry/isAudioEntry directly) so browsing away to a
  // non-media file doesn't tear the player down and re-pay the init cost
  // on the NEXT video/audio preview -- same "stays alive for the rest of
  // the session" lifetime the always-present objects had before, just
  // deferred past startup.
  property bool _videoTouched: false
  property bool _audioTouched: false
  onIsVideoEntryChanged: if (isVideoEntry) _videoTouched = true
  onIsAudioEntryChanged: if (isAudioEntry) _audioTouched = true
  Component.onCompleted: {
    if (isVideoEntry) _videoTouched = true
    if (isAudioEntry) _audioTouched = true
  }

  BorderSurface {
    id: previewPanel
    visible: root.open
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.right: parent.right
    width: parent.width * 0.45 - Style.spacing.rowGap
    radius: Style.cornerRadius
    color: Commons.Color.menu.selectedBackground
    borderSpec: Border.flat(Commons.Color.menu.border, Style.normalBorderWidth)
    padding: Style.spacing.sm

    MouseArea { anchors.fill: parent; onClicked: {} }

    Column {
      anchors.fill: parent
      anchors.topMargin: previewPanel.contentTopInset
      anchors.rightMargin: previewPanel.contentRightInset
      anchors.bottomMargin: previewPanel.contentBottomInset
      anchors.leftMargin: previewPanel.contentLeftInset
      spacing: Style.spacing.sm

      Text {
        id: titleText
        width: parent.width
        text: root.entryName
        font.pixelSize: Style.font.title
        font.family: Style.font.family
        font.bold: true
        color: Commons.Color.menu.text
        elide: Text.ElideMiddle
      }

      PanelSeparator { foreground: Commons.Color.menu.text; strength: 0.15 }

      // Everything below is exactly ONE of several mutually-exclusive
      // content kinds (image/video/text/pdf/audio/no-preview/empty),
      // gated by root.isXEntry -- previously these were direct siblings of
      // the title/separator INSIDE THE SAME Column above. That's the
      // layout Column is meant for (each visible child stacked after the
      // previous one), but that model breaks down for content that's
      // mutually exclusive rather than always co-visible: opening the
      // preview of a file with no matching kind flips several of these
      // isXEntry flags in the SAME tick (the new kind's flag true, the
      // OLD previewed entry's kind flag false), and Column's positioner
      // does not reliably reflow when multiple children change visibility
      // simultaneously -- confirmed empirically (dumped real y/height:
      // the "No preview available" block landed at y=0, height=0,
      // overlapping the title, while the now-hidden previous block stayed
      // frozen at its old position instead of being removed from the
      // flow). A plain Item (not a positioner) sidesteps the whole bug
      // class: every content kind below anchors independently within it,
      // with no inter-sibling stacking to get wrong since only one is
      // ever visible at a time.
      Item {
        id: contentArea
        width: parent.width
        height: parent.height - 60

        Image {
          visible: root.isImageEntry
          anchors.fill: parent
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
          anchors.fill: parent

        Image {
          id: videoPoster
          visible: !videoLoader.item || videoLoader.item.playbackState !== MediaPlayer.PlayingState
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

        // Lazy: see root._videoTouched's doc comment above.
        Loader {
          id: videoLoader
          anchors.fill: parent
          active: root._videoTouched
          sourceComponent: Component {
            Video {
              visible: playbackState === MediaPlayer.PlayingState
              anchors.fill: parent
              fillMode: VideoOutput.PreserveAspectFit
              source: root.videoSource
            }
          }
        }

        Button {
          text: (videoLoader.item && videoLoader.item.playbackState === MediaPlayer.PlayingState) ? "Pause" : "Play"
          bordered: true
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.spacing.sm
          Accessible.role: Accessible.Button
          Accessible.name: text
          onClicked: {
            if (!videoLoader.item) return
            if (videoLoader.item.playbackState === MediaPlayer.PlayingState) videoLoader.item.pause()
            else videoLoader.item.play()
          }
        }
      }

      Flickable {
        visible: root.isTextEntry
        anchors.fill: parent
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
          color: Commons.Color.menu.text
          wrapMode: Text.Wrap
        }

        Text {
          id: previewTextItem
          visible: root.highlightedText.length === 0
          width: parent.width
          text: root.plainText || "(empty)"
          font.pixelSize: Style.font.subtitle
          font.family: "monospace"
          color: Commons.Color.menu.text
          wrapMode: Text.Wrap
        }
      }

      Image {
        visible: root.isPdfEntry
        anchors.fill: parent
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        cache: true
        source: root.isPdfEntry ? root.pdfImageSource : ""
      }

      // Inline audio playback (V1.1, headline #3) -- same basic play/pause-
      // only scope as the video block above, no VideoOutput needed (audio
      // files have no video track to render). The Row (play button) and
      // the Column (metadata table) below are wrapped together in ONE
      // Column instead of being two more top-level contentArea children,
      // since -- unlike the mutually-exclusive content kinds around them
      // -- these two are never independently toggled: both are driven by
      // isAudioEntry (the table adds `&& audioInfo.length > 0` on top),
      // so there's no multi-sibling-visibility-changing-at-once scenario
      // here for Column's positioner to mishandle.
      Column {
        visible: root.isAudioEntry
        anchors.top: parent.top
        width: parent.width
        spacing: Style.spacing.sm

        Row {
          spacing: Style.spacing.sm

          // Lazy: see root._audioTouched's doc comment above. Wrapped in an
          // Item (rather than loading the bare MediaPlayer as the Loader's
          // root) so `Loader.item` -- typed for the common Item case --
          // reliably exposes the player via the alias regardless of Qt
          // version quirks around loading a non-visual root type directly.
          Loader {
            id: audioLoader
            active: root._audioTouched
            sourceComponent: Component {
              Item {
                property alias player: audioPlayerInner
                // No isAudioEntry guard needed (cleanup pass): audioSource is
                // already "" whenever isAudioEntry is false, see the video
                // block's comment above.
                MediaPlayer {
                  id: audioPlayerInner
                  source: root.audioSource
                  audioOutput: AudioOutput {}
                }
              }
            }
          }

          Button {
            text: (audioLoader.item && audioLoader.item.player.playbackState === MediaPlayer.PlayingState) ? "Pause" : "Play"
            bordered: true
            Accessible.role: Accessible.Button
            Accessible.name: text
            onClicked: {
              if (!audioLoader.item) return
              if (audioLoader.item.player.playbackState === MediaPlayer.PlayingState) audioLoader.item.player.pause()
              else audioLoader.item.player.play()
            }
          }
        }

        Column {
          visible: root.audioInfo.length > 0
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
                color: Commons.Color.menu.text
                opacity: Style.emphasis.secondary
              }

              Text {
                width: parent.width - 120 - Style.spacing.sm
                text: parent.modelData.value
                font.pixelSize: Style.font.subtitle
                font.family: Style.font.family
                color: Commons.Color.menu.text
                elide: Text.ElideRight
              }
            }
          }
        }
      }

      Column {
        visible: root.hasEntry && !root.isImageEntry && !root.isTextEntry
          && !root.isVideoEntry
          && !(root.isPdfEntry && root.pdfImageSource !== "")
          && !root.isAudioEntry
        anchors.top: parent.top
        width: parent.width
        spacing: Style.spacing.sm

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "No preview available"
          font.pixelSize: Style.font.title
          font.family: Style.font.family
          color: Commons.Color.menu.text
          opacity: Style.emphasis.muted
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "Press Enter to open with default app"
          font.pixelSize: Style.font.subtitle
          font.family: Style.font.family
          color: Commons.Color.menu.text
          opacity: Style.emphasis.secondary
        }
      }

      EmptyState {
        visible: !root.hasEntry
        centerOn: parent
        message: "No file selected"
        subMessage: "Select a file to preview its contents"
      }
      }
    }
  }
}

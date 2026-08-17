#pragma once

#include <QObject>
#include <QString>
#include <QVariantMap>
#include <memory>
#include <mutex>
#include <qqmlregistration.h>

// C++ backend for previews. Replaces the preview panel's
// shell processes: the text READING (previously `head -c 4000`)
// and the METADATA. The scaled image and the PDF are still provided by
// ThumbnailProvider at a preview size -- "cache reusing
// ThumbnailProvider when possible", without duplicating render/cache. The
// highlighting (Pygments), the video thumbnail (ffmpegthumbnailer) and the
// audio metadata (ffprobe) stay in shell for now.
//
// (Omafiles.Backend.PreviewProvider).
class PreviewProvider : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON

public:
  explicit PreviewProvider(QObject *parent = nullptr);
  ~PreviewProvider() override;

  // File metadata (QFileInfo + QMimeDatabase). Cheap and synchronous:
  // { name, path, size, mtime, mime, permissions ("rwxr-x---"...),
  //   readable, writable, executable }.
  Q_INVOKABLE QVariantMap info(const QString &path);

  // Reads the text of `path` (up to `maxBytes`, 256 KB by default) on a pool
  // thread and delivers it via textReady(). Cancellation by generation: if the
  // user changes selection (another call), the previous result is
  // discarded and does not repopulate the panel. It never blocks the UI thread.
  Q_INVOKABLE void requestText(const QString &path, int maxBytes = 262144);

  // Highlights code in-process using SyntaxHighlighter.
  Q_INVOKABLE QString highlightCode(const QString &source, const QString &extensionOrFilename);

  // Checks if the file extension supports syntax highlighting.
  Q_INVOKABLE bool isHighlightable(const QString &extensionOrFilename);

  // Extracts audio/video metadata in-process (synchronous lookup).
  Q_INVOKABLE QVariantList audioMetadata(const QString &path);

  // Asynchronously extracts audio metadata on a thread pool with cancellation.
  Q_INVOKABLE void requestAudio(const QString &path);

signals:
  // content = read text; highlighted = HTML with inline syntax styling;
  // encoding = "utf-8" | "latin1"; bytes = read; lines = approximate number
  // of lines; truncated = whether the file was larger than maxBytes.
  void textReady(const QString &path, const QString &content,
                 const QString &highlighted, const QString &encoding,
                 qint64 bytes, int lines, bool truncated);

  // info = array of { label, value } metadata items.
  void audioReady(const QString &path, const QVariantList &info);

private:
  // Workers retain this control block rather than dereferencing the provider.
  // A worker holds the mutex while it queues delivery, so destruction cannot
  // race invokeMethod's target use. Queued delivery checks life and generation
  // under the mutex, then unlocks before emitting on the provider's thread.
  // Generations stay independent from the provider's lifetime.
  struct Life {
    std::mutex mutex;
    bool alive = true;
    quint64 textGeneration = 0;
    quint64 audioGeneration = 0;
  };
  std::shared_ptr<Life> m_life = std::make_shared<Life>();
};

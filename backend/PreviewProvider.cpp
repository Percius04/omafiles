#include "PreviewProvider.h"
#include "MediaInfo.h"
#include "SyntaxHighlighter.h"

#include <QDateTime>
#include <QFile>
#include <QFileInfo>
#include <QMimeDatabase>
#include <QRunnable>
#include <QStringConverter>
#include <QThreadPool>

PreviewProvider::PreviewProvider(QObject *parent) : QObject(parent) {}

PreviewProvider::~PreviewProvider() {
  std::lock_guard<std::mutex> lock(m_life->mutex);
  m_life->alive = false;
}

QString PreviewProvider::highlightCode(const QString &source, const QString &extensionOrFilename) {
  return SyntaxHighlighter::highlight(source, extensionOrFilename);
}

bool PreviewProvider::isHighlightable(const QString &extensionOrFilename) {
  return SyntaxHighlighter::isSupported(extensionOrFilename);
}

QVariantList PreviewProvider::audioMetadata(const QString &path) {
  const MediaInfo::Metadata meta = MediaInfo::extract(path);
  return MediaInfo::toVariantList(meta);
}

void PreviewProvider::requestAudio(const QString &path) {
  auto life = m_life;
  quint64 generation;
  {
    std::lock_guard<std::mutex> lock(life->mutex);
    generation = ++life->audioGeneration;
  }
  PreviewProvider *target = this;
  QThreadPool::globalInstance()->start(QRunnable::create(
      [target, life, path, generation]() {
        const MediaInfo::Metadata meta = MediaInfo::extract(path);
        const QVariantList info = MediaInfo::toVariantList(meta);

        std::lock_guard<std::mutex> lock(life->mutex);
        if (!life->alive || generation != life->audioGeneration)
          return;
        QMetaObject::invokeMethod(
            target,
            [target, life, path, info, generation]() {
              {
                std::lock_guard<std::mutex> deliveryLock(life->mutex);
                if (!life->alive || generation != life->audioGeneration)
                  return;
              }
              emit target->audioReady(path, info);
            },
            Qt::QueuedConnection);
      }));
}

QVariantMap PreviewProvider::info(const QString &path) {
  const QFileInfo fi(path);
  QVariantMap m;
  m[QStringLiteral("name")] = fi.fileName();
  m[QStringLiteral("path")] = fi.absoluteFilePath();
  m[QStringLiteral("size")] = static_cast<qint64>(fi.size());
  m[QStringLiteral("mtime")] =
      static_cast<qint64>(fi.lastModified().toSecsSinceEpoch());

  // MIME by content + extension (opens and reads a small header; cheap
  // for a single selected file).
  static QMimeDatabase db;
  m[QStringLiteral("mime")] = db.mimeTypeForFile(fi).name();

  // Basic owner permissions as an "rwx" string.
  const QFileDevice::Permissions p = fi.permissions();
  QString perms;
  perms += (p & QFileDevice::ReadOwner) ? QLatin1Char('r') : QLatin1Char('-');
  perms += (p & QFileDevice::WriteOwner) ? QLatin1Char('w') : QLatin1Char('-');
  perms += (p & QFileDevice::ExeOwner) ? QLatin1Char('x') : QLatin1Char('-');
  m[QStringLiteral("permissions")] = perms;
  m[QStringLiteral("readable")] = fi.isReadable();
  m[QStringLiteral("writable")] = fi.isWritable();
  m[QStringLiteral("executable")] = fi.isExecutable();
  return m;
}

void PreviewProvider::requestText(const QString &path, int maxBytes) {
  auto life = m_life;
  quint64 generation;
  {
    std::lock_guard<std::mutex> lock(life->mutex);
    generation = ++life->textGeneration;
  }
  PreviewProvider *target = this;
  QThreadPool::globalInstance()->start(QRunnable::create(
      [target, life, path, maxBytes, generation]() {
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly))
          return; // unreadable: does not emit (the panel keeps the previous/empty state)

        const qint64 total = file.size();
        const QByteArray raw = file.read(maxBytes);
        file.close();
        const bool truncated = total > maxBytes;

        // Encoding detection: tries UTF-8; if invalid, Latin-1.
        QStringDecoder dec(QStringConverter::Utf8,
                           QStringConverter::Flag::Stateless);
        QString content = dec.decode(raw);
        QString encoding;
        if (dec.hasError()) {
          content = QString::fromLatin1(raw);
          encoding = QStringLiteral("latin1");
        } else {
          encoding = QStringLiteral("utf-8");
        }

        const int lines = static_cast<int>(content.count(QLatin1Char('\n'))) + 1;
        const qint64 bytes = raw.size();

        // Native in-process syntax highlighting on the background worker thread.
        QString highlighted;
        if (SyntaxHighlighter::isSupported(path)) {
          highlighted = SyntaxHighlighter::highlight(content, path);
        }

        std::lock_guard<std::mutex> lock(life->mutex);
        if (!life->alive || generation != life->textGeneration)
          return;
        QMetaObject::invokeMethod(
            target,
            [target, life, path, content, highlighted, encoding, bytes, lines,
             truncated, generation]() {
              {
                std::lock_guard<std::mutex> deliveryLock(life->mutex);
                if (!life->alive || generation != life->textGeneration)
                  return;
              }
              emit target->textReady(path, content, highlighted, encoding, bytes,
                                     lines, truncated);
            },
            Qt::QueuedConnection);
      }));
}

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
  // Marks the object as dead under the lock: a worker that has not yet
  // delivered will see alive=false and will not touch this already-destroyed
  // object.
  std::lock_guard<std::mutex> lk(m_life->mtx);
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
  const quint64 gen = ++m_audioGen;
  auto life = m_life; // copy of the control block, outlives the singleton
  QThreadPool::globalInstance()->start(QRunnable::create(
      [this, life, path, gen]() {
        const MediaInfo::Metadata meta = MediaInfo::extract(path);
        const QVariantList info = MediaInfo::toVariantList(meta);

        // Safe delivery: the destructor takes this same lock, so either we see
        // alive=false (and do not touch the dead singleton) or we hold it and
        // the destructor waits for us to release.
        std::lock_guard<std::mutex> lk(life->mtx);
        if (!life->alive)
          return;
        QMetaObject::invokeMethod(
            this,
            [this, path, info, gen]() {
              if (gen != m_audioGen)
                return;
              emit audioReady(path, info);
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
  const quint64 gen = ++m_gen;
  auto life = m_life; // copy of the control block, outlives the singleton
  QThreadPool::globalInstance()->start(QRunnable::create(
      [this, life, path, maxBytes, gen]() {
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

        // Safe delivery: see requestAudio() / the Life guard in the header.
        std::lock_guard<std::mutex> lk(life->mtx);
        if (!life->alive)
          return;
        QMetaObject::invokeMethod(
            this,
            [this, path, content, highlighted, encoding, bytes, lines, truncated, gen]() {
              // Cancellation: discard if another preview was already requested after.
              if (gen != m_gen)
                return;
              emit textReady(path, content, highlighted, encoding, bytes, lines, truncated);
            },
            Qt::QueuedConnection);
      }));
}

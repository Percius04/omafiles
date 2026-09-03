#include "SearchWorker.h"

#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFileInfo>
#include <QRunnable>
#include <QThreadPool>
#include <QVariantMap>

namespace {
// Seconds since the epoch, 0 where the filesystem reports no birth time --
// the same contract as DirectoryModel::Entry::btime.
qint64 birthSecs(const QFileInfo &fi) {
  const QDateTime b = fi.birthTime();
  return b.isValid() ? static_cast<qint64>(b.toSecsSinceEpoch()) : 0;
}
} // namespace

SearchWorker::SearchWorker(QObject *parent) : QObject(parent) {}

SearchWorker::~SearchWorker() {
  std::lock_guard<std::mutex> lk(m_life->mtx);
  m_life->alive = false;
}

void SearchWorker::cancel() { m_gen->fetch_add(1); }

void SearchWorker::search(const QString &root, const QString &query,
                          bool showHidden) {
  // Invalidates any previous search and opens this one's generation.
  const quint64 gen = m_gen->fetch_add(1) + 1;
  if (query.isEmpty())
    return;

  auto life = m_life;
  auto genPtr = m_gen; // shared_ptr copy: `this`-independent, see m_gen's doc comment
  const QString rootPath = root;
  // Phase 27 (PERF_AUDIT_RC1): the query is NOT lowercased to then do
  // fileName().toLower().contains(q) -> that allocated a new QString
  // per scanned file (100k allocations on a large tree). It is
  // compared with Qt::CaseInsensitive, which does the case-folding without
  // materializing the lowercased name.
  const QString q = query;

  QThreadPool::globalInstance()->start(QRunnable::create([this, life, genPtr, gen,
                                                          rootPath, q,
                                                          showHidden]() {
    // Without QDir::Hidden in the filter, QDirIterator does NOT emit hidden
    // entries NOR recurse into hidden folders -- equivalent to the
    // `-not -path './.*' -not -path '*/.*'` of the script.
    QDir::Filters filters = QDir::AllEntries | QDir::NoDotAndDotDot;
    if (showHidden)
      filters |= QDir::Hidden;

    const QDir base(rootPath);
    QDirIterator it(rootPath, filters, QDirIterator::Subdirectories);
    QVariantList out;
    while (it.hasNext()) {
      // Cancelled or superseded by another search -> abort without emitting.
      if (genPtr->load() != gen)
        return;
      it.next();
      const QFileInfo fi = it.fileInfo();
      if (!fi.fileName().contains(q, Qt::CaseInsensitive))
        continue;
      const bool isDir = fi.isDir();
      QVariantMap e;
      e[QStringLiteral("type")] =
          isDir ? QStringLiteral("dir") : QStringLiteral("file");
      // Path relative to root (same "name" that the script produced).
      e[QStringLiteral("name")] =
          base.relativeFilePath(fi.absoluteFilePath());
      e[QStringLiteral("size")] =
          isDir ? qint64(0) : static_cast<qint64>(fi.size());
      e[QStringLiteral("mtime")] =
          static_cast<qint64>(fi.lastModified().toSecsSinceEpoch());
      e[QStringLiteral("btime")] = birthSecs(fi);
      e[QStringLiteral("link")] = QString();
      out.append(e);
      // Cap of 201: the 201st only serves to know there were more than 200.
      if (out.size() >= 201)
        break;
    }
    const bool truncated = out.size() > 200;
    if (truncated)
      out.erase(out.begin() + 200, out.end());

    // Safe delivery (P0 concurrency audit, forensic audit 2026-08-16): the
    // alive/generation checks now happen BEFORE invokeMethod is called, not
    // inside the deferred functor -- calling QMetaObject::invokeMethod(this,
    // ...) at all needs to dereference `this` (to find its thread affinity)
    // regardless of what the deferred functor later does, so it must never
    // be reached once the object might already be dead. Holding `life->mtx`
    // across the call blocks the destructor (which needs the same lock)
    // until we're done, exactly like FileOperations/DirectoryModel.
    std::lock_guard<std::mutex> lk(life->mtx);
    if (!life->alive)
      return;
    if (genPtr->load() != gen)
      return; // superseded while delivering
    QMetaObject::invokeMethod(
        this, [this, out, truncated]() { emit results(out, truncated); },
        Qt::QueuedConnection);
  }));
}

void SearchWorker::searchContent(const QString &root, const QString &query,
                                 bool showHidden) {
  const quint64 gen = m_gen->fetch_add(1) + 1;
  if (query.isEmpty())
    return;

  auto life = m_life;
  auto genPtr = m_gen; // shared_ptr copy: `this`-independent, see m_gen's doc comment
  const QString rootPath = root;
  const QString q = query;

  QThreadPool::globalInstance()->start(QRunnable::create([this, life, genPtr, gen,
                                                          rootPath, q,
                                                          showHidden]() {
    QDir::Filters filters = QDir::Files | QDir::NoDotAndDotDot;
    if (showHidden)
      filters |= QDir::Hidden;

    QDirIterator it(rootPath, filters, QDirIterator::Subdirectories);
    QVariantList out;

    constexpr qint64 kMaxFileSize = 5LL * 1024 * 1024; // 5 MB limit

    while (it.hasNext()) {
      if (genPtr->load() != gen)
        return;

      it.next();
      const QFileInfo fi = it.fileInfo();

      // Skip non-files, empty files, or oversized files
      if (!fi.isFile() || fi.size() > kMaxFileSize || fi.size() == 0)
        continue;

      // Ignore common non-text media extensions
      const QString ext = fi.suffix().toLower();
      if (ext == QLatin1String("png") || ext == QLatin1String("jpg") ||
          ext == QLatin1String("jpeg") || ext == QLatin1String("gif") ||
          ext == QLatin1String("webp") || ext == QLatin1String("mp3") ||
          ext == QLatin1String("mp4") || ext == QLatin1String("mkv") ||
          ext == QLatin1String("avi") || ext == QLatin1String("flac") ||
          ext == QLatin1String("zip") || ext == QLatin1String("tar") ||
          ext == QLatin1String("gz") || ext == QLatin1String("xz") ||
          ext == QLatin1String("pdf") || ext == QLatin1String("iso")) {
        continue;
      }

      QFile file(fi.absoluteFilePath());
      if (!file.open(QIODevice::ReadOnly))
        continue;

      // Binary heuristic: check first 512 bytes for null byte
      const QByteArray sample = file.read(512);
      if (sample.contains('\0')) {
        file.close();
        continue;
      }

      file.seek(0);
      QTextStream in(&file);
      int lineNo = 0;

      while (!in.atEnd()) {
        if (genPtr->load() != gen) {
          file.close();
          return;
        }

        const QString line = in.readLine();
        ++lineNo;

        if (line.contains(q, Qt::CaseInsensitive)) {
          QString snippet = line.simplified();
          if (snippet.size() > 200) {
            snippet = snippet.left(200);
          }

          QVariantMap e;
          e[QStringLiteral("type")] = QStringLiteral("file");
          e[QStringLiteral("name")] = fi.fileName();
          e[QStringLiteral("path")] = fi.absoluteFilePath();
          e[QStringLiteral("parent")] = fi.absolutePath();
          e[QStringLiteral("line")] = lineNo;
          e[QStringLiteral("snippet")] = snippet;
          e[QStringLiteral("size")] = static_cast<qint64>(fi.size());
          e[QStringLiteral("mtime")] =
              static_cast<qint64>(fi.lastModified().toSecsSinceEpoch());
          e[QStringLiteral("btime")] = birthSecs(fi);
          e[QStringLiteral("link")] = QString();
          out.append(e);

          if (out.size() >= 201)
            break;
        }
      }

      file.close();
      if (out.size() >= 201)
        break;
    }

    const bool truncated = out.size() > 200;
    if (truncated)
      out.erase(out.begin() + 200, out.end());

    // Safe delivery -- see the identical comment in search() above.
    std::lock_guard<std::mutex> lk(life->mtx);
    if (!life->alive)
      return;
    if (genPtr->load() != gen)
      return;
    QMetaObject::invokeMethod(
        this, [this, out, truncated]() { emit results(out, truncated); },
        Qt::QueuedConnection);
  }));
}

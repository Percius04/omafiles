#include "SearchWorker.h"

#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QRunnable>
#include <QThreadPool>
#include <QVariantMap>
#include <algorithm>

#ifdef OMAFILES_SEARCH_TEST_GATE
// Compile-only native test scheduling seam; absent from the application/plugin.
extern void searchTraversalGate(const QString &path);
#endif

SearchWorker::SearchWorker(QObject *parent) : QObject(parent) {}

SearchWorker::~SearchWorker() {
  std::lock_guard<std::mutex> lk(m_life->mtx);
  m_life->alive = false;
  m_gen->fetch_add(
      1); // stop traversal; also fence reentrant snapshot receivers
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
    struct Match {
      QFileInfo info;
      int score;
    };
    QList<Match> best;
    bool truncated = false;
    const auto less = [](const Match &a, const Match &b) {
      if (a.score != b.score)
        return a.score < b.score;
      const QString ap = a.info.absoluteFilePath(),
                    bp = b.info.absoluteFilePath();
      if (ap.size() != bp.size())
        return ap.size() < bp.size();
      const int nameOrder =
          a.info.fileName().localeAwareCompare(b.info.fileName());
      return nameOrder ? nameOrder < 0 : ap < bp;
    };
    // Explicit traversal prunes cache/dependency contents, even with hidden
    // files enabled. Never follow directory symlinks outside the local
    // scope.
    const QStringList noise = {
        QStringLiteral("node_modules"), QStringLiteral(".cache"),
        QStringLiteral(".git"),         QStringLiteral(".pnpm"),
        QStringLiteral(".cargo"),       QStringLiteral(".rustup")};
    // Publish root matches immediately, then at most ten intermediate
    // snapshots per second. Every queued snapshot is fenced both here and
    // on dispatch.
    const auto publish = [&](bool complete) {
      QVariantList out;
      for (const auto &match : best) {
        const QFileInfo &fi = match.info;
        const bool isDir = fi.isDir();
        QVariantMap e;
        e[QStringLiteral("type")] =
            isDir ? QStringLiteral("dir") : QStringLiteral("file");
        // Keep the existing native relative-name API; SearchBackend makes
        // paths absolute when combining these entries with the global
        // index.
        e[QStringLiteral("name")] =
            base.relativeFilePath(fi.absoluteFilePath());
        e[QStringLiteral("size")] =
            isDir ? qint64(0) : static_cast<qint64>(fi.size());
        e[QStringLiteral("mtime")] =
            static_cast<qint64>(fi.lastModified().toSecsSinceEpoch());
        e[QStringLiteral("link")] = QString();
        out.append(e);
      }

      // Safe delivery (P0 concurrency audit, forensic audit 2026-08-16):
      // the alive/generation checks now happen BEFORE invokeMethod is
      // called, not inside the deferred functor -- calling
      // QMetaObject::invokeMethod(this,
      // ...) at all needs to dereference `this` (to find its thread
      // affinity) regardless of what the deferred functor later does, so it
      // must never be reached once the object might already be dead.
      // Holding `life->mtx` across the call blocks the destructor (which
      // needs the same lock) until we're done, exactly like
      // FileOperations/DirectoryModel.
      std::lock_guard<std::mutex> lk(life->mtx);
      if (!life->alive)
        return;
      if (genPtr->load() != gen)
        return; // superseded while delivering
      QMetaObject::invokeMethod(
          this,
          [this, genPtr, gen, out, truncated, complete]() {
            // A newer search/cancel can run after enqueue and before
            // delivery.
            if (genPtr->load() != gen)
              return;
            emit snapshot(out, truncated, complete);
            // A snapshot receiver can synchronously cancel/start another
            // query.
            if (complete && genPtr->load() == gen)
              emit results(out, truncated);
          },
          Qt::QueuedConnection);
    };
    QElapsedTimer publicationClock;
    publicationClock.start();
    QStringList pending{rootPath};
    while (!pending.isEmpty()) {
      if (genPtr->load() != gen)
        return;
      const QString directory =
          pending.takeFirst(); // breadth first: shallow Downloads is not
                               // behind a deep dev tree
#ifdef OMAFILES_SEARCH_TEST_GATE
      searchTraversalGate(directory);
#endif
      QDirIterator it(directory, filters);
      while (it.hasNext()) {
        if (genPtr->load() != gen)
          return;
        it.next();
        const QFileInfo fi = it.fileInfo();
        if (fi.isDir() && !fi.isSymLink() && !noise.contains(fi.fileName()))
          pending.append(fi.absoluteFilePath());
        if (publicationClock.elapsed() >= 100) {
          publish(false);
          publicationClock.restart();
        }
        const QString name = fi.fileName();
        if (!name.contains(q, Qt::CaseInsensitive))
          continue;
        const int score = name.compare(q, Qt::CaseInsensitive) == 0 ? 0
                          : name.startsWith(q, Qt::CaseInsensitive) ? 1
                                                                    : 2;
        const Match match{fi, score};
        best.insert(std::lower_bound(best.begin(), best.end(), match, less),
                    match);
        // Scan beyond the cap so a later exact match still beats early
        // noise. Retain only the best 200, not an unbounded list of all
        // matches.
        if (best.size() > 200) {
          truncated = true;
          best.removeLast();
        }
      }
      if (!pending.isEmpty() &&
          (directory == rootPath || publicationClock.elapsed() >= 100)) {
        publish(false);
        publicationClock.restart();
      }
    }
    publish(true);
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
        this,
        [this, genPtr, gen, out, truncated]() {
          // A newer search/cancel can run after enqueue and before delivery.
          if (genPtr->load() != gen)
            return;
          emit snapshot(out, truncated, true);
          if (genPtr->load() == gen)
            emit results(out, truncated);
        },
        Qt::QueuedConnection);
  }));
}

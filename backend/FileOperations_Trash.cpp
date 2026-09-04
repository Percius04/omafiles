#include "FileOperations.h"
#include "FileOpsPrivate.h"
#include <QThreadPool>
#include <QRunnable>
using namespace FileOpsPrivate;
void FileOperations::trash(const QString &path) {
  run(QStringLiteral("trash"), path, [path](const auto &) -> Result {
    if (!QFileInfo(path).exists() && !QFileInfo(path).isSymLink())
      return {false, QStringLiteral("path does not exist")};
    QString trashPath;
    if (!QFile::moveToTrash(path, &trashPath))
      return {false, QStringLiteral("could not move to trash")};
    return {true, QString()};
  });
}

void FileOperations::emptyTrash() {
  auto cancelled = beginCancelToken(); // fresh, operation-local token (P1-4); job lambda is `this`-free (P0)
  // Selfcheck-only hook, same env-var-gated pattern as
  // OMAFILES_SELFCHECK_SLOW_TRASH_MOUNT_MS: read HERE, not on the worker, so the
  // caller can clear it the moment this returns and the queued job can never
  // fall back to the real roots (#29). Always off in production.
  const QString onlyRoot = qEnvironmentVariable("OMAFILES_SELFCHECK_TRASH_ROOT");
  run(QStringLiteral("emptyTrash"), QString(), [cancelled, onlyRoot](const auto &) -> Result {
    QString err;
    const QStringList roots =
        onlyRoot.isEmpty() ? discoverTrashRoots() : QStringList{onlyRoot};
    for (const QString &root : roots) {
      if (cancelled->load())
        return {false, QStringLiteral("cancelled")};

      const QString filesDir = root + QStringLiteral("/files");
      const QString infoDir = root + QStringLiteral("/info");

      if (QFileInfo(filesDir).isDir()) {
        const QFileInfoList files = QDir(filesDir).entryInfoList(
            QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden |
            QDir::System);
        for (const QFileInfo &fi : files) {
          if (cancelled->load())
            return {false, QStringLiteral("cancelled")};
          removeTree(fi.absoluteFilePath(), *cancelled, err);
        }
      }

      if (QFileInfo(infoDir).isDir()) {
        const QFileInfoList infos = QDir(infoDir).entryInfoList(
            {QStringLiteral("*.trashinfo")}, QDir::Files | QDir::Hidden);
        for (const QFileInfo &fi : infos) {
          if (cancelled->load())
            return {false, QStringLiteral("cancelled")};
          QFile::remove(fi.absoluteFilePath());
        }
      }
    }
    return {true, QString()};
  });
}

void FileOperations::restore(const QString &path) {
  run(QStringLiteral("restore"), path, [path](const auto &) -> Result {
    const QFileInfo fi(path);
    const QString name = fi.fileName();
    const QString filesDir = fi.absolutePath();       // <root>/files
    const QString root = QFileInfo(filesDir).absolutePath(); // <root>
    const QString infoPath =
        root + QStringLiteral("/info/") + name + QStringLiteral(".trashinfo");

    QFile info(infoPath);
    if (!info.open(QIODevice::ReadOnly))
      return {false, QStringLiteral("no .trashinfo for %1").arg(name)};
    QString encoded;
    while (!info.atEnd()) {
      const QByteArray line = info.readLine();
      if (line.startsWith("Path=")) {
        encoded = QString::fromUtf8(line.mid(5)).trimmed();
        break;
      }
    }
    info.close();
    if (encoded.isEmpty())
      return {false, QStringLiteral("no Path= in .trashinfo")};

    QString orig = QUrl::fromPercentEncoding(encoded.toUtf8());
    // In disk trashes (.Trash-$uid) Path may be relative to the mount
    // point (= the parent of <root>); in the home one it is absolute.
    if (!orig.startsWith(QLatin1Char('/')))
      orig = QFileInfo(root).absolutePath() + QLatin1Char('/') + orig;

    if (QFileInfo::exists(orig))
      return {false, QStringLiteral("target already exists: %1").arg(orig)};
    QDir().mkpath(QFileInfo(orig).absolutePath());
    if (::rename(QFile::encodeName(path).constData(),
                 QFile::encodeName(orig).constData()) != 0)
      return {false, QString::fromLocal8Bit(strerror(errno))};
    QFile::remove(infoPath);
    return {true, QString()};
  });
}

void FileOperations::restoreByOrigPath(const QString &origPath) {
  auto cancelled = beginCancelToken(); // fresh, operation-local token (P1-4); job lambda is `this`-free (P0)
  run(QStringLiteral("restore"), origPath, [origPath, cancelled](const auto &) -> Result {
    // Search in ALL the XDG roots for the .trashinfo whose Path= matches origPath,
    // matching exact, canonical (symlink-resolved), or clean paths,
    // and keeping the most recent one (same file deleted several times).
    QString bestInfo;
    qint64 bestMtime = -1;
    QString bestRoot;
    const QString origCanonical = canonicalPathForFile(origPath);
    const QString origClean = QDir::cleanPath(origPath);

    for (const QString &root : discoverTrashRoots()) {
      QDir infoDir(root + QStringLiteral("/info"));
      if (!infoDir.exists())
        continue;
      const QFileInfoList infos = infoDir.entryInfoList(
          {QStringLiteral("*.trashinfo")}, QDir::Files);
      for (const QFileInfo &fi : infos) {
        QString name, decoded;
        qint64 epoch = 0;
        if (!parseTrashInfo(fi, root, name, decoded, epoch))
          continue;

        const bool matches = (decoded == origPath) ||
                             (QDir::cleanPath(decoded) == origClean) ||
                             (canonicalPathForFile(decoded) == origCanonical);
        if (!matches)
          continue;

        const qint64 m = fi.lastModified().toSecsSinceEpoch();
        if (m > bestMtime) {
          bestMtime = m;
          bestInfo = fi.absoluteFilePath();
          bestRoot = root;
        }
      }
    }
    if (bestInfo.isEmpty())
      return {false,
              QStringLiteral("no matching trashed item for %1").arg(origPath)};

    // <root>/files/<name> (name = basename of the .trashinfo without the extension).
    QString name = QFileInfo(bestInfo).fileName();
    name.chop(QStringLiteral(".trashinfo").size());
    const QString src = bestRoot + QStringLiteral("/files/") + name;
    if (!QFileInfo::exists(src) && !QFileInfo(src).isSymLink())
      return {false, QStringLiteral("trash file missing: %1").arg(src)};
    if (QFileInfo::exists(origPath) || QFileInfo(origPath).isSymLink())
      return {false,
              QStringLiteral("destination already exists: %1").arg(origPath)};

    QDir().mkpath(QFileInfo(origPath).absolutePath());
    if (::rename(QFile::encodeName(src).constData(),
                 QFile::encodeName(origPath).constData()) != 0) {
      if (errno != EXDEV)
        return {false, QString::fromLocal8Bit(strerror(errno))};
      // Crosses disks (rare in XDG: the trash is on the same disk as
      // the original): copy + delete, as `mv` would.
      qint64 copied = 0;
      QString e;
      const auto noop = [](qint64) {};
      if (!copyTree(src, origPath, copied, noop, *cancelled, e))
        return {false, e};
      if (!removeTree(src, *cancelled, e))
        return {false, e};
    }
    QFile::remove(bestInfo);
    return {true, QString()};
  });
}

void FileOperations::requestTrashRoots(quint64 requestId) {
  auto life = m_life; // copy of the control block, outlives the singleton (see run())
  QThreadPool::globalInstance()->start(QRunnable::create(
      [this, life, requestId]() {
        const QStringList roots = discoverTrashRoots(); // the slow part: stat() per mount
        std::lock_guard<std::mutex> lk(life->mtx);
        if (!life->alive)
          return;
        QMetaObject::invokeMethod(
            this,
            [this, requestId, roots]() { emit trashRootsReady(requestId, roots); },
            Qt::QueuedConnection);
      }));
}

void FileOperations::requestTrashInfo(quint64 requestId) {
  auto life = m_life;
  QThreadPool::globalInstance()->start(QRunnable::create(
      [this, life, requestId]() {
        QVariantList out;
        for (const QString &root : discoverTrashRoots()) {
          QDir infoDir(root + QStringLiteral("/info"));
          if (!infoDir.exists())
            continue;
          const QFileInfoList infos = infoDir.entryInfoList(
              {QStringLiteral("*.trashinfo")}, QDir::Files);
          for (const QFileInfo &fi : infos) {
            QString name, origPath;
            qint64 epoch = 0;
            if (!parseTrashInfo(fi, root, name, origPath, epoch))
              continue;
            QVariantMap e;
            e[QStringLiteral("name")] = name;
            e[QStringLiteral("origPath")] = origPath;
            e[QStringLiteral("epoch")] = epoch;
            e[QStringLiteral("trashRoot")] = root;
            out.append(e);
          }
        }
        std::lock_guard<std::mutex> lk(life->mtx);
        if (!life->alive)
          return;
        QMetaObject::invokeMethod(
            this,
            [this, requestId, out]() { emit trashInfoReady(requestId, out); },
            Qt::QueuedConnection);
      }));
}

#include "FileOperations.h"
#include "FileOpsPrivate.h"
#include <QThreadPool>
#include <QRunnable>
using namespace FileOpsPrivate;

void FileOperations::trash(const QString &path) {
  run(QStringLiteral("trash"), path, [path](const auto &) -> Result {
    if (!entryExists(path))
      return {false, QStringLiteral("path does not exist")};
    QString trashPath;
    if (!QFile::moveToTrash(path, &trashPath))
      return {false, QStringLiteral("could not move to trash")};
    return {true, QString(), QString(), trashPath};
  });
}

void FileOperations::emptyTrash() {
  m_cancelled->store(false);
  auto cancelled = m_cancelled; // see copy() -- job lambda is `this`-free
  run(QStringLiteral("emptyTrash"), QString(), [cancelled](const auto &) -> Result {
    if (cancelled->load())
      return {false, QStringLiteral("cancelled")};
    QStringList failures;
    for (const ValidatedTrashRoot &root : discoverValidatedTrashRoots()) {
      if (cancelled->load())
        return {false, QStringLiteral("cancelled")};

      const QFileInfoList payloads = QDir(root.files).entryInfoList(
          QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden |
          QDir::System);
      for (const QFileInfo &payload : payloads) {
        if (cancelled->load())
          return {false, QStringLiteral("cancelled")};
        if (!safeTrashPayloadEntry(payload.absoluteFilePath(), root.files)) {
          failures << QStringLiteral("unsafe trash payload: %1")
                          .arg(payload.absoluteFilePath());
          continue;
        }

        QString removeError;
        if (!removeTree(payload.absoluteFilePath(), *cancelled, removeError)) {
          if (cancelled->load())
            return {false, QStringLiteral("cancelled")};
          failures << removeError;
          continue; // Keep this payload's metadata.
        }

        const QString infoPath =
            QDir(root.info)
                .filePath(payload.fileName() + QStringLiteral(".trashinfo"));
        if (!entryExists(infoPath))
          continue;
        if (!safeTrashInfoEntry(infoPath, root.info)) {
          failures << QStringLiteral("unsafe trash metadata: %1").arg(infoPath);
          continue;
        }
        if (!QFile::remove(infoPath))
          failures << QStringLiteral("cannot remove %1").arg(infoPath);
      }
    }
    if (cancelled->load())
      return {false, QStringLiteral("cancelled")};
    if (!failures.isEmpty())
      return {false, failures.join(QStringLiteral("; "))};
    return {true, QString()};
  });
}

namespace {

struct RestoreOutcome {
  bool ok = false;
  QString error;
  QString warning;
};

RestoreOutcome restorePayload(const QString &source, const QString &destination,
                              const QString &metadata,
                              const std::atomic<bool> &cancelled) {
  if (!QDir().mkpath(QFileInfo(destination).absolutePath()))
    return {false, QStringLiteral("cannot create restore parent"), {}};

  injectDestinationRaceForTest(destination);
  bool committed = renameEntryNoReplace(source, destination);
  bool copied = false;
  if (!committed) {
    const int renameError = errno;
    if (renameError != EXDEV) {
      return {false,
              renameError == EEXIST
                  ? QStringLiteral("destination already exists: %1").arg(destination)
                  : QString::fromLocal8Bit(strerror(renameError)),
              {}};
    }

    const QString stage =
        FileOpsPrivate::uniqueSiblingPath(destination, QStringLiteral("stage"));
    qint64 copiedBytes = 0;
    QString copyError;
    const auto noop = [](qint64) {};
    if (!copyTree(source, stage, copiedBytes, noop, cancelled, copyError)) {
      forceRemove(stage);
      return {false, copyError, {}};
    }
    injectRestoreCommitRaceForTest(destination);
    const CommitOutcome commit =
        commitStagedReplacement(stage, destination, false, true);
    if (!commit.ok) {
      return {false,
              QStringLiteral("%1; complete restore stage retained at %2")
                  .arg(commit.error, stage),
              {}};
    }
    committed = true;
    copied = true;
  }

  Q_ASSERT(committed);
  QStringList warnings;
  if (copied) {
    QString cleanupError;
    if (!removeTree(source, cancelled, cleanupError)) {
      warnings << QStringLiteral("restore committed; trash payload retained at %1: %2")
                      .arg(source, cleanupError);
    }
  }

  if (warnings.isEmpty()) {
    bool metadataRemoved = false;
#ifdef OMAFILES_UNIT_TEST
    if (testMetadataRemoveFailurePath.isEmpty() ||
        !samePathComponents(metadata, testMetadataRemoveFailurePath))
      metadataRemoved = QFile::remove(metadata);
#else
    metadataRemoved = QFile::remove(metadata);
#endif
    if (!metadataRemoved)
      warnings << QStringLiteral("restore committed; metadata retained at %1")
                      .arg(metadata);
  }
  return {true, {}, warnings.join(QStringLiteral("; "))};
}

} // namespace

void FileOperations::restore(const QString &path) {
  m_cancelled->store(false);
  auto cancelled = m_cancelled;
  run(QStringLiteral("restore"), path, [path, cancelled](const auto &) -> Result {
    const QFileInfo payload(path);
    const QString payloadParent = payload.absoluteDir().canonicalPath();
    ValidatedTrashRoot selected;
    bool foundRoot = false;
    for (const ValidatedTrashRoot &root : discoverValidatedTrashRoots()) {
      if (samePathComponents(payloadParent, root.files)) {
        selected = root;
        foundRoot = true;
        break;
      }
    }
    if (!foundRoot || !safeTrashPayloadEntry(path, selected.files))
      return {false, QStringLiteral("unsafe or inactive trash path")};

    const QString name = payload.fileName();
    const QString infoPath =
        QDir(selected.info).filePath(name + QStringLiteral(".trashinfo"));
    if (!safeTrashInfoEntry(infoPath, selected.info))
      return {false, QStringLiteral("no safe .trashinfo for %1").arg(name)};

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
    if (!orig.startsWith(QLatin1Char('/')))
      orig = QFileInfo(selected.root).absolutePath() + QLatin1Char('/') + orig;

    const RestoreOutcome restored =
        restorePayload(path, orig, infoPath, *cancelled);
    return {restored.ok, restored.error, restored.warning};
  });
}

void FileOperations::restoreByOrigPath(const QString &origPath) {
  m_cancelled->store(false);
  auto cancelled = m_cancelled; // see copy() -- job lambda is `this`-free
  run(QStringLiteral("restore"), origPath, [origPath, cancelled](const auto &) -> Result {
    QString bestInfo;
    qint64 bestMtime = -1;
    ValidatedTrashRoot bestRoot;
    const QString origCanonical = canonicalPathForFile(origPath);
    const QString origClean = QDir::cleanPath(origPath);

    for (const ValidatedTrashRoot &root : discoverValidatedTrashRoots()) {
      const QFileInfoList infos = QDir(root.info).entryInfoList(
          {QStringLiteral("*.trashinfo")}, QDir::Files | QDir::Hidden);
      for (const QFileInfo &fi : infos) {
        if (!safeTrashInfoEntry(fi.absoluteFilePath(), root.info))
          continue;
        QString name, decoded;
        qint64 epoch = 0;
        if (!parseTrashInfo(fi, root.root, name, decoded, epoch))
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

    QString name = QFileInfo(bestInfo).fileName();
    name.chop(QStringLiteral(".trashinfo").size());
    const QString src = QDir(bestRoot.files).filePath(name);
    if (!safeTrashPayloadEntry(src, bestRoot.files))
      return {false, QStringLiteral("trash file missing or unsafe: %1").arg(src)};
    const RestoreOutcome restored =
        restorePayload(src, origPath, bestInfo, *cancelled);
    return {restored.ok, restored.error, restored.warning};
  });
}

QStringList FileOperations::trashRoots() const { return discoverTrashRoots(); }

QVariantList FileOperations::trashInfo() const {
  QVariantList out;
  for (const ValidatedTrashRoot &root : discoverValidatedTrashRoots()) {
    const QFileInfoList infos = QDir(root.info).entryInfoList(
        {QStringLiteral("*.trashinfo")}, QDir::Files | QDir::Hidden);
    for (const QFileInfo &fi : infos) {
      if (!safeTrashInfoEntry(fi.absoluteFilePath(), root.info))
        continue;
      QString name, origPath;
      qint64 epoch = 0;
      if (!parseTrashInfo(fi, root.root, name, origPath, epoch))
        continue;
      QVariantMap entry;
      entry[QStringLiteral("name")] = name;
      entry[QStringLiteral("origPath")] = origPath;
      entry[QStringLiteral("epoch")] = epoch;
      entry[QStringLiteral("trashRoot")] = root.root;
      entry[QStringLiteral("payloadPath")] =
          QDir(root.files).filePath(name);
      out.append(entry);
    }
  }
  return out;
}

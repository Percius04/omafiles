#include "FileOperations.h"
#include "FileOpsPrivate.h"
#include <QThreadPool>
#include <QRunnable>
using namespace FileOpsPrivate;

void FileOperations::move(const QString &source, const QString &destination,
                          bool overwrite) {
  m_cancelled->store(false);
  auto cancelled = m_cancelled; // see copy() -- job lambda is `this`-free
  run(QStringLiteral("move"), source,
      [source, destination, overwrite, cancelled](const auto &progressFn) -> Result {
        if (!entryExists(source))
          return {false, QStringLiteral("source does not exist")};
        QString validationError;
        if (!validateTransferPaths(source, destination, validationError))
          return {false, validationError};
        if (entryExists(destination) && !overwrite)
          return {false, QStringLiteral("destination already exists")};

        const QString stage =
            FileOpsPrivate::uniqueSiblingPath(destination, QStringLiteral("stage"));

        // First try to move the source to a sibling stage. This detects a
        // same-filesystem move without changing destination. The commit helper
        // then backs up destination, renames the stage, and rolls back the old
        // destination if that final rename fails.
        if (renameEntry(source, stage)) {
          const CommitOutcome commit =
              commitStagedReplacement(stage, destination, overwrite);
          if (commit.ok)
            return {true, QString()};
          if (commit.committed)
            return {true, QString(), commit.error};
          if (!commit.backup.isEmpty())
            return {false, commit.error};
          if (entryExists(stage) && !renameEntryNoReplace(stage, source)) {
            return {false,
                    QStringLiteral("%1; source rollback failed: %2")
                        .arg(commit.error,
                             QString::fromLocal8Bit(strerror(errno)))};
          }
          return {false, commit.error};
        }

        if (errno != EXDEV)
          return {false, QString::fromLocal8Bit(strerror(errno))};

        // Cross-filesystem move: copy into a destination sibling, replace the
        // destination while retaining its old entry, then atomically hide the
        // source in a recovery sibling. The source rename is the commit point.
        const qint64 realTotal = treeSize(source);
        const qint64 pctTotal = qMax<qint64>(1, realTotal);
        qint64 copied = 0;
        double lastPct = -1;
        const auto cb = [&](qint64 done) {
          const double pct = qMin(100.0, done * 100.0 / pctTotal);
          if (pct - lastPct >= 1.0) {
            lastPct = pct;
            progressFn(done, realTotal);
          }
        };
        QString err;
        if (!copyTree(source, stage, copied, cb, *cancelled, err)) {
          forceRemove(stage);
          return {false, err};
        }

        const CommitOutcome commit =
            commitStagedReplacement(stage, destination, overwrite, true);
        if (!commit.ok) {
          if (!commit.committed) {
            if (commit.backup.isEmpty())
              forceRemove(stage);
            return {false, commit.error};
          }
          return {true, QString(), commit.error};
        }

        const QString recovery =
            uniqueHiddenSiblingPath(source, QStringLiteral("recovery"));
        bool sourceStaged = false;
#ifdef OMAFILES_UNIT_TEST
        if (!testSourceStageRenameFailure.exchange(false))
          sourceStaged = renameEntry(source, recovery);
        else
          errno = EIO;
#else
        sourceStaged = renameEntry(source, recovery);
#endif
        if (!sourceStaged) {
          const QString stageError = QString::fromLocal8Bit(strerror(errno));
          // The destination is only provisional until the source is hidden.
          // Rename the new entry back to its stage before restoring the old one.
          if (!renameEntry(destination, stage)) {
            return {false,
                    QStringLiteral("source staging failed (%1); destination rollback failed (%2)")
                        .arg(stageError, QString::fromLocal8Bit(strerror(errno)))};
          }
          if (!commit.backup.isEmpty() &&
              !renameEntryNoReplace(commit.backup, destination)) {
            const QString rollbackError = QString::fromLocal8Bit(strerror(errno));
            renameEntryNoReplace(stage, destination); // preserve any rollback race winner
            return {false,
                    QStringLiteral("source staging failed (%1); old destination restore failed (%2); new stage retained at %3; old destination retained at %4")
                        .arg(stageError, rollbackError, stage, commit.backup)};
          }
          forceRemove(stage);
          return {false, QStringLiteral("source staging failed: %1").arg(stageError)};
        }

        // Committed: the visible source is absent and destination is complete.
        // Cleanup is recoverable and must not turn this into a failed move.
        QStringList warnings;
        if (!removeTree(recovery, *cancelled, err)) {
          warnings << QStringLiteral("move committed; source cleanup retained at %1: %2")
                          .arg(recovery, err);
        }
        if (!commit.backup.isEmpty()) {
          std::atomic<bool> neverCancelled{false};
          QString backupError;
          if (!removeTree(commit.backup, neverCancelled, backupError)) {
            warnings << QStringLiteral("move committed; old destination backup retained at %1: %2")
                            .arg(commit.backup, backupError);
          }
        }
        progressFn(realTotal, realTotal);
        return {true, QString(), warnings.join(QStringLiteral("; "))};
      });
}

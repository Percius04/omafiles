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
            uniqueSiblingPath(destination, QStringLiteral("stage"));

        // First try to move the source to a sibling stage. This detects a
        // same-filesystem move without changing destination. The commit helper
        // then backs up destination, renames the stage, and rolls back the old
        // destination if that final rename fails.
        if (renameEntry(source, stage)) {
          const CommitOutcome commit =
              commitStagedReplacement(stage, destination, overwrite);
          if (commit.ok)
            return {true, QString()};
          if (!commit.committed && entryExists(stage) &&
              !renameEntry(stage, source)) {
            return {false,
                    QStringLiteral("%1; source rollback failed: %2")
                        .arg(commit.error,
                             QString::fromLocal8Bit(strerror(errno)))};
          }
          return {false, commit.error};
        }

        if (errno != EXDEV)
          return {false, QString::fromLocal8Bit(strerror(errno))};

        // Cross-filesystem move: copy into the sibling stage, commit it, then
        // delete source. Once committed, a source-delete failure is reported as
        // a duplicate; destination is never deleted to hide that failure.
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
            commitStagedReplacement(stage, destination, overwrite);
        if (!commit.ok) {
          if (!commit.committed)
            forceRemove(stage);
          return {false, commit.error};
        }
        if (!removeTree(source, *cancelled, err)) {
          return {false,
                  QStringLiteral("destination committed; source removal incomplete (duplicate may remain): %1")
                      .arg(err)};
        }
        progressFn(realTotal, realTotal);
        return {true, QString()};
      });
}

#include "FileOperations.h"
#include "FileOpsPrivate.h"
#include <QThreadPool>
#include <QRunnable>
using namespace FileOpsPrivate;
void FileOperations::copy(const QString &source, const QString &destination,
                          bool overwrite) {
  m_cancelled->store(false);
  // `cancelled` is a shared_ptr COPY captured by value below, not `this` --
  // the job lambda below is entirely `this`-free (P0 concurrency audit,
  // forensic audit 2026-08-16): see the comment on run()/ProgressFn in
  // FileOperations.h for why that matters.
  auto cancelled = m_cancelled;
  run(QStringLiteral("copy"), source,
      [source, destination, overwrite, cancelled](const auto &progressFn) -> Result {
        if (!entryExists(source))
          return {false, QStringLiteral("source does not exist")};
        QString validationError;
        if (!validateTransferPaths(source, destination, validationError))
          return {false, validationError};
        if (entryExists(destination) && !overwrite)
          return {false, QStringLiteral("destination already exists")};

        // Build the complete replacement beside destination. The old
        // destination stays in place until the final rename commit.
        const QString stage =
            uniqueSiblingPath(destination, QStringLiteral("stage"));
        const qint64 realTotal = treeSize(source);
        const qint64 pctTotal = qMax<qint64>(1, realTotal);
        qint64 copied = 0;
        double lastPct = -1;
        const auto cb = [&](qint64 done) {
          const double pct = qMin(100.0, done * 100.0 / pctTotal);
          if (pct - lastPct >= 1.0) { // do not flood with signals (~every 1%)
            lastPct = pct;
            progressFn(done, realTotal);
          }
        };
        QString err;
        if (!copyTree(source, stage, copied, cb, *cancelled, err)) {
          // Cancellation and copy failures remove only the private stage. The
          // previous destination has not been touched.
          forceRemove(stage);
          return {false, err};
        }

        const CommitOutcome commit =
            commitStagedReplacement(stage, destination, overwrite);
        if (!commit.ok) {
          if (!commit.committed) {
            forceRemove(stage);
            return {false, commit.error};
          }
          return {true, QString(), commit.error};
        }
        progressFn(realTotal, realTotal);
        return {true, QString()};
      });
}


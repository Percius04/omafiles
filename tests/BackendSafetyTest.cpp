#include "DirectoryModel.h"
#include "FileOperations.h"
#include "FileOpsPrivate.h"
#include "PreviewProvider.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QProcess>
#include <QProcessEnvironment>
#include <QSemaphore>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>
#include <QThreadPool>
#include <QUrl>

#include <functional>
#include <sys/stat.h>

using namespace FileOpsPrivate;

namespace {

bool writeFile(const QString &path, const QByteArray &content) {
  QFile file(path);
  if (!file.open(QIODevice::WriteOnly))
    return false;
  return file.write(content) == content.size();
}

QByteArray readFile(const QString &path) {
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly))
    return {};
  return file.readAll();
}

QByteArray rawSymlinkTarget(const QString &path) {
  QByteArray target(4096, '\0');
  const ssize_t size =
      ::readlink(QFile::encodeName(path).constData(), target.data(), target.size());
  if (size < 0)
    return {};
  target.resize(size);
  return target;
}

struct OperationResult {
  bool finished = false;
  QString error;
  QString warning;
};

OperationResult runOperation(FileOperations &operations,
                             const std::function<void()> &start) {
  QSignalSpy finished(&operations, &FileOperations::finished);
  QSignalSpy error(&operations, &FileOperations::error);
  QSignalSpy warning(&operations, &FileOperations::warning);
  start();
  const bool delivered = QTest::qWaitFor(
      [&] { return finished.count() + error.count() == 1; }, 10000);
  if (!delivered)
    return {false, QStringLiteral("timed out"), {}};
  if (!error.isEmpty())
    return {false, error.first().at(2).toString(), {}};
  return {true, {}, warning.isEmpty() ? QString() : warning.first().at(2).toString()};
}

void createSourceAndDestination(const QString &source, const QString &destination,
                                bool directory, bool large = false) {
  if (directory) {
    QDir().mkpath(source);
    QDir().mkpath(destination);
    writeFile(QDir(source).filePath(QStringLiteral("new-only")), "new");
    writeFile(QDir(destination).filePath(QStringLiteral("old-only")), "old");
    if (large)
      writeFile(QDir(source).filePath(QStringLiteral("large")),
                QByteArray(3 * 1024 * 1024, 'n'));
  } else {
    writeFile(source, large ? QByteArray(3 * 1024 * 1024, 'n')
                            : QByteArray("new"));
    writeFile(destination, "old");
  }
}

bool destinationHasOldContent(const QString &destination, bool directory) {
  return directory
             ? readFile(QDir(destination).filePath(QStringLiteral("old-only"))) ==
                   QByteArray("old")
             : readFile(destination) == QByteArray("old");
}

bool destinationHasNewContent(const QString &destination, bool directory) {
  return directory
             ? readFile(QDir(destination).filePath(QStringLiteral("new-only"))) ==
                       QByteArray("new") &&
                   !QFileInfo::exists(
                       QDir(destination).filePath(QStringLiteral("old-only")))
             : readFile(destination) == QByteArray("new");
}

bool createTrashItem(const QString &dataHome, const QString &name,
                     const QString &originalPath, const QByteArray &content,
                     QString &payload, QString &metadata) {
  const QString trash = QDir(dataHome).filePath(QStringLiteral("Trash"));
  const QString files = QDir(trash).filePath(QStringLiteral("files"));
  const QString info = QDir(trash).filePath(QStringLiteral("info"));
  if (!QDir().mkpath(files) || !QDir().mkpath(info))
    return false;
  payload = QDir(files).filePath(name);
  metadata = QDir(info).filePath(name + QStringLiteral(".trashinfo"));
  return writeFile(payload, content) &&
         writeFile(metadata,
                   QByteArray("[Trash Info]\nPath=") +
                       QUrl::toPercentEncoding(originalPath) +
                       QByteArray("\nDeletionDate=2026-01-01T00:00:00\n"));
}

class ScopedEnvironment {
public:
  ScopedEnvironment(const char *name, const QByteArray &value)
      : m_name(name), m_had(qEnvironmentVariableIsSet(name)),
        m_old(qgetenv(name)) {
    qputenv(name, value);
  }
  ~ScopedEnvironment() {
    if (m_had)
      qputenv(m_name.constData(), m_old);
    else
      qunsetenv(m_name.constData());
  }

private:
  QByteArray m_name;
  bool m_had;
  QByteArray m_old;
};

} // namespace

class BackendSafetyTest : public QObject {
  Q_OBJECT

private slots:
  void cleanup();
  void transferRejectsUnsafePaths_data();
  void transferRejectsUnsafePaths();
  void noReplaceRacePreservesWinner_data();
  void noReplaceRacePreservesWinner();
  void overwriteRacePreservesWinnerAndRecovery_data();
  void overwriteRacePreservesWinnerAndRecovery();
  void overwriteCommitFailurePreservesDestination_data();
  void overwriteCommitFailurePreservesDestination();
  void copyFailurePreservesDestination_data();
  void copyFailurePreservesDestination();
  void copyCancellationPreservesDestination_data();
  void copyCancellationPreservesDestination();
  void overwriteSuccessReplacesDestination_data();
  void overwriteSuccessReplacesDestination();
  void crossFilesystemMoveCopyInterruptionPreservesDestination_data();
  void crossFilesystemMoveCopyInterruptionPreservesDestination();
  void relativeSymlinkTargetIsPreserved_data();
  void relativeSymlinkTargetIsPreserved();
  void crossFilesystemMoveCommittedCleanupWarning_data();
  void crossFilesystemMoveCommittedCleanupWarning();
  void crossFilesystemMoveSourceStagingFailureRollsBack();
  void removeTreeSwapNeverFollowsSymlink();
  void removeTreeDeletesSymlinkLeaf();
  void removeTreeSupportsSymlinkedParent();
  void trashReportsExactPayloadPath();
  void restoreRacePreservesWinnerAndPayload_data();
  void restoreRacePreservesWinnerAndPayload();
  void restoreCleanupFailureWarnsThenFinishes_data();
  void restoreCleanupFailureWarnsThenFinishes();
  void trashRejectsSymlinkedComponents_data();
  void trashRejectsSymlinkedComponents();
  void emptyTrashPayloadFailurePreservesMetadata();
  void emptyTrashCancellationPreservesMetadata();
  void basenameValidation_data();
  void basenameValidation();
  void renameEntryKinds_data();
  void renameEntryKinds();
  void renameRejectsExistingDestination_data();
  void renameRejectsExistingDestination();
  void transactionalRenameMoveReplacesNonDirectory_data();
  void transactionalRenameMoveReplacesNonDirectory();
  void listManyCarriesExactPayloadIdentity();
  void previewProviderDestroyUnderQueuedWork();
  void previewProviderGenerationDiscardsOldWork();
  void previewProviderSynchronousDelete();
};

void BackendSafetyTest::cleanup() {
  QThreadPool::globalInstance()->waitForDone();
  testCopyFailureAfter.store(-1);
  testCancelCopyAfter.store(-1);
  testCommitRenameFailure.store(false);
  testSourceStageRenameFailure.store(false);
  testCreateDestinationBeforeNoReplace.store(false);
  testCreateRestoreDestinationBeforeCommit.store(false);
  testRemoveFailurePath.clear();
  testCancelRemovePath.clear();
  testSwapRemovePath.clear();
  testSwapRemoveTarget.clear();
  testSwapRemoveBackup.clear();
  testMetadataRemoveFailurePath.clear();
}

void BackendSafetyTest::transferRejectsUnsafePaths_data() {
  QTest::addColumn<QString>("operation");
  QTest::addColumn<QString>("alias");
  for (const QString &operation : {QStringLiteral("copy"), QStringLiteral("move")}) {
    QTest::newRow(qPrintable(operation + QStringLiteral("-equal")))
        << operation << QStringLiteral("equal");
    QTest::newRow(qPrintable(operation + QStringLiteral("-dot")))
        << operation << QStringLiteral("dot");
    QTest::newRow(qPrintable(operation + QStringLiteral("-descendant")))
        << operation << QStringLiteral("descendant");
    QTest::newRow(qPrintable(operation + QStringLiteral("-symlink-parent")))
        << operation << QStringLiteral("symlink-parent");
  }
}

void BackendSafetyTest::transferRejectsUnsafePaths() {
  QFETCH(QString, operation);
  QFETCH(QString, alias);
  QTemporaryDir temp;
  QVERIFY(temp.isValid());

  QString source;
  QString destination;
  if (alias == QLatin1String("descendant")) {
    source = temp.filePath(QStringLiteral("source"));
    QVERIFY(QDir().mkpath(QDir(source).filePath(QStringLiteral("child"))));
    QVERIFY(writeFile(QDir(source).filePath(QStringLiteral("keep")), "keep"));
    destination = QDir(source).filePath(QStringLiteral("child/new"));
  } else {
    const QString realParent = temp.filePath(QStringLiteral("real"));
    QVERIFY(QDir().mkpath(realParent));
    source = QDir(realParent).filePath(QStringLiteral("keep"));
    QVERIFY(writeFile(source, "keep"));
    if (alias == QLatin1String("equal"))
      destination = source;
    else if (alias == QLatin1String("dot"))
      destination = realParent + QStringLiteral("/./keep");
    else {
      const QString linkedParent = temp.filePath(QStringLiteral("linked"));
      QVERIFY(QFile::link(realParent, linkedParent));
      destination = QDir(linkedParent).filePath(QStringLiteral("keep"));
    }
  }

  FileOperations operations;
  const OperationResult result = runOperation(operations, [&] {
    if (operation == QLatin1String("copy"))
      operations.copy(source, destination, true);
    else
      operations.move(source, destination, true);
  });
  QVERIFY2(!result.finished, qPrintable(result.error));
  QCOMPARE(readFile(alias == QLatin1String("descendant")
                        ? QDir(source).filePath(QStringLiteral("keep"))
                        : source),
           QByteArray("keep"));
  if (alias == QLatin1String("descendant"))
    QVERIFY(!entryExists(destination));
}

void BackendSafetyTest::noReplaceRacePreservesWinner_data() {
  QTest::addColumn<QString>("operation");
  QTest::newRow("copy") << QStringLiteral("copy");
  QTest::newRow("move") << QStringLiteral("move");
}

void BackendSafetyTest::noReplaceRacePreservesWinner() {
  QFETCH(QString, operation);
  QTemporaryDir temp;
  QVERIFY(temp.isValid());
  const QString source = temp.filePath(QStringLiteral("source"));
  const QString destination = temp.filePath(QStringLiteral("destination"));
  QVERIFY(writeFile(source, "source-data"));

  testCreateDestinationBeforeNoReplace.store(true);
  FileOperations operations;
  const OperationResult result = runOperation(operations, [&] {
    if (operation == QLatin1String("copy"))
      operations.copy(source, destination, false);
    else
      operations.move(source, destination, false);
  });

  QVERIFY(!result.finished);
  QVERIFY(result.error.contains(QStringLiteral("exist"), Qt::CaseInsensitive));
  QCOMPARE(readFile(destination), QByteArray("race-winner"));
  QCOMPARE(readFile(source), QByteArray("source-data"));
}

void BackendSafetyTest::overwriteRacePreservesWinnerAndRecovery_data() {
  QTest::addColumn<QString>("operation");
  QTest::newRow("copy") << QStringLiteral("copy");
  QTest::newRow("move") << QStringLiteral("move");
}

void BackendSafetyTest::overwriteRacePreservesWinnerAndRecovery() {
  QFETCH(QString, operation);
  QTemporaryDir temp;
  QVERIFY(temp.isValid());
  const QString source = temp.filePath(QStringLiteral("source"));
  const QString destination = temp.filePath(QStringLiteral("destination"));
  QVERIFY(writeFile(source, "new"));
  QVERIFY(writeFile(destination, "old"));

  testCreateDestinationBeforeNoReplace.store(true);
  FileOperations operations;
  const OperationResult result = runOperation(operations, [&] {
    if (operation == QLatin1String("copy"))
      operations.copy(source, destination, true);
    else
      operations.move(source, destination, true);
  });

  QVERIFY(!result.finished);
  QCOMPARE(readFile(destination), QByteArray("race-winner"));
  const QStringList backups = QDir(temp.path()).entryList(
      {QStringLiteral("destination.omafiles-backup-*")}, QDir::Files);
  const QStringList stages = QDir(temp.path()).entryList(
      {QStringLiteral("destination.omafiles-stage-*")}, QDir::Files);
  QCOMPARE(backups.size(), 1);
  QCOMPARE(stages.size(), 1);
  QCOMPARE(readFile(temp.filePath(backups.first())), QByteArray("old"));
  QCOMPARE(readFile(temp.filePath(stages.first())), QByteArray("new"));
}

void BackendSafetyTest::overwriteCommitFailurePreservesDestination_data() {
  QTest::addColumn<QString>("operation");
  QTest::addColumn<bool>("directory");
  for (const QString &operation : {QStringLiteral("copy"), QStringLiteral("move")}) {
    QTest::newRow(qPrintable(operation + QStringLiteral("-file"))) << operation << false;
    QTest::newRow(qPrintable(operation + QStringLiteral("-directory"))) << operation << true;
  }
}

void BackendSafetyTest::overwriteCommitFailurePreservesDestination() {
  QFETCH(QString, operation);
  QFETCH(bool, directory);
  QTemporaryDir temp;
  QVERIFY(temp.isValid());
  const QString source = temp.filePath(QStringLiteral("source"));
  const QString destination = temp.filePath(QStringLiteral("destination"));
  createSourceAndDestination(source, destination, directory);

  testCommitRenameFailure.store(true);
  FileOperations operations;
  const OperationResult result = runOperation(operations, [&] {
    if (operation == QLatin1String("copy"))
      operations.copy(source, destination, true);
    else
      operations.move(source, destination, true);
  });
  QVERIFY2(!result.finished, qPrintable(result.error));
  QVERIFY(destinationHasOldContent(destination, directory));
  QVERIFY(entryExists(source));
}

void BackendSafetyTest::copyFailurePreservesDestination_data() {
  QTest::addColumn<bool>("directory");
  QTest::newRow("file") << false;
  QTest::newRow("directory") << true;
}

void BackendSafetyTest::copyFailurePreservesDestination() {
  QFETCH(bool, directory);
  QTemporaryDir temp;
  QVERIFY(temp.isValid());
  const QString source = temp.filePath(QStringLiteral("source"));
  const QString destination = temp.filePath(QStringLiteral("destination"));
  createSourceAndDestination(source, destination, directory);

  testCopyFailureAfter.store(0);
  FileOperations operations;
  const OperationResult result = runOperation(
      operations, [&] { operations.copy(source, destination, true); });
  QVERIFY2(!result.finished, qPrintable(result.error));
  QVERIFY(destinationHasOldContent(destination, directory));
}

void BackendSafetyTest::copyCancellationPreservesDestination_data() {
  QTest::addColumn<bool>("directory");
  QTest::newRow("file") << false;
  QTest::newRow("directory") << true;
}

void BackendSafetyTest::copyCancellationPreservesDestination() {
  QFETCH(bool, directory);
  QTemporaryDir temp;
  QVERIFY(temp.isValid());
  const QString source = temp.filePath(QStringLiteral("source"));
  const QString destination = temp.filePath(QStringLiteral("destination"));
  createSourceAndDestination(source, destination, directory, true);

  testCancelCopyAfter.store(1024 * 1024);
  FileOperations operations;
  const OperationResult result = runOperation(
      operations, [&] { operations.copy(source, destination, true); });
  QVERIFY2(!result.finished, qPrintable(result.error));
  QVERIFY(result.error.contains(QStringLiteral("cancelled")));
  QVERIFY(destinationHasOldContent(destination, directory));
}

void BackendSafetyTest::overwriteSuccessReplacesDestination_data() {
  overwriteCommitFailurePreservesDestination_data();
}

void BackendSafetyTest::overwriteSuccessReplacesDestination() {
  QFETCH(QString, operation);
  QFETCH(bool, directory);
  QTemporaryDir temp;
  QVERIFY(temp.isValid());
  const QString source = temp.filePath(QStringLiteral("source"));
  const QString destination = temp.filePath(QStringLiteral("destination"));
  createSourceAndDestination(source, destination, directory);

  FileOperations operations;
  const OperationResult result = runOperation(operations, [&] {
    if (operation == QLatin1String("copy"))
      operations.copy(source, destination, true);
    else
      operations.move(source, destination, true);
  });
  QVERIFY2(result.finished, qPrintable(result.error));
  QVERIFY(destinationHasNewContent(destination, directory));
  QCOMPARE(entryExists(source), operation == QLatin1String("copy"));
}

void BackendSafetyTest::crossFilesystemMoveCopyInterruptionPreservesDestination_data() {
  QTest::addColumn<bool>("directory");
  QTest::addColumn<bool>("cancel");
  QTest::newRow("file-failure") << false << false;
  QTest::newRow("directory-failure") << true << false;
  QTest::newRow("file-cancellation") << false << true;
  QTest::newRow("directory-cancellation") << true << true;
}

void BackendSafetyTest::crossFilesystemMoveCopyInterruptionPreservesDestination() {
  QFETCH(bool, directory);
  QFETCH(bool, cancel);
  struct stat tempStat {};
  struct stat shmStat {};
  if (::stat(QFile::encodeName(QDir::tempPath()).constData(), &tempStat) != 0 ||
      ::stat("/dev/shm", &shmStat) != 0 || tempStat.st_dev == shmStat.st_dev)
    QSKIP("No writable second filesystem is available at /dev/shm");

  QTemporaryDir destinationRoot;
  QTemporaryDir sourceRoot(QStringLiteral("/dev/shm/omafiles-safety-XXXXXX"));
  if (!destinationRoot.isValid() || !sourceRoot.isValid())
    QSKIP("Could not create cross-filesystem fixtures");
  const QString source = sourceRoot.filePath(QStringLiteral("source"));
  const QString destination = destinationRoot.filePath(QStringLiteral("destination"));
  createSourceAndDestination(source, destination, directory, cancel);
  if (cancel)
    testCancelCopyAfter.store(1024 * 1024);
  else
    testCopyFailureAfter.store(0);

  FileOperations operations;
  const OperationResult result = runOperation(
      operations, [&] { operations.move(source, destination, true); });
  QVERIFY2(!result.finished, qPrintable(result.error));
  if (cancel)
    QVERIFY(result.error.contains(QStringLiteral("cancelled")));
  QVERIFY(destinationHasOldContent(destination, directory));
  QVERIFY(entryExists(source));
}

void BackendSafetyTest::relativeSymlinkTargetIsPreserved_data() {
  QTest::addColumn<QString>("operation");
  QTest::newRow("copy") << QStringLiteral("copy");
  QTest::newRow("cross-filesystem-move") << QStringLiteral("move");
}

void BackendSafetyTest::relativeSymlinkTargetIsPreserved() {
  QFETCH(QString, operation);
  struct stat tempStat {};
  struct stat shmStat {};
  if (operation == QLatin1String("move") &&
      (::stat(QFile::encodeName(QDir::tempPath()).constData(), &tempStat) != 0 ||
       ::stat("/dev/shm", &shmStat) != 0 || tempStat.st_dev == shmStat.st_dev))
    QSKIP("No writable second filesystem is available at /dev/shm");

  QTemporaryDir destinationRoot;
  QTemporaryDir ordinarySourceRoot;
  QTemporaryDir crossFilesystemSourceRoot(
      QStringLiteral("/dev/shm/omafiles-safety-XXXXXX"));
  QTemporaryDir *sourceRoot = operation == QLatin1String("move")
                                  ? &crossFilesystemSourceRoot
                                  : &ordinarySourceRoot;
  if (!destinationRoot.isValid() || !sourceRoot->isValid())
    QSKIP("Could not create symlink fixtures");

  const QString source = sourceRoot->filePath(QStringLiteral("source-link"));
  const QString destination =
      destinationRoot.filePath(QStringLiteral("destination-link"));
  QVERIFY(writeFile(sourceRoot->filePath(QStringLiteral("target")), "payload"));
  QCOMPARE(::symlink("target", QFile::encodeName(source).constData()), 0);
  QCOMPARE(rawSymlinkTarget(source), QByteArray("target"));

  FileOperations operations;
  const OperationResult result = runOperation(operations, [&] {
    if (operation == QLatin1String("copy"))
      operations.copy(source, destination, false);
    else
      operations.move(source, destination, false);
  });
  QVERIFY2(result.finished, qPrintable(result.error));
  QVERIFY(QFileInfo(destination).isSymLink());
  QCOMPARE(rawSymlinkTarget(destination), QByteArray("target"));
  QCOMPARE(entryExists(source), operation == QLatin1String("copy"));
}

void BackendSafetyTest::crossFilesystemMoveCommittedCleanupWarning_data() {
  QTest::addColumn<bool>("cancel");
  QTest::newRow("failure") << false;
  QTest::newRow("cancellation") << true;
}

void BackendSafetyTest::crossFilesystemMoveCommittedCleanupWarning() {
  QFETCH(bool, cancel);
  struct stat tempStat {};
  struct stat shmStat {};
  if (::stat(QFile::encodeName(QDir::tempPath()).constData(), &tempStat) != 0 ||
      ::stat("/dev/shm", &shmStat) != 0 || tempStat.st_dev == shmStat.st_dev)
    QSKIP("No writable second filesystem is available at /dev/shm");

  QTemporaryDir destinationRoot;
  QTemporaryDir sourceRoot(QStringLiteral("/dev/shm/omafiles-safety-XXXXXX"));
  if (!destinationRoot.isValid() || !sourceRoot.isValid())
    QSKIP("Could not create cross-filesystem fixtures");
  const QString source = sourceRoot.filePath(QStringLiteral("source"));
  const QString destination = destinationRoot.filePath(QStringLiteral("destination"));
  QVERIFY(writeFile(source, "new"));
  QVERIFY(writeFile(destination, "old"));

  if (cancel)
    testCancelRemovePath = source;
  else
    testRemoveFailurePath = source;
  FileOperations operations;
  const OperationResult result = runOperation(
      operations, [&] { operations.move(source, destination, true); });
  QVERIFY2(result.finished, qPrintable(result.error));
  QVERIFY(result.warning.contains(cancel ? QStringLiteral("cancelled")
                                          : QStringLiteral("forced remove failure")));
  QVERIFY(!entryExists(source));
  QCOMPARE(readFile(destination), QByteArray("new"));
  const QStringList recovery = QDir(sourceRoot.path()).entryList(
      {QStringLiteral(".source.omafiles-recovery-*")}, QDir::AllEntries | QDir::Hidden);
  QCOMPARE(recovery.size(), 1);
  QCOMPARE(readFile(sourceRoot.filePath(recovery.first())), QByteArray("new"));
  const QStringList backups = QDir(destinationRoot.path()).entryList(
      {QStringLiteral("destination.omafiles-backup-*")}, QDir::AllEntries);
  QVERIFY(backups.isEmpty());
}

void BackendSafetyTest::crossFilesystemMoveSourceStagingFailureRollsBack() {
  struct stat tempStat {};
  struct stat shmStat {};
  if (::stat(QFile::encodeName(QDir::tempPath()).constData(), &tempStat) != 0 ||
      ::stat("/dev/shm", &shmStat) != 0 || tempStat.st_dev == shmStat.st_dev)
    QSKIP("No writable second filesystem is available at /dev/shm");

  QTemporaryDir destinationRoot;
  QTemporaryDir sourceRoot(QStringLiteral("/dev/shm/omafiles-safety-XXXXXX"));
  if (!destinationRoot.isValid() || !sourceRoot.isValid())
    QSKIP("Could not create cross-filesystem fixtures");
  const QString source = sourceRoot.filePath(QStringLiteral("source"));
  const QString destination = destinationRoot.filePath(QStringLiteral("destination"));
  QVERIFY(writeFile(source, "new"));
  QVERIFY(writeFile(destination, "old"));

  testSourceStageRenameFailure.store(true);
  FileOperations operations;
  const OperationResult result = runOperation(
      operations, [&] { operations.move(source, destination, true); });
  QVERIFY(!result.finished);
  QVERIFY(result.error.contains(QStringLiteral("source staging failed")));
  QCOMPARE(readFile(source), QByteArray("new"));
  QCOMPARE(readFile(destination), QByteArray("old"));
  QCOMPARE(QDir(sourceRoot.path()).entryList(QDir::AllEntries | QDir::NoDotAndDotDot),
           QStringList{QStringLiteral("source")});
  QCOMPARE(QDir(destinationRoot.path()).entryList(QDir::AllEntries | QDir::NoDotAndDotDot),
           QStringList{QStringLiteral("destination")});
}

void BackendSafetyTest::removeTreeSwapNeverFollowsSymlink() {
  QTemporaryDir temp;
  QTemporaryDir outside;
  QVERIFY(temp.isValid());
  QVERIFY(outside.isValid());
  const QString root = temp.filePath(QStringLiteral("root"));
  const QString child = QDir(root).filePath(QStringLiteral("child"));
  const QString backup = temp.filePath(QStringLiteral("inspected-child"));
  const QString sentinel = outside.filePath(QStringLiteral("sentinel"));
  QVERIFY(QDir().mkpath(child));
  QVERIFY(writeFile(QDir(child).filePath(QStringLiteral("inside")), "inside"));
  QVERIFY(writeFile(sentinel, "outside"));

  testSwapRemovePath = child;
  testSwapRemoveTarget = outside.path();
  testSwapRemoveBackup = backup;
  FileOperations operations;
  const OperationResult result =
      runOperation(operations, [&] { operations.remove(root); });

  QVERIFY(!result.finished);
  QCOMPARE(readFile(sentinel), QByteArray("outside"));
  QCOMPARE(readFile(QDir(backup).filePath(QStringLiteral("inside"))),
           QByteArray("inside"));
  QVERIFY(QFileInfo(child).isSymLink());
}

void BackendSafetyTest::removeTreeDeletesSymlinkLeaf() {
  QTemporaryDir temp;
  QTemporaryDir outside;
  QVERIFY(temp.isValid());
  QVERIFY(outside.isValid());
  const QString sentinel = outside.filePath(QStringLiteral("sentinel"));
  const QString link = temp.filePath(QStringLiteral("directory-link"));
  QVERIFY(writeFile(sentinel, "outside"));
  QCOMPARE(::symlink(QFile::encodeName(outside.path()).constData(),
                     QFile::encodeName(link).constData()),
           0);

  FileOperations operations;
  const OperationResult result =
      runOperation(operations, [&] { operations.remove(link); });
  QVERIFY2(result.finished, qPrintable(result.error));
  QVERIFY(!entryExists(link));
  QCOMPARE(readFile(sentinel), QByteArray("outside"));
}

void BackendSafetyTest::removeTreeSupportsSymlinkedParent() {
  QTemporaryDir temp;
  QVERIFY(temp.isValid());
  const QString realParent = temp.filePath(QStringLiteral("real-parent"));
  const QString linkedParent = temp.filePath(QStringLiteral("linked-parent"));
  QVERIFY(QDir().mkpath(realParent));
  QVERIFY(QFile::link(realParent, linkedParent));
  const QString child = QDir(realParent).filePath(QStringLiteral("child"));
  QVERIFY(writeFile(child, "data"));

  FileOperations operations;
  const OperationResult result = runOperation(
      operations, [&] { operations.remove(QDir(linkedParent).filePath(QStringLiteral("child"))); });
  QVERIFY2(result.finished, qPrintable(result.error));
  QVERIFY(!entryExists(child));
  QVERIFY(QFileInfo(linkedParent).isSymLink());
}

void BackendSafetyTest::trashReportsExactPayloadPath() {
  QTemporaryDir data;
  QVERIFY(data.isValid());
  ScopedEnvironment xdg("XDG_DATA_HOME", data.path().toUtf8());
  const QString source = data.filePath(QStringLiteral("source"));
  QVERIFY(writeFile(source, "payload"));

  FileOperations operations;
  QSignalSpy detail(&operations, &FileOperations::operationDetail);
  QStringList sequence;
  connect(&operations, &FileOperations::operationDetail, &operations,
          [&sequence] { sequence << QStringLiteral("detail"); });
  connect(&operations, &FileOperations::finished, &operations,
          [&sequence] { sequence << QStringLiteral("finished"); });
  const OperationResult result =
      runOperation(operations, [&] { operations.trash(source); });
  QVERIFY2(result.finished, qPrintable(result.error));
  QCOMPARE(detail.size(), 1);
  QCOMPARE(detail.first().at(0).toString(), QStringLiteral("trash"));
  QCOMPARE(detail.first().at(1).toString(), source);
  QCOMPARE(detail.first().at(2).toString(), QStringLiteral("payloadPath"));
  QCOMPARE(sequence,
           QStringList({QStringLiteral("detail"), QStringLiteral("finished")}));
  const QString payload = detail.first().at(3).toString();
  QVERIFY(entryExists(payload));
  const QVariantList trashEntries = operations.trashInfo();
  QCOMPARE(trashEntries.size(), 1);
  QCOMPARE(trashEntries.first().toMap().value(QStringLiteral("payloadPath")).toString(),
           payload);
}

void BackendSafetyTest::restoreRacePreservesWinnerAndPayload_data() {
  QTest::addColumn<bool>("exact");
  QTest::addColumn<bool>("crossFilesystem");
  QTest::newRow("restore-same") << true << false;
  QTest::newRow("restore-by-path-same") << false << false;
  QTest::newRow("restore-cross") << true << true;
  QTest::newRow("restore-by-path-cross") << false << true;
}

void BackendSafetyTest::restoreRacePreservesWinnerAndPayload() {
  QFETCH(bool, exact);
  QFETCH(bool, crossFilesystem);
  struct stat tempStat {};
  struct stat shmStat {};
  if (crossFilesystem &&
      (::stat(QFile::encodeName(QDir::tempPath()).constData(), &tempStat) != 0 ||
       ::stat("/dev/shm", &shmStat) != 0 || tempStat.st_dev == shmStat.st_dev))
    QSKIP("No writable second filesystem is available at /dev/shm");

  QTemporaryDir destinationRoot;
  QTemporaryDir sameTrashRoot;
  QTemporaryDir crossTrashRoot(QStringLiteral("/dev/shm/omafiles-restore-XXXXXX"));
  QTemporaryDir *trashRoot = crossFilesystem ? &crossTrashRoot : &sameTrashRoot;
  if (!destinationRoot.isValid() || !trashRoot->isValid())
    QSKIP("Could not create restore fixtures");
  ScopedEnvironment xdg("XDG_DATA_HOME", trashRoot->path().toUtf8());
  const QString destination =
      destinationRoot.filePath(QStringLiteral("restored/item"));
  QString payload;
  QString metadata;
  QVERIFY(createTrashItem(trashRoot->path(), QStringLiteral("item"), destination,
                          "trashed", payload, metadata));

  if (crossFilesystem)
    testCreateRestoreDestinationBeforeCommit.store(true);
  else
    testCreateDestinationBeforeNoReplace.store(true);
  FileOperations operations;
  const OperationResult result = runOperation(operations, [&] {
    if (exact)
      operations.restore(payload);
    else
      operations.restoreByOrigPath(destination);
  });

  QVERIFY(!result.finished);
  QCOMPARE(readFile(destination), QByteArray("race-winner"));
  QCOMPARE(readFile(payload), QByteArray("trashed"));
  QVERIFY(entryExists(metadata));
  const QStringList stages = QDir(QFileInfo(destination).absolutePath()).entryList(
      {QStringLiteral("item.omafiles-stage-*")}, QDir::Files);
  QCOMPARE(stages.size(), crossFilesystem ? 1 : 0);
  if (crossFilesystem)
    QCOMPARE(readFile(QDir(QFileInfo(destination).absolutePath()).filePath(stages.first())),
             QByteArray("trashed"));
}

void BackendSafetyTest::restoreCleanupFailureWarnsThenFinishes_data() {
  QTest::addColumn<QString>("cleanup");
  QTest::addColumn<bool>("exact");
  QTest::newRow("restore-metadata") << QStringLiteral("metadata") << true;
  QTest::newRow("restore-by-path-metadata") << QStringLiteral("metadata") << false;
  QTest::newRow("restore-cross-filesystem-payload") << QStringLiteral("payload") << true;
  QTest::newRow("restore-by-path-cross-filesystem-payload") << QStringLiteral("payload") << false;
}

void BackendSafetyTest::restoreCleanupFailureWarnsThenFinishes() {
  QFETCH(QString, cleanup);
  QFETCH(bool, exact);
  const bool crossFilesystem = cleanup == QLatin1String("payload");
  struct stat tempStat {};
  struct stat shmStat {};
  if (crossFilesystem &&
      (::stat(QFile::encodeName(QDir::tempPath()).constData(), &tempStat) != 0 ||
       ::stat("/dev/shm", &shmStat) != 0 || tempStat.st_dev == shmStat.st_dev))
    QSKIP("No writable second filesystem is available at /dev/shm");

  QTemporaryDir destinationRoot;
  QTemporaryDir sameTrashRoot;
  QTemporaryDir crossTrashRoot(QStringLiteral("/dev/shm/omafiles-restore-XXXXXX"));
  QTemporaryDir *trashRoot = crossFilesystem ? &crossTrashRoot : &sameTrashRoot;
  if (!destinationRoot.isValid() || !trashRoot->isValid())
    QSKIP("Could not create restore fixtures");
  ScopedEnvironment xdg("XDG_DATA_HOME", trashRoot->path().toUtf8());
  const QString destination = destinationRoot.filePath(QStringLiteral("item"));
  QString payload;
  QString metadata;
  QVERIFY(createTrashItem(trashRoot->path(), QStringLiteral("item"), destination,
                          "trashed", payload, metadata));
  if (crossFilesystem)
    testRemoveFailurePath = payload;
  else
    testMetadataRemoveFailurePath = metadata;

  FileOperations operations;
  QStringList sequence;
  connect(&operations, &FileOperations::warning, &operations,
          [&sequence] { sequence << QStringLiteral("warning"); });
  connect(&operations, &FileOperations::finished, &operations,
          [&sequence] { sequence << QStringLiteral("finished"); });
  connect(&operations, &FileOperations::error, &operations,
          [&sequence] { sequence << QStringLiteral("error"); });
  const OperationResult result = runOperation(operations, [&] {
    if (exact)
      operations.restore(payload);
    else
      operations.restoreByOrigPath(destination);
  });

  QVERIFY2(result.finished, qPrintable(result.error));
  QVERIFY(!result.warning.isEmpty());
  QCOMPARE(sequence, QStringList({QStringLiteral("warning"),
                                  QStringLiteral("finished")}));
  QCOMPARE(readFile(destination), QByteArray("trashed"));
  QVERIFY(entryExists(metadata));
  QCOMPARE(entryExists(payload), crossFilesystem);
}

void BackendSafetyTest::trashRejectsSymlinkedComponents_data() {
  QTest::addColumn<QString>("component");
  QTest::newRow("root") << QStringLiteral("root");
  QTest::newRow("files") << QStringLiteral("files");
  QTest::newRow("info") << QStringLiteral("info");
}

void BackendSafetyTest::trashRejectsSymlinkedComponents() {
  QFETCH(QString, component);
  QTemporaryDir data;
  QTemporaryDir outside;
  QVERIFY(data.isValid());
  QVERIFY(outside.isValid());
  ScopedEnvironment xdg("XDG_DATA_HOME", data.path().toUtf8());

  const QString trash = data.filePath(QStringLiteral("Trash"));
  const QString outsideTrash = outside.filePath(QStringLiteral("Trash"));
  QVERIFY(QDir().mkpath(QDir(outsideTrash).filePath(QStringLiteral("files"))));
  QVERIFY(QDir().mkpath(QDir(outsideTrash).filePath(QStringLiteral("info"))));
  const QString sentinel =
      QDir(outsideTrash).filePath(QStringLiteral("files/sentinel"));
  QVERIFY(writeFile(sentinel, "outside"));
  QVERIFY(writeFile(QDir(outsideTrash).filePath(QStringLiteral("info/sentinel.trashinfo")),
                    "[Trash Info]\nPath=/outside\n"));

  if (component == QLatin1String("root")) {
    QVERIFY(QFile::link(outsideTrash, trash));
  } else {
    QVERIFY(QDir().mkpath(trash));
    if (component == QLatin1String("files")) {
      QVERIFY(QFile::link(QDir(outsideTrash).filePath(QStringLiteral("files")),
                          QDir(trash).filePath(QStringLiteral("files"))));
      QVERIFY(QDir().mkpath(QDir(trash).filePath(QStringLiteral("info"))));
    } else {
      QVERIFY(QDir().mkpath(QDir(trash).filePath(QStringLiteral("files"))));
      QVERIFY(writeFile(QDir(trash).filePath(QStringLiteral("files/sentinel")),
                        "payload"));
      QVERIFY(QFile::link(QDir(outsideTrash).filePath(QStringLiteral("info")),
                          QDir(trash).filePath(QStringLiteral("info"))));
    }
  }

  FileOperations operations;
  QVERIFY(!operations.trashRoots().contains(QFileInfo(trash).canonicalFilePath()));
  QVERIFY(operations.trashInfo().isEmpty());
  const OperationResult empty =
      runOperation(operations, [&] { operations.emptyTrash(); });
  QVERIFY2(empty.finished, qPrintable(empty.error));
  QCOMPARE(readFile(sentinel), QByteArray("outside"));

  const QString unsafePayload =
      component == QLatin1String("root")
          ? QDir(outsideTrash).filePath(QStringLiteral("files/sentinel"))
          : QDir(trash).filePath(QStringLiteral("files/sentinel"));
  const OperationResult restore =
      runOperation(operations, [&] { operations.restore(unsafePayload); });
  QVERIFY(!restore.finished);
  QCOMPARE(readFile(sentinel), QByteArray("outside"));
}

void BackendSafetyTest::emptyTrashPayloadFailurePreservesMetadata() {
  QTemporaryDir data;
  QVERIFY(data.isValid());
  ScopedEnvironment xdg("XDG_DATA_HOME", data.path().toUtf8());
  const QString trash = data.filePath(QStringLiteral("Trash"));
  const QString files = QDir(trash).filePath(QStringLiteral("files"));
  const QString info = QDir(trash).filePath(QStringLiteral("info"));
  QVERIFY(QDir().mkpath(files));
  QVERIFY(QDir().mkpath(info));
  const QString payload = QDir(files).filePath(QStringLiteral("item"));
  const QString metadata = QDir(info).filePath(QStringLiteral("item.trashinfo"));
  QVERIFY(writeFile(payload, "keep"));
  QVERIFY(writeFile(metadata, "[Trash Info]\nPath=/tmp/item\n"));

  testRemoveFailurePath = payload;
  FileOperations operations;
  const OperationResult result =
      runOperation(operations, [&] { operations.emptyTrash(); });
  QVERIFY(!result.finished);
  QVERIFY(entryExists(payload));
  QVERIFY(entryExists(metadata));
}

void BackendSafetyTest::emptyTrashCancellationPreservesMetadata() {
  QTemporaryDir data;
  QVERIFY(data.isValid());
  ScopedEnvironment xdg("XDG_DATA_HOME", data.path().toUtf8());
  const QString trash = data.filePath(QStringLiteral("Trash"));
  const QString files = QDir(trash).filePath(QStringLiteral("files"));
  const QString info = QDir(trash).filePath(QStringLiteral("info"));
  QVERIFY(QDir().mkpath(files));
  QVERIFY(QDir().mkpath(info));
  const QString payload = QDir(files).filePath(QStringLiteral("item"));
  const QString metadata = QDir(info).filePath(QStringLiteral("item.trashinfo"));
  QVERIFY(writeFile(payload, "keep"));
  QVERIFY(writeFile(metadata, "[Trash Info]\nPath=/tmp/item\n"));

  testCancelRemovePath = payload;
  FileOperations operations;
  const OperationResult result =
      runOperation(operations, [&] { operations.emptyTrash(); });
  QVERIFY(!result.finished);
  QVERIFY(result.error.contains(QStringLiteral("cancelled")));
  QVERIFY(entryExists(payload));
  QVERIFY(entryExists(metadata));
}

void BackendSafetyTest::basenameValidation_data() {
  QTest::addColumn<QString>("name");
  QTest::addColumn<bool>("valid");
  QTest::newRow("empty") << QString() << false;
  QTest::newRow("dot") << QStringLiteral(".") << false;
  QTest::newRow("dot-dot") << QStringLiteral("..") << false;
  QTest::newRow("slash") << QStringLiteral("a/b") << false;
  QTest::newRow("absolute") << QStringLiteral("/tmp/x") << false;
  QTest::newRow("traversal") << QStringLiteral("../x") << false;
  QTest::newRow("nul") << QString(QChar(u'a')) + QChar(0) + QChar(u'b') << false;
  QTest::newRow("spaces") << QStringLiteral("  ") << true;
  QTest::newRow("leading-dash") << QStringLiteral("-rf") << true;
  QTest::newRow("unicode") << QStringLiteral("café-文件") << true;
}

void BackendSafetyTest::basenameValidation() {
  QFETCH(QString, name);
  QFETCH(bool, valid);
  QTemporaryDir temp;
  QVERIFY(temp.isValid());
  const QString source = temp.filePath(QStringLiteral("source"));
  QVERIFY(writeFile(source, "keep"));

  FileOperations operations;
  const OperationResult result =
      runOperation(operations, [&] { operations.rename(source, name); });
  QCOMPARE(result.finished, valid);
  if (!valid) {
    QCOMPARE(readFile(source), QByteArray("keep"));
    QCOMPARE(QDir(temp.path()).entryList(QDir::AllEntries | QDir::NoDotAndDotDot).size(), 1);
  }
}

void BackendSafetyTest::renameEntryKinds_data() {
  QTest::addColumn<QString>("kind");
  QTest::newRow("file") << QStringLiteral("file");
  QTest::newRow("symlink") << QStringLiteral("symlink");
  QTest::newRow("broken-symlink") << QStringLiteral("broken-symlink");
}

void BackendSafetyTest::renameEntryKinds() {
  QFETCH(QString, kind);
  QTemporaryDir temp;
  QVERIFY(temp.isValid());
  const QString source = temp.filePath(QStringLiteral("source"));
  const QString destination = temp.filePath(QStringLiteral("renamed"));
  if (kind == QLatin1String("file")) {
    QVERIFY(writeFile(source, "keep"));
  } else {
    const QString target = kind == QLatin1String("symlink")
                               ? temp.filePath(QStringLiteral("target"))
                               : temp.filePath(QStringLiteral("missing"));
    if (kind == QLatin1String("symlink"))
      QVERIFY(writeFile(target, "target"));
    QVERIFY(QFile::link(target, source));
  }

  FileOperations operations;
  const OperationResult result =
      runOperation(operations, [&] { operations.rename(source, QStringLiteral("renamed")); });
  QVERIFY2(result.finished, qPrintable(result.error));
  QVERIFY(!entryExists(source));
  QVERIFY(entryExists(destination));
  if (kind != QLatin1String("file"))
    QCOMPARE(rawSymlinkTarget(destination), QFile::encodeName(kind == QLatin1String("symlink")
                                                                  ? temp.filePath(QStringLiteral("target"))
                                                                  : temp.filePath(QStringLiteral("missing"))));
}

void BackendSafetyTest::renameRejectsExistingDestination_data() {
  QTest::addColumn<QString>("kind");
  QTest::newRow("file") << QStringLiteral("file");
  QTest::newRow("symlink") << QStringLiteral("symlink");
  QTest::newRow("broken-symlink") << QStringLiteral("broken-symlink");
  QTest::newRow("empty-directory") << QStringLiteral("empty-directory");
  QTest::newRow("nonempty-directory") << QStringLiteral("nonempty-directory");
}

void BackendSafetyTest::renameRejectsExistingDestination() {
  QFETCH(QString, kind);
  QTemporaryDir temp;
  QVERIFY(temp.isValid());
  const QString source = temp.filePath(QStringLiteral("source"));
  const QString destination = temp.filePath(QStringLiteral("destination"));
  const QString target = temp.filePath(QStringLiteral("target"));
  QVERIFY(writeFile(source, "source"));
  if (kind == QLatin1String("file")) {
    QVERIFY(writeFile(destination, "destination"));
  } else if (kind == QLatin1String("symlink") ||
             kind == QLatin1String("broken-symlink")) {
    if (kind == QLatin1String("symlink"))
      QVERIFY(writeFile(target, "target"));
    QVERIFY(QFile::link(target, destination));
  } else {
    QVERIFY(QDir().mkpath(destination));
    if (kind == QLatin1String("nonempty-directory"))
      QVERIFY(writeFile(QDir(destination).filePath(QStringLiteral("child")), "child"));
  }

  const QByteArray linkTarget = rawSymlinkTarget(destination);
  FileOperations operations;
  const OperationResult result = runOperation(
      operations, [&] { operations.rename(source, QStringLiteral("destination")); });
  QVERIFY(!result.finished);
  QCOMPARE(readFile(source), QByteArray("source"));
  QVERIFY(entryExists(destination));
  if (kind == QLatin1String("file"))
    QCOMPARE(readFile(destination), QByteArray("destination"));
  else if (kind == QLatin1String("symlink") ||
           kind == QLatin1String("broken-symlink"))
    QCOMPARE(rawSymlinkTarget(destination), linkTarget);
  else
    QCOMPARE(entryExists(QDir(destination).filePath(QStringLiteral("child"))),
             kind == QLatin1String("nonempty-directory"));
}

void BackendSafetyTest::transactionalRenameMoveReplacesNonDirectory_data() {
  QTest::addColumn<QString>("destinationKind");
  QTest::newRow("file") << QStringLiteral("file");
  QTest::newRow("symlink") << QStringLiteral("symlink");
  QTest::newRow("broken-symlink") << QStringLiteral("broken-symlink");
}

void BackendSafetyTest::transactionalRenameMoveReplacesNonDirectory() {
  QFETCH(QString, destinationKind);
  QTemporaryDir temp;
  QVERIFY(temp.isValid());
  const QString source = temp.filePath(QStringLiteral("source"));
  const QString destination = temp.filePath(QStringLiteral("destination"));
  QVERIFY(writeFile(source, "new"));
  if (destinationKind == QLatin1String("file")) {
    QVERIFY(writeFile(destination, "old"));
  } else {
    const QString target = destinationKind == QLatin1String("symlink")
                               ? temp.filePath(QStringLiteral("target"))
                               : temp.filePath(QStringLiteral("missing"));
    if (destinationKind == QLatin1String("symlink"))
      QVERIFY(writeFile(target, "target"));
    QVERIFY(QFile::link(target, destination));
  }

  FileOperations operations;
  const OperationResult result = runOperation(
      operations, [&] { operations.move(source, destination, true); });
  QVERIFY2(result.finished, qPrintable(result.error));
  QVERIFY(!entryExists(source));
  QCOMPARE(readFile(destination), QByteArray("new"));
  QVERIFY(!QFileInfo(destination).isSymLink());
}

void BackendSafetyTest::listManyCarriesExactPayloadIdentity() {
  QTemporaryDir temp;
  QVERIFY(temp.isValid());
  const QString first = temp.filePath(QStringLiteral("first/files"));
  const QString second = temp.filePath(QStringLiteral("second/files"));
  QVERIFY(QDir().mkpath(first));
  QVERIFY(QDir().mkpath(second));
  QVERIFY(writeFile(QDir(first).filePath(QStringLiteral("same")), "one"));
  QVERIFY(writeFile(QDir(second).filePath(QStringLiteral("same")), "two"));
  const QString firstInfo = temp.filePath(QStringLiteral("first/info"));
  const QString secondInfo = temp.filePath(QStringLiteral("second/info"));
  QVERIFY(QDir().mkpath(firstInfo));
  QVERIFY(QDir().mkpath(secondInfo));
  QVERIFY(writeFile(QDir(firstInfo).filePath(QStringLiteral("same.trashinfo")), "info-one"));
  QVERIFY(writeFile(QDir(secondInfo).filePath(QStringLiteral("same.trashinfo")), "info-two"));

  DirectoryModel model;
  QSignalSpy listed(&model, &DirectoryModel::listed);
  model.listMany({first, second});
  QVERIFY(listed.wait(10000));
  const QVariantList entries = model.entries();
  QCOMPARE(entries.size(), 2);
  const QStringList paths{entries.at(0).toMap().value(QStringLiteral("path")).toString(),
                          entries.at(1).toMap().value(QStringLiteral("path")).toString()};
  const QString firstPayload = QDir(first).filePath(QStringLiteral("same"));
  const QString secondPayload = QDir(second).filePath(QStringLiteral("same"));
  QVERIFY(paths.contains(firstPayload));
  QVERIFY(paths.contains(secondPayload));
  QCOMPARE(readFile(firstPayload), QByteArray("one"));
  QCOMPARE(readFile(secondPayload), QByteArray("two"));
  for (const QString &payload : paths) {
    const QDir root(QFileInfo(payload).absoluteDir().absolutePath() + QStringLiteral("/.."));
    const QByteArray expected = payload == firstPayload ? QByteArray("info-one") : QByteArray("info-two");
    QCOMPARE(readFile(root.filePath(QStringLiteral("info/same.trashinfo"))), expected);
  }
  QVERIFY(model.signature() != QString());
}

void BackendSafetyTest::previewProviderDestroyUnderQueuedWork() {
  QTemporaryDir temp;
  QVERIFY(temp.isValid());
  const QString path = temp.filePath(QStringLiteral("preview.txt"));
  QVERIFY(writeFile(path, QByteArray(256 * 1024, 'x')));

  QThreadPool *pool = QThreadPool::globalInstance();
  pool->waitForDone();
  const int oldMax = pool->maxThreadCount();
  pool->setMaxThreadCount(1);
  QSemaphore started;
  QSemaphore release;
  pool->start(QRunnable::create([&] {
    started.release();
    release.acquire();
  }));
  QVERIFY(started.tryAcquire(1, 5000));

  for (int i = 0; i < 100; ++i) {
    auto *provider = new PreviewProvider;
    provider->requestText(path);
    provider->requestAudio(path);
    delete provider;
  }
  release.release();
  QVERIFY(pool->waitForDone(30000));
  pool->setMaxThreadCount(oldMax);
}

void BackendSafetyTest::previewProviderGenerationDiscardsOldWork() {
  QTemporaryDir temp;
  QVERIFY(temp.isValid());
  const QString first = temp.filePath(QStringLiteral("first.txt"));
  const QString second = temp.filePath(QStringLiteral("second.txt"));
  QVERIFY(writeFile(first, "first"));
  QVERIFY(writeFile(second, "second"));

  QThreadPool *pool = QThreadPool::globalInstance();
  pool->waitForDone();
  const int oldMax = pool->maxThreadCount();
  pool->setMaxThreadCount(1);
  QSemaphore started;
  QSemaphore release;
  pool->start(QRunnable::create([&] {
    started.release();
    release.acquire();
  }));
  QVERIFY(started.tryAcquire(1, 5000));

  PreviewProvider provider;
  QSignalSpy ready(&provider, &PreviewProvider::textReady);
  provider.requestText(first);
  provider.requestText(second);
  release.release();
  QVERIFY(QTest::qWaitFor([&] { return ready.count() == 1; }, 10000));
  QCOMPARE(ready.first().at(0).toString(), second);
  pool->waitForDone();
  pool->setMaxThreadCount(oldMax);
}

void BackendSafetyTest::previewProviderSynchronousDelete() {
  constexpr auto childEnvironment = "OMAFILES_PREVIEW_DELETE_CHILD";
  if (!qEnvironmentVariableIsSet(childEnvironment)) {
    QProcess child;
    QProcessEnvironment environment = QProcessEnvironment::systemEnvironment();
    environment.insert(QString::fromLatin1(childEnvironment), QStringLiteral("1"));
    child.setProcessEnvironment(environment);
    child.start(QCoreApplication::applicationFilePath(),
                {QStringLiteral("previewProviderSynchronousDelete")});
    QVERIFY(child.waitForStarted(5000));
    const bool completed = child.waitForFinished(5000);
    if (!completed) {
      child.kill();
      child.waitForFinished();
    }
    QVERIFY2(completed, "synchronous textReady deletion deadlocked delivery");
    QCOMPARE(child.exitStatus(), QProcess::NormalExit);
    QVERIFY2(child.exitCode() == 0, child.readAll().constData());
    return;
  }

  QTemporaryDir temp;
  QVERIFY(temp.isValid());
  const QString path = temp.filePath(QStringLiteral("preview.txt"));
  QVERIFY(writeFile(path, "content"));

  PreviewProvider *provider = new PreviewProvider;
  connect(provider, &PreviewProvider::textReady, provider,
          [&provider] { delete provider; provider = nullptr; });
  provider->requestText(path);
  QVERIFY(QTest::qWaitFor([&] { return provider == nullptr; }, 5000));
  QThreadPool::globalInstance()->waitForDone();
}

QTEST_GUILESS_MAIN(BackendSafetyTest)
#include "BackendSafetyTest.moc"

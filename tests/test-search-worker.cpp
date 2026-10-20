#include "SearchWorker.h"
#include <QFile>
#include <QSemaphore>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>
#include <QThreadPool>

static QString gatedDirectory;
static QSemaphore enteredDirectory, resumeDirectory;
void searchTraversalGate(const QString &path) {
  if (path == gatedDirectory) {
    enteredDirectory.release();
    resumeDirectory.acquire();
  }
}

class SearchWorkerTests : public QObject {
  Q_OBJECT
private slots:
  void destroyFromSnapshotReceiver() {
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    auto *worker = new SearchWorker;
    bool delivered = false;
    connect(worker, &SearchWorker::snapshot, this, [worker, &delivered]() {
      delivered = true;
      delete worker;
    });
    worker->search(dir.path(), "ORBIT", false);
    QVERIFY(QThreadPool::globalInstance()->waitForDone(5000));
    QCoreApplication::processEvents();
    QVERIFY(
        delivered); // legacy delivery must not dereference a deleted receiver
  }
  void legacyResultsOnlyComplete() {
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    QVERIFY(QDir(dir.path()).mkdir("sub"));
    SearchWorker worker;
    QSignalSpy spy(&worker, &SearchWorker::results);
    worker.search(dir.path(), "ORBIT", false);
    QVERIFY(QThreadPool::globalInstance()->waitForDone(5000));
    QCoreApplication::processEvents();
    QCOMPARE(spy.count(),
             1); // legacy callers/selfcheck must receive the full walk
  }
  void rootPublishedBeforeDescendantFinishes() {
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    QVERIFY(QDir(dir.path()).mkdir("Downloads"));
    QFile file(dir.filePath("ORBIT.pdf"));
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("fresh");
    file.close();
    gatedDirectory = dir.filePath("Downloads");
    SearchWorker worker;
    QSignalSpy spy(&worker, &SearchWorker::snapshot);
    worker.search(dir.path(), "ORBIT", false);
    const bool entered = enteredDirectory.tryAcquire(1, 5000);
    QCoreApplication::processEvents();
    const bool deliveredWhileBlocked =
        !spy.isEmpty() &&
        spy.first().at(0).toList().first().toMap()["name"] == "ORBIT.pdf";
    // Release before asserting: failure must not strand a QThreadPool worker.
    resumeDirectory.release();
    QVERIFY(QThreadPool::globalInstance()->waitForDone(5000));
    gatedDirectory.clear();
    QVERIFY(entered);
    QVERIFY2(deliveredWhileBlocked,
             "root match must arrive before descendant traversal completes");
    QCoreApplication::processEvents();
    QVERIFY(spy.last().at(0).toList().size() == 1);
    QCOMPARE(spy.first().at(2).toBool(), false);
    QCOMPARE(spy.last().at(2).toBool(), true);
  }
  void supersededQueuedDelivery_data() {
    QTest::addColumn<bool>("contentFirst");
    QTest::newRow("name-to-content") << false;
    QTest::newRow("content-to-name") << true;
  }
  void supersededQueuedDelivery() {
    QFETCH(bool, contentFirst);
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    QFile file(dir.filePath("ORBIT.txt"));
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("needle\n");
    file.close();
    SearchWorker worker;
    QSignalSpy spy(&worker, &SearchWorker::snapshot);
    if (contentFirst)
      worker.searchContent(dir.path(), "needle", false);
    else
      worker.search(dir.path(), "ORBIT", false);
    QVERIFY(QThreadPool::globalInstance()->waitForDone(5000));
    if (contentFirst)
      worker.search(dir.path(), "missing", false);
    else
      worker.searchContent(dir.path(), "missing", false);
    QVERIFY(QThreadPool::globalInstance()->waitForDone(5000));
    QCoreApplication::processEvents();
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.first().at(0).toList().size(), 0);
  }
  void destroyQueuedDelivery() {
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    auto *worker = new SearchWorker;
    worker->search(dir.path(), "ORBIT", false);
    QVERIFY(QThreadPool::globalInstance()->waitForDone(5000));
    delete worker;
    QCoreApplication::processEvents(); // the receiver owns and drops queued
                                       // calls
  }
  void cancelQueuedDelivery_data() {
    QTest::addColumn<bool>("content");
    QTest::newRow("filename") << false;
    QTest::newRow("content") << true;
  }
  void cancelQueuedDelivery() {
    QFETCH(bool, content);
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    QFile file(dir.filePath("ORBIT.txt"));
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("ORBIT needle\n");
    file.close();
    // Include descendants so cancellation fences both progressive and final
    // filename snapshots already enqueued, not just the single content result.
    QVERIFY(QDir(dir.path()).mkdir("sub"));
    SearchWorker worker;
    QSignalSpy spy(&worker, &SearchWorker::snapshot);
    if (content)
      worker.searchContent(dir.path(), "needle", false);
    else
      worker.search(dir.path(), "ORBIT", false);
    // Deterministically finish the worker WITHOUT dispatching its queued
    // delivery. Cancellation must still fence a result already enqueued.
    QVERIFY(QThreadPool::globalInstance()->waitForDone(5000));
    QCOMPARE(spy.count(), 0);
    worker.cancel();
    QCoreApplication::processEvents();
    QCOMPARE(spy.count(), 0);
  }
};
QTEST_GUILESS_MAIN(SearchWorkerTests)
#include "test-search-worker.moc"

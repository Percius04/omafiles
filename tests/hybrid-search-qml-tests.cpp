#include <QtQuickTest>
#include <QQmlEngine>
#include <QDir>
#include <QFileInfo>
#include <QRunnable>
#include <QSemaphore>
#include <QThreadPool>
#include <memory>

// Test-only scheduling gate: the actual SearchWorker and ProcessRunner remain
// untouched. Holding the pool makes index-before-local ordering deterministic
// without relying on machine speed, directory size, or production delay hooks.
class WorkerGate : public QObject {
  Q_OBJECT
public:
  using QObject::QObject;
  ~WorkerGate() override { release(); }
  Q_INVOKABLE bool hold() {
    release();
    m_state = std::make_shared<State>();
    auto state = m_state;
    auto *pool = QThreadPool::globalInstance();
    pool->setMaxThreadCount(1);
    pool->start(QRunnable::create([state]() {
      state->started.release();
      state->resume.acquire();
    }));
    return state->started.tryAcquire(1, 5000);
  }
  Q_INVOKABLE void release() {
    if (m_state) {
      m_state->resume.release();
      m_state.reset();
    }
  }
private:
  struct State { QSemaphore started; QSemaphore resume; };
  std::shared_ptr<State> m_state;
};
class Setup : public QObject {
  Q_OBJECT
public slots:
  void qmlEngineAvailable(QQmlEngine *engine) {
    engine->addImportPath(QFileInfo(QString::fromUtf8(__FILE__)).dir().filePath("../app/qml_modules"));
  }
  void applicationAvailable() {
    // Match the app's theme-file access, confined to the runner's fixture HOME.
    qputenv("QML_XHR_ALLOW_FILE_READ", "1");
    qmlRegisterType<WorkerGate>("Omafiles.SearchTests", 1, 0, "WorkerGate");
  }
};
QUICK_TEST_MAIN_WITH_SETUP(hybrid_search, Setup)
#include "hybrid-search-qml-tests.moc"

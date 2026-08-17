#include "FileOperations.h"
#include "FileOpsPrivate.h"
#include <QThreadPool>
#include <QRunnable>
using namespace FileOpsPrivate;

FileOperations::FileOperations(QObject *parent) : QObject(parent) {}

FileOperations::~FileOperations() {
  // Marks the object as dead under the lock: a worker that has not yet
  // delivered will see alive=false and will not touch this already-destroyed object.
  std::lock_guard<std::mutex> lk(m_life->mtx);
  m_life->alive = false;
}

void FileOperations::run(const QString &op, const QString &path,
                         std::function<Result(const ProgressFn &)> job) {
  auto life = m_life; // copy of the control block, outlives the singleton
  // Built here on the calling thread (this is still guaranteed valid): the
  // returned closure captures `life` by value, so when the WORKER thread
  // calls it later it never needs to re-read anything through `this` to
  // find out whether it is still safe to proceed -- it only ever touches
  // `this` (the invokeMethod call) while holding `life->mtx`, which the
  // destructor also takes before it lets the object's memory go.
  ProgressFn progressFn = [this, life, op, path](qint64 done, qint64 total) {
    std::lock_guard<std::mutex> lk(life->mtx);
    if (!life->alive)
      return;
    QMetaObject::invokeMethod(
        this,
        [this, op, path, done, total]() { emit progress(op, path, done, total); },
        Qt::QueuedConnection);
  };
  QThreadPool::globalInstance()->start(QRunnable::create(
      [this, life, op, path, job = std::move(job), progressFn]() {
        Result r = job(progressFn);
        // Safe delivery: the destructor takes this same lock, so either we
        // see alive=false (and do not touch the dead object) or we hold
        // it and the destructor waits for us to release.
        std::lock_guard<std::mutex> lk(life->mtx);
        if (!life->alive)
          return;
        QMetaObject::invokeMethod(
            this,
            [this, op, path, r]() {
              if (r.ok) {
                if (!r.payloadPath.isEmpty())
                  emit operationDetail(op, path, QStringLiteral("payloadPath"),
                                       r.payloadPath);
                if (!r.warning.isEmpty())
                  emit warning(op, path, r.warning);
                emit finished(op, path);
              } else {
                emit error(op, path, r.message);
              }
            },
            Qt::QueuedConnection);
      }));
}

void FileOperations::cancel() { m_cancelled->store(true); }

namespace {

bool validBasename(const QString &name) {
  return !name.isEmpty() && name != QLatin1String(".") &&
         name != QLatin1String("..") && !name.contains(QLatin1Char('/')) &&
         !name.contains(QChar(0));
}

} // namespace

QStringList FileOperations::existingPaths(const QStringList &paths) const {
  QStringList out;
  for (const QString &p : paths) {
    // lstat criterion shared with copy()/move(): a symlink counts as a
    // conflict whether or not it has a valid target (see entryExists / BUG-01).
    if (entryExists(p))
      out << p;
  }
  return out;
}

qint64 FileOperations::totalSize(const QStringList &paths) const {
  qint64 total = 0;
  for (const QString &p : paths)
    total += treeSize(p);
  return total;
}

QStringList FileOperations::octalModes(const QStringList &paths) const {
  QStringList out;
  out.reserve(paths.size());
  for (const QString &p : paths) {
    struct stat st;
    // stat() (follows symlinks), like `stat -c%a` -- %a is mode & 07777 in
    // octal without a leading zero (e.g. "755", "4755"). "" if it could not.
    if (::stat(QFile::encodeName(p).constData(), &st) == 0)
      out << QString::number(st.st_mode & 07777, 8);
    else
      out << QString();
  }
  return out;
}

void FileOperations::rename(const QString &path, const QString &newName) {
  if (!validBasename(newName)) {
    run(QStringLiteral("rename"), path, [](const auto &) -> Result {
      return {false, QStringLiteral("invalid file name")};
    });
    return;
  }
  const QString dst = QDir(QFileInfo(path).absolutePath()).filePath(newName);
  run(QStringLiteral("rename"), path, [path, dst](const auto &) -> Result {
    if (!entryExists(path))
      return {false, QStringLiteral("source does not exist")};
    if (QFileInfo(dst).isDir())
      return {false, QStringLiteral("destination is a directory")};
    if (!renameEntryNoReplace(path, dst)) {
      if (errno == EEXIST)
        return {false, QStringLiteral("destination already exists")};
      return {false, QString::fromLocal8Bit(strerror(errno))};
    }
    return {true, QString()};
  });
}

void FileOperations::mkdir(const QString &path) {
  run(QStringLiteral("mkdir"), path, [path](const auto &) -> Result {
    if (!QDir().mkpath(path))
      return {false, QStringLiteral("cannot create %1").arg(path)};
    return {true, QString()};
  });
}


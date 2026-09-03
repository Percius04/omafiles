#include "FileOperations.h"
#include "FileOpsPrivate.h"
#include <QDateTime>
#include <QMetaObject>
#include <QThreadPool>
#include <QRunnable>
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <sys/stat.h>
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
              if (r.ok)
                emit finished(op, path);
              else
                emit error(op, path, r.message);
            },
            Qt::QueuedConnection);
      }));
}

void FileOperations::cancel() { m_cancelled->store(true); }

std::shared_ptr<std::atomic<bool>> FileOperations::beginCancelToken() {
  auto token = std::make_shared<std::atomic<bool>>(false);
  m_cancelled = token; // cancel() now targets THIS operation
  return token;
}

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

QVariantMap FileOperations::statInfo(const QString &path) const {
  // statx, not lstat: same cost, and the only way to get the creation
  // (birth) time -- see the same swap in DirectoryModel's scan loop.
  struct statx st;
  if (::statx(AT_FDCWD, QFile::encodeName(path).constData(), AT_SYMLINK_NOFOLLOW,
              STATX_BASIC_STATS | STATX_BTIME, &st) != 0)
    return {};

  QChar type = QLatin1Char('-');
  if (S_ISDIR(st.stx_mode)) type = QLatin1Char('d');
  else if (S_ISLNK(st.stx_mode)) type = QLatin1Char('l');

  auto rwx = [](mode_t m, mode_t r, mode_t w, mode_t x) {
    QString s;
    s += (m & r) ? QLatin1Char('r') : QLatin1Char('-');
    s += (m & w) ? QLatin1Char('w') : QLatin1Char('-');
    s += (m & x) ? QLatin1Char('x') : QLatin1Char('-');
    return s;
  };
  const QString perms = QString(type) + rwx(st.stx_mode, S_IRUSR, S_IWUSR, S_IXUSR) +
                        rwx(st.stx_mode, S_IRGRP, S_IWGRP, S_IXGRP) +
                        rwx(st.stx_mode, S_IROTH, S_IWOTH, S_IXOTH);
  const QString octal = QString::number(st.stx_mode & 07777, 8);

  struct passwd *pw = ::getpwuid(st.stx_uid);
  struct group *gr = ::getgrgid(st.stx_gid);
  const QString owner = pw ? QString::fromLocal8Bit(pw->pw_name) : QString::number(st.stx_uid);
  const QString grp = gr ? QString::fromLocal8Bit(gr->gr_name) : QString::number(st.stx_gid);

  const QString fmt = QStringLiteral("yyyy-MM-dd HH:mm:ss");
  const QDateTime mtime = QDateTime::fromSecsSinceEpoch(st.stx_mtime.tv_sec).toLocalTime();
  // "" when the filesystem reports no birth time; the Properties panel
  // hides the row rather than showing a fake epoch.
  const QString btime = (st.stx_mask & STATX_BTIME)
      ? QDateTime::fromSecsSinceEpoch(st.stx_btime.tv_sec).toLocalTime().toString(fmt)
      : QString();

  QVariantMap out;
  out[QStringLiteral("perms")] = perms + QStringLiteral(" ") + octal;
  out[QStringLiteral("ownerGroup")] = owner + QStringLiteral(":") + grp;
  out[QStringLiteral("mtime")] = mtime.toString(fmt);
  out[QStringLiteral("btime")] = btime;
  return out;
}

void FileOperations::requestDirSize(quint64 requestId, const QString &path) {
  auto life = m_life; // same delivery pattern as run() -- see its own doc comment
  QThreadPool::globalInstance()->start(QRunnable::create([this, life, requestId, path]() {
    const qint64 bytes = treeSize(path);
    std::lock_guard<std::mutex> lk(life->mtx);
    if (!life->alive) return;
    QMetaObject::invokeMethod(
        this, [this, requestId, bytes]() { emit dirSizeReady(requestId, bytes); },
        Qt::QueuedConnection);
  }));
}

void FileOperations::rename(const QString &path, const QString &newName) {
  const QString dst = QFileInfo(path).absolutePath() + QLatin1Char('/') + newName;
  run(QStringLiteral("rename"), path, [path, dst](const auto &) -> Result {
    if (!QFileInfo::exists(path))
      return {false, QStringLiteral("source does not exist")};
    if (QFileInfo::exists(dst))
      return {false, QStringLiteral("destination already exists")};
    if (::rename(QFile::encodeName(path).constData(),
                 QFile::encodeName(dst).constData()) != 0)
      return {false, QString::fromLocal8Bit(strerror(errno))};
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


#pragma once
#include "FileOperations.h"

#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QRunnable>
#include <QStorageInfo>
#include <QThreadPool>
#include <QUrl>
#include <QUuid>
#include <QVariantMap>

#include <cerrno>
#include <cstdio>
#include <dirent.h>
#include <cstring>
#include <fcntl.h>
#include <linux/fs.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

namespace FileOpsPrivate {

inline constexpr qint64 kChunk = 1 << 20; // 1 MiB

#ifdef OMAFILES_UNIT_TEST
// These hooks exist only in the separately compiled unit-test executable.
// The production backend is built without OMAFILES_UNIT_TEST.
inline std::atomic<qint64> testCopyFailureAfter{-1};
inline std::atomic<qint64> testCancelCopyAfter{-1};
inline std::atomic<bool> testCommitRenameFailure{false};
inline std::atomic<bool> testSourceStageRenameFailure{false};
inline std::atomic<bool> testCreateDestinationBeforeNoReplace{false};
inline std::atomic<bool> testCreateRestoreDestinationBeforeCommit{false};
inline std::atomic<bool> testCreateFileWinnerBeforeCreate{false};
inline std::atomic<bool> testCreateDirectoryWinnerBeforeCreate{false};
inline QString testRemoveFailurePath;
inline QString testCancelRemovePath;
inline QString testSwapRemovePath;
inline QString testSwapRemoveTarget;
inline QString testSwapRemoveBackup;
inline QString testMetadataRemoveFailurePath;
#endif

// Does a directory ENTRY exist at `path`? (lstat, not stat.) Unlike
// QFileInfo::exists() -- which follows symlinks and is therefore blind to a
// broken symlink -- this counts as existing anything that occupies the
// name, including a symlink whose target does not exist. It is the SINGLE
// "destination conflict" criterion shared by existingPaths() (the UI
// check) and the no-overwrite guards of copy()/move(): they previously diverged
// from the shell's `test -e` precisely in the broken-symlink case (BUG-01,
// Hardening-1). Same idiom that removeTree/trash/restore already used below.
inline bool entryExists(const QString &path) {
  struct stat st;
  return ::lstat(QFile::encodeName(path).constData(), &st) == 0;
}

inline bool realDirectoryEntry(const QString &path) {
  struct stat st;
  return ::lstat(QFile::encodeName(path).constData(), &st) == 0 &&
         S_ISDIR(st.st_mode);
}

// Resolve existing parent components, then append the final entry name and any
// non-existent suffix. The final entry is not followed: overwriting a symlink
// replaces that link, not its target. This still catches aliases through a
// symlinked parent when the final path does not exist.
inline QString canonicalizedPath(const QString &path) {
  const QFileInfo entry(QDir::cleanPath(QFileInfo(path).absoluteFilePath()));
  QString probe = QDir::cleanPath(entry.absolutePath());
  QStringList suffix{entry.fileName()};
  while (!entryExists(probe)) {
    const QFileInfo fi(probe);
    const QString parent = QDir::cleanPath(fi.absolutePath());
    if (parent == probe)
      break;
    suffix.prepend(fi.fileName());
    probe = parent;
  }

  QString resolved = QFileInfo(probe).canonicalFilePath();
  if (resolved.isEmpty())
    resolved = QDir::cleanPath(probe);
  for (const QString &component : suffix) {
    if (!component.isEmpty())
      resolved = QDir(resolved).filePath(component);
  }
  return QDir::cleanPath(resolved);
}

inline QStringList pathComponents(const QString &path) {
  return QDir::fromNativeSeparators(QDir::cleanPath(path))
      .split(QLatin1Char('/'), Qt::SkipEmptyParts);
}

inline bool samePathComponents(const QString &a, const QString &b) {
  return pathComponents(a) == pathComponents(b);
}

inline bool descendantPathComponents(const QString &parent,
                                     const QString &candidate) {
  const QStringList p = pathComponents(parent);
  const QStringList c = pathComponents(candidate);
  if (c.size() <= p.size())
    return false;
  for (qsizetype i = 0; i < p.size(); ++i) {
    if (p.at(i) != c.at(i))
      return false;
  }
  return true;
}

inline bool validateTransferPaths(const QString &source,
                                  const QString &destination, QString &err) {
  const QString sourcePath = canonicalizedPath(source);
  const QString destinationPath = canonicalizedPath(destination);
  if (samePathComponents(sourcePath, destinationPath)) {
    err = QStringLiteral("source and destination are the same path");
    return false;
  }
  if (realDirectoryEntry(source) &&
      descendantPathComponents(sourcePath, destinationPath)) {
    err = QStringLiteral("destination is inside the source directory");
    return false;
  }
  return true;
}

inline QString uniqueSiblingPath(const QString &destination,
                                 const QString &role) {
  const QFileInfo destinationInfo(destination);
  const QString prefix = destinationInfo.fileName() + QStringLiteral(".omafiles-") +
                         role + QLatin1Char('-');
  QString candidate;
  do {
    candidate = QDir(destinationInfo.absolutePath())
                    .filePath(prefix + QUuid::createUuid().toString(
                                           QUuid::WithoutBraces));
  } while (entryExists(candidate));
  return candidate;
}

inline QString uniqueHiddenSiblingPath(const QString &entry,
                                       const QString &role) {
  const QFileInfo info(entry);
  return uniqueSiblingPath(
      QDir(info.absolutePath()).filePath(QLatin1Char('.') + info.fileName()), role);
}

inline bool removeTree(const QString &path,
                       const std::atomic<bool> &cancelled, QString &err);

struct CommitOutcome {
  CommitOutcome(bool succeeded = false, bool didCommit = false,
                QString message = {}, QString backupPath = {})
      : ok(succeeded), committed(didCommit), error(std::move(message)),
        backup(std::move(backupPath)) {}

  bool ok = false;
  bool committed = false;
  QString error;
  QString backup;
};

inline bool renameEntry(const QString &source, const QString &destination) {
  return ::rename(QFile::encodeName(source).constData(),
                  QFile::encodeName(destination).constData()) == 0;
}

// Linux is the supported runtime. renameat2 closes the no-overwrite race that
// an entryExists()+rename() pair cannot close.
inline bool renameEntryNoReplace(const QString &source,
                                 const QString &destination) {
#ifdef SYS_renameat2
  return ::syscall(SYS_renameat2, AT_FDCWD,
                   QFile::encodeName(source).constData(), AT_FDCWD,
                   QFile::encodeName(destination).constData(),
                   RENAME_NOREPLACE) == 0;
#else
  Q_UNUSED(source)
  Q_UNUSED(destination)
  errno = ENOTSUP;
  return false;
#endif
}

inline void createRaceWinnerForTest(const QString &destination,
                                    std::atomic<bool> &hook) {
#ifdef OMAFILES_UNIT_TEST
  if (hook.exchange(false)) {
    QFile injected(destination);
    if (injected.open(QIODevice::WriteOnly)) {
      injected.write("race-winner");
      injected.close();
    }
  }
#else
  Q_UNUSED(destination)
  Q_UNUSED(hook)
#endif
}

inline void injectDestinationRaceForTest(const QString &destination) {
#ifdef OMAFILES_UNIT_TEST
  createRaceWinnerForTest(destination, testCreateDestinationBeforeNoReplace);
#else
  Q_UNUSED(destination)
#endif
}

inline void injectRestoreCommitRaceForTest(const QString &destination) {
#ifdef OMAFILES_UNIT_TEST
  createRaceWinnerForTest(destination, testCreateRestoreDestinationBeforeCommit);
#else
  Q_UNUSED(destination)
#endif
}

// Replace destination with an already complete sibling stage. If destination
// exists, keep it as a sibling backup until the stage rename succeeds.
inline CommitOutcome commitStagedReplacement(const QString &stage,
                                             const QString &destination,
                                             bool overwrite,
                                             bool retainBackup = false) {
  QString backup;
  const bool destinationExists = entryExists(destination);
  if (destinationExists && !overwrite)
    return {false, false, QStringLiteral("destination already exists")};

  if (destinationExists) {
    backup = uniqueSiblingPath(destination, QStringLiteral("backup"));
    if (!renameEntry(destination, backup))
      return {false, false, QString::fromLocal8Bit(strerror(errno))};
  }

  injectDestinationRaceForTest(destination);

  bool committed = false;
#ifdef OMAFILES_UNIT_TEST
  if (testCommitRenameFailure.exchange(false)) {
    errno = EIO;
  } else {
    committed = renameEntryNoReplace(stage, destination);
  }
#else
  committed = renameEntryNoReplace(stage, destination);
#endif
  if (!committed) {
    const QString commitError = QString::fromLocal8Bit(strerror(errno));
    if (!backup.isEmpty() && !renameEntryNoReplace(backup, destination)) {
      return {false, false,
              QStringLiteral("commit failed (%1); destination rollback failed (%2); stage retained at %3; old destination retained at %4")
                  .arg(commitError, QString::fromLocal8Bit(strerror(errno)), stage,
                       backup),
              backup};
    }
    return {false, false, QStringLiteral("commit failed: %1").arg(commitError)};
  }

  if (retainBackup)
    return {true, true, QString(), backup};

  if (!backup.isEmpty()) {
    std::atomic<bool> neverCancelled{false};
    QString cleanupError;
    if (!removeTree(backup, neverCancelled, cleanupError))
      return {false, true,
              QStringLiteral("replacement committed; backup retained: %1")
                  .arg(cleanupError),
              backup};
  }
  return {true, true, QString(), QString()};
}

// Total size (recursive) of a path, for the progress percentage.
inline qint64 treeSize(const QString &path) {
  QFileInfo fi(path);
  if (fi.isSymLink())
    return 0;
  if (fi.isDir()) {
    qint64 total = 0;
    QDirIterator it(path, QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden |
                              QDir::System,
                    QDirIterator::Subdirectories);
    while (it.hasNext()) {
      it.next();
      const QFileInfo e = it.fileInfo();
      if (e.isFile() && !e.isSymLink())
        total += e.size();
    }
    return total;
  }
  return fi.size();
}

// Copies a file in chunks, reporting bytes copied via cb.
// `cancelled` is checked between chunks: if it is set, it aborts with err.
inline bool copyFile(const QString &src, const QString &dst, qint64 &copied,
              const std::function<void(qint64)> &cb,
              const std::atomic<bool> &cancelled, QString &err) {
  QFile in(src);
  if (!in.open(QIODevice::ReadOnly)) {
    err = QStringLiteral("cannot read %1").arg(src);
    return false;
  }
  QFile out(dst);
  if (!out.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
    err = QStringLiteral("cannot write %1").arg(dst);
    return false;
  }
  QByteArray buf;
  buf.resize(kChunk);
  qint64 n;
#ifdef OMAFILES_UNIT_TEST
  if (testCopyFailureAfter.load() == 0) {
    err = QStringLiteral("forced copy failure");
    return false;
  }
#endif
  while ((n = in.read(buf.data(), kChunk)) > 0) {
    if (cancelled.load()) {
      err = QStringLiteral("cancelled");
      return false;
    }
    if (out.write(buf.constData(), n) != n) {
      err = QStringLiteral("write failed on %1").arg(dst);
      return false;
    }
    copied += n;
    cb(copied);
#ifdef OMAFILES_UNIT_TEST
    const qint64 cancelAfter = testCancelCopyAfter.load();
    if (cancelAfter >= 0 && copied >= cancelAfter)
      const_cast<std::atomic<bool> &>(cancelled).store(true);
    const qint64 failAfter = testCopyFailureAfter.load();
    if (failAfter >= 0 && copied >= failAfter) {
      err = QStringLiteral("forced copy failure");
      return false;
    }
#endif
  }
  // QFile::read() returns 0 on clean EOF and -1 on a real I/O error -- the
  // loop condition `> 0` exits identically for both, so without this check a
  // mid-copy read failure (dropped network share, failing disk sector) was
  // reported as a successful copy with a silently truncated destination
  // (P0-2, forensic audit 2026-08-16).
  if (n < 0) {
    err = QStringLiteral("read failed on %1: %2").arg(src, in.errorString());
    return false;
  }
  out.close();
  in.close();
  out.setPermissions(in.permissions()); // preserve mode
  return true;
}

inline bool readSymlinkTarget(const QString &path, QByteArray &target,
                              QString &err) {
  const QByteArray encodedPath = QFile::encodeName(path);
  struct stat st {};
  if (::lstat(encodedPath.constData(), &st) != 0) {
    err = QStringLiteral("cannot inspect symlink %1: %2")
              .arg(path, QString::fromLocal8Bit(strerror(errno)));
    return false;
  }
  if (!S_ISLNK(st.st_mode)) {
    err = QStringLiteral("not a symlink: %1").arg(path);
    return false;
  }

  qsizetype capacity = st.st_size > 0 ? static_cast<qsizetype>(st.st_size) + 1 : 1;
  for (;;) {
    target.resize(capacity);
    const ssize_t size =
        ::readlink(encodedPath.constData(), target.data(), target.size());
    if (size < 0) {
      err = QStringLiteral("cannot read symlink %1: %2")
                .arg(path, QString::fromLocal8Bit(strerror(errno)));
      return false;
    }
    if (size < target.size()) {
      target.resize(size);
      return true;
    }
    if (capacity > QByteArray::maxSize() / 2) {
      err = QStringLiteral("symlink target is too long: %1").arg(path);
      return false;
    }
    capacity *= 2;
  }
}

inline bool createSymlink(const QByteArray &target, const QString &path,
                          QString &err) {
  if (::symlink(target.constData(), QFile::encodeName(path).constData()) == 0)
    return true;
  err = QStringLiteral("cannot create symlink %1: %2")
            .arg(path, QString::fromLocal8Bit(strerror(errno)));
  return false;
}

// Recursive copy (files, folders and symlinks as symlinks).
inline bool copyTree(const QString &src, const QString &dst, qint64 &copied,
              const std::function<void(qint64)> &cb,
              const std::atomic<bool> &cancelled, QString &err) {
  if (cancelled.load()) {
    err = QStringLiteral("cancelled");
    return false;
  }
  QFileInfo si(src);
  if (si.isSymLink()) {
    // QFileInfo::symLinkTarget() resolves relative targets to absolute paths.
    // Preserve the bytes stored in the link so its meaning stays relative to
    // the copied link's new parent.
    QByteArray target;
    return readSymlinkTarget(src, target, err) && createSymlink(target, dst, err);
  }
  if (si.isDir()) {
    if (!QDir().mkpath(dst)) {
      err = QStringLiteral("cannot create %1").arg(dst);
      return false;
    }
    const QFileInfoList entries =
        QDir(src).entryInfoList(QDir::AllEntries | QDir::NoDotAndDotDot |
                                QDir::Hidden | QDir::System);
    for (const QFileInfo &e : entries) {
      if (!copyTree(e.absoluteFilePath(), dst + QLatin1Char('/') + e.fileName(),
                    copied, cb, cancelled, err))
        return false;
    }
    return true;
  }
  return copyFile(src, dst, copied, cb, cancelled, err);
}

struct ScopedFd {
  explicit ScopedFd(int descriptor = -1) : fd(descriptor) {}
  ~ScopedFd() {
    if (fd >= 0)
      ::close(fd);
  }
  ScopedFd(const ScopedFd &) = delete;
  ScopedFd &operator=(const ScopedFd &) = delete;
  int fd = -1;
};

inline bool openDirectoryPathNoFollow(const QString &path, ScopedFd &result,
                                      QString &err) {
  QString absolute = QFileInfo(path).canonicalFilePath();
  if (absolute.isEmpty())
    absolute = QDir::cleanPath(QFileInfo(path).absoluteFilePath());
  ScopedFd current(::open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC));
  if (current.fd < 0) {
    err = QStringLiteral("cannot open /: %1")
              .arg(QString::fromLocal8Bit(strerror(errno)));
    return false;
  }
  for (const QString &component : pathComponents(absolute)) {
    const int next = ::openat(current.fd, QFile::encodeName(component).constData(),
                              O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (next < 0) {
      err = QStringLiteral("cannot open directory %1: %2")
                .arg(path, QString::fromLocal8Bit(strerror(errno)));
      return false;
    }
    ::close(current.fd);
    current.fd = next;
  }
  result.fd = current.fd;
  current.fd = -1;
  return true;
}

#ifdef OMAFILES_UNIT_TEST
inline bool matchesRemoveTestPath(const QString &path,
                                  const QString &configured) {
  if (configured.isEmpty())
    return false;
  const QFileInfo actual(QFileInfo(path).absoluteFilePath());
  const QFileInfo expected(QFileInfo(configured).absoluteFilePath());
  return samePathComponents(actual.absoluteFilePath(), expected.absoluteFilePath()) ||
         (samePathComponents(actual.absolutePath(), expected.absolutePath()) &&
          actual.fileName().startsWith(QLatin1Char('.') + expected.fileName() +
                                       QStringLiteral(".omafiles-recovery-")));
}
#endif

inline bool removeTreeEntryAt(int parentFd, const QByteArray &name,
                              const QString &displayPath,
                              const std::atomic<bool> &cancelled, QString &err) {
#ifdef OMAFILES_UNIT_TEST
  if (matchesRemoveTestPath(displayPath, testRemoveFailurePath)) {
    err = QStringLiteral("forced remove failure");
    return false;
  }
  if (matchesRemoveTestPath(displayPath, testCancelRemovePath))
    const_cast<std::atomic<bool> &>(cancelled).store(true);
#endif
  if (cancelled.load()) {
    err = QStringLiteral("cancelled");
    return false;
  }

  struct stat st {};
  if (::fstatat(parentFd, name.constData(), &st, AT_SYMLINK_NOFOLLOW) != 0) {
    err = QStringLiteral("cannot inspect %1: %2")
              .arg(displayPath, QString::fromLocal8Bit(strerror(errno)));
    return false;
  }

#ifdef OMAFILES_UNIT_TEST
  if (S_ISDIR(st.st_mode) && !testSwapRemovePath.isEmpty() &&
      samePathComponents(QFileInfo(displayPath).absoluteFilePath(),
                         QFileInfo(testSwapRemovePath).absoluteFilePath())) {
    const QByteArray backup = QFile::encodeName(testSwapRemoveBackup);
    const QByteArray target = QFile::encodeName(testSwapRemoveTarget);
    if (::renameat(parentFd, name.constData(), AT_FDCWD, backup.constData()) != 0 ||
        ::symlinkat(target.constData(), parentFd, name.constData()) != 0) {
      err = QStringLiteral("forced remove swap failed: %1")
                .arg(QString::fromLocal8Bit(strerror(errno)));
      return false;
    }
    testSwapRemovePath.clear();
  }
#endif

  if (!S_ISDIR(st.st_mode)) {
    if (::unlinkat(parentFd, name.constData(), 0) == 0)
      return true;
    err = QStringLiteral("cannot remove %1: %2")
              .arg(displayPath, QString::fromLocal8Bit(strerror(errno)));
    return false;
  }

  ScopedFd directory(::openat(parentFd, name.constData(),
                              O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
  if (directory.fd < 0) {
    err = QStringLiteral("cannot open directory %1: %2")
              .arg(displayPath, QString::fromLocal8Bit(strerror(errno)));
    return false;
  }
  DIR *entries = ::fdopendir(::dup(directory.fd));
  if (!entries) {
    err = QStringLiteral("cannot list directory %1: %2")
              .arg(displayPath, QString::fromLocal8Bit(strerror(errno)));
    return false;
  }
  for (;;) {
    if (cancelled.load()) {
      ::closedir(entries);
      err = QStringLiteral("cancelled");
      return false;
    }
    errno = 0;
    dirent *entry = ::readdir(entries);
    if (!entry)
      break;
    const QByteArray childName(entry->d_name);
    if (childName == "." || childName == "..")
      continue;
    const QString childPath =
        QDir(displayPath).filePath(QFile::decodeName(childName));
    if (!removeTreeEntryAt(directory.fd, childName, childPath, cancelled, err)) {
      ::closedir(entries);
      return false;
    }
  }
  const int listError = errno;
  ::closedir(entries);
  if (listError != 0) {
    err = QStringLiteral("cannot list directory %1: %2")
              .arg(displayPath, QString::fromLocal8Bit(strerror(listError)));
    return false;
  }
  if (::unlinkat(parentFd, name.constData(), AT_REMOVEDIR) == 0)
    return true;
  err = QStringLiteral("cannot remove directory %1: %2")
            .arg(displayPath, QString::fromLocal8Bit(strerror(errno)));
  return false;
}

// Linux descriptor-relative recursive delete. Every directory component and
// child directory is opened with O_NOFOLLOW, and entries are inspected and
// removed relative to an already-open parent descriptor.
inline bool removeTree(const QString &path, const std::atomic<bool> &cancelled,
                       QString &err) {
  const QFileInfo entry(QDir::cleanPath(QFileInfo(path).absoluteFilePath()));
  if (entry.fileName().isEmpty()) {
    err = QStringLiteral("refusing to remove filesystem root");
    return false;
  }
  ScopedFd parent;
  if (!openDirectoryPathNoFollow(entry.absolutePath(), parent, err))
    return false;
  return removeTreeEntryAt(parent.fd, QFile::encodeName(entry.fileName()),
                           entry.absoluteFilePath(), cancelled, err);
}

// "Forced" delete for the cancellation cleanup: it does NOT check the
// cancellation flag (which is set precisely when we call it) and does not report
// errors -- it is best-effort to remove a partial copy. Phase 13.G.
inline void forceRemove(const QString &path) {
  QFileInfo fi(path);
  if (!fi.exists() && !fi.isSymLink())
    return;
  if (fi.isDir() && !fi.isSymLink())
    QDir(path).removeRecursively();
  else
    QFile::remove(path);
}

struct ValidatedTrashRoot {
  QString root;
  QString files;
  QString info;
};

inline bool directChildByComponents(const QString &parent,
                                    const QString &child) {
  const QStringList p = pathComponents(parent);
  const QStringList c = pathComponents(child);
  if (c.size() != p.size() + 1)
    return false;
  for (qsizetype i = 0; i < p.size(); ++i) {
    if (p.at(i) != c.at(i))
      return false;
  }
  return true;
}

inline bool validateTrashRoot(const QString &candidate,
                              ValidatedTrashRoot &validated) {
  const QString root = QDir::cleanPath(QFileInfo(candidate).absoluteFilePath());
  const QString files = QDir(root).filePath(QStringLiteral("files"));
  const QString info = QDir(root).filePath(QStringLiteral("info"));

  // lstat deliberately does not follow the final component. A symlinked
  // root, files directory, or info directory is never an active trash root.
  if (!realDirectoryEntry(root) || !realDirectoryEntry(files) ||
      !realDirectoryEntry(info))
    return false;

  const QString canonicalRoot = QFileInfo(root).canonicalFilePath();
  const QString canonicalFiles = QFileInfo(files).canonicalFilePath();
  const QString canonicalInfo = QFileInfo(info).canonicalFilePath();
  if (canonicalRoot.isEmpty() || canonicalFiles.isEmpty() ||
      canonicalInfo.isEmpty() ||
      !directChildByComponents(canonicalRoot, canonicalFiles) ||
      !directChildByComponents(canonicalRoot, canonicalInfo))
    return false;

  validated = {canonicalRoot, canonicalFiles, canonicalInfo};
  return true;
}

// Active XDG trash roots. Only roots whose root/files/info entries are real
// directories and whose canonical components remain contained are returned.
inline QList<ValidatedTrashRoot> discoverValidatedTrashRoots() {
  QStringList candidates;
  const QString home = QDir::homePath();
  const QString dataHome =
      qEnvironmentVariable("XDG_DATA_HOME", home + QStringLiteral("/.local/share"));
  candidates << QDir(dataHome).filePath(QStringLiteral("Trash"));

  const QString uid = QString::number(::getuid());
  for (const QStorageInfo &v : QStorageInfo::mountedVolumes()) {
    const QString mp = v.rootPath();
    if (mp.isEmpty() || mp == QLatin1String("/"))
      continue;
    if (samePathComponents(canonicalizedPath(home), canonicalizedPath(mp)) ||
        descendantPathComponents(canonicalizedPath(mp), canonicalizedPath(home)))
      continue;
    candidates << QDir(mp).filePath(QStringLiteral(".Trash-") + uid);
  }

  QList<ValidatedTrashRoot> roots;
  for (const QString &candidate : candidates) {
    ValidatedTrashRoot root;
    if (validateTrashRoot(candidate, root))
      roots.append(root);
  }
  return roots;
}

inline QStringList discoverTrashRoots() {
  QStringList roots;
  for (const ValidatedTrashRoot &root : discoverValidatedTrashRoots())
    roots << root.root;
  return roots;
}

inline bool safeTrashInfoEntry(const QString &path, const QString &infoDir) {
  const QString absolute = QDir::cleanPath(QFileInfo(path).absoluteFilePath());
  struct stat st;
  return directChildByComponents(infoDir, absolute) &&
         ::lstat(QFile::encodeName(absolute).constData(), &st) == 0 &&
         S_ISREG(st.st_mode);
}

inline bool safeTrashPayloadEntry(const QString &path,
                                  const QString &filesDir) {
  const QFileInfo entry(path);
  const QString resolvedParent = QFileInfo(entry.absolutePath()).canonicalFilePath();
  const QString resolvedEntry =
      QDir(resolvedParent).filePath(entry.fileName()); // do not follow payload link
  return !resolvedParent.isEmpty() &&
         directChildByComponents(filesDir, resolvedEntry) && entryExists(path);
}

// Parses a .trashinfo file: fills name/origPath/epoch. `root` is the
// physical root of the trash (to resolve a relative Path= in disk
// trashes). Same decode as restoreByOrigPath (correct percent-decoding).
// Returns false if the file has no Path= (corrupt/incomplete).
inline bool parseTrashInfo(const QFileInfo &infoFile, const QString &root,
                    QString &name, QString &origPath, qint64 &epoch) {
  QFile f(infoFile.absoluteFilePath());
  if (!f.open(QIODevice::ReadOnly))
    return false;
  QString enc, dateStr;
  while (!f.atEnd()) {
    const QByteArray line = f.readLine();
    if (line.startsWith("Path="))
      enc = QString::fromUtf8(line.mid(5)).trimmed();
    else if (line.startsWith("DeletionDate="))
      dateStr = QString::fromUtf8(line.mid(13)).trimmed();
  }
  f.close();
  if (enc.isEmpty())
    return false;

  QString decoded = QUrl::fromPercentEncoding(enc.toUtf8());
  if (!decoded.startsWith(QLatin1Char('/')))
    decoded = QFileInfo(root).absolutePath() + QLatin1Char('/') + decoded;

  // name = stem of the .trashinfo (same as the file in files/).
  name = infoFile.fileName();
  name.chop(QStringLiteral(".trashinfo").size());
  origPath = decoded;
  const QDateTime dt = QDateTime::fromString(dateStr, Qt::ISODate);
  epoch = dt.isValid() ? dt.toSecsSinceEpoch() : 0;
  return true;
}

// Resolves a path to its canonical form, handling non-existent target files by
// resolving their existing parent directory symlinks (e.g. ~/Descargas -> /mnt/Almacen/Descargas).
inline QString canonicalPathForFile(const QString &path) {
  const QFileInfo fi(path);
  const QString canonical = fi.canonicalFilePath();
  if (!canonical.isEmpty())
    return canonical;
  const QDir parentDir(fi.absolutePath());
  const QString parentCanonical = parentDir.canonicalPath();
  if (!parentCanonical.isEmpty())
    return parentCanonical + QLatin1Char('/') + fi.fileName();
  return QDir::cleanPath(path);
}

} // namespace FileOpsPrivate

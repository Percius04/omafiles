#include "DirectoryModel.h"

#include <QFile>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QRunnable>
#include <QThreadPool>

#include <algorithm>

#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {

inline bool asciiDigit(QChar c) {
  return c.unicode() >= u'0' && c.unicode() <= u'9';
}

// Compares names like Utils.naturalCompare(a.toLowerCase(), b.toLowerCase())
// on the QML side: number-aware (ASCII digits are compared by VALUE, not
// character by character) and case-insensitive. Phase 10.A: this is the
// VISIBLE order. Previously it sorted here by glibc collation (byte-for-byte
// parity with list-dir.sh) and then SortOps ALWAYS re-sorted in JS with this
// same naturalCompare, throwing away the C++ work; now it is done once here
// and SortOps no longer re-sorts the default case (name/asc). Returns <0, 0,
// >0.
//
// Phase 27 (PERF_AUDIT_RC1): EXPECTS the two names ALREADY lowercased. std::sort
// does O(n log n) comparisons, so doing `.toLower()` in here
// allocated ~2·n·log n QString per listing (allocation storm measured in
// the benchmark). The toLower is now done ONCE per entry in sortInto
// (Schwartzian transform) and this function operates on the already-lowered keys.
int naturalCompareLowered(const QString &a, const QString &b) {
  int i = 0, j = 0;
  const int na = a.size(), nb = b.size();
  while (i < na && j < nb) {
    const bool da = asciiDigit(a[i]);
    const bool db = asciiDigit(b[j]);
    if (da && db) {
      // Runs of digits: compare as integers (no leading zeros;
      // longer = greater; equal length -> lexicographic).
      int i2 = i, j2 = j;
      while (i2 < na && asciiDigit(a[i2]))
        i2++;
      while (j2 < nb && asciiDigit(b[j2]))
        j2++;
      int sa = i, sb = j;
      while (sa < i2 - 1 && a[sa] == u'0')
        sa++;
      while (sb < j2 - 1 && b[sb] == u'0')
        sb++;
      const int la = i2 - sa, lb = j2 - sb;
      if (la != lb)
        return la - lb;
      const int c = QStringView(a).mid(sa, la).compare(QStringView(b).mid(sb, lb));
      if (c != 0)
        return c;
      i = i2;
      j = j2;
    } else if (da != db) {
      // Digit before non-digit (in JS: number - Infinity < 0).
      return da ? -1 : 1;
    } else {
      // Runs of non-digits: compare with the locale collation (like the
      // .localeCompare() of JS).
      int i2 = i, j2 = j;
      while (i2 < na && !asciiDigit(a[i2]))
        i2++;
      while (j2 < nb && !asciiDigit(b[j2]))
        j2++;
      const int c =
          QString::localeAwareCompare(a.mid(i, i2 - i), b.mid(j, j2 - j));
      if (c != 0)
        return c;
      i = i2;
      j = j2;
    }
  }
  return (na - i) - (nb - j);
}

// Scans ONE directory and APPENDs its entries to dirs/files (without
// sorting; the caller sorts once at the end). Returns the error
// code mirroring list-dir.sh: 0 ok, 2 no permission, 3 does not exist, 4 not a
// folder, 1 other. In an aggregate listing (trash) the caller ignores the
// code and simply skips the folders that fail.
int gatherOne(const QByteArray &p, bool showHidden,
              QVector<DirectoryModel::Entry> &dirs,
              QVector<DirectoryModel::Entry> &files,
              bool includePath = false) {
  // stat/-d/-r-x follow symlinks just like the script's bash tests.
  struct stat st;
  if (::stat(p.constData(), &st) != 0)
    return 3; // does not exist (-e false; includes a dangling symlink)
  if (!S_ISDIR(st.st_mode))
    return 4; // not a folder (-d false)
  if (::access(p.constData(), R_OK | X_OK) != 0)
    return 2; // no read/execute permission
  DIR *dir = ::opendir(p.constData());
  if (!dir)
    return 1; // other (equivalent to the cd that failed)

  struct dirent *de;
  while ((de = ::readdir(dir)) != nullptr) {
    const char *n = de->d_name;
    // Always skip "." and "..".
    if (n[0] == '.' && (n[1] == '\0' || (n[1] == '.' && n[2] == '\0')))
      continue;
    // Dotfiles only with showHidden (equivalent to the script's shopt dotglob).
    if (!showHidden && n[0] == '.')
      continue;

    QByteArray full = p;
    full += '/';
    full += n;

    // Phase 27 (PERF_AUDIT_RC1): a single syscall in the common case. Before,
    // lstat + stat were done ALWAYS (2 syscalls/entry -> 200k at 100k files).
    // For a NON-symlink stat==lstat, so the second was redundant: lstat is
    // done first and only followed by stat when there really is a
    // link to resolve. Behaviour identical (a path that stat resolves
    // but lstat does not is impossible: lstat still resolves the path, it just
    // does not deref the last component).
    struct stat ls;
    const bool lok = (::lstat(full.constData(), &ls) == 0);
    const bool isLink = lok && S_ISLNK(ls.st_mode);
    struct stat s;
    bool followed;
    if (isLink) {
      followed = (::stat(full.constData(), &s) == 0); // follow the link
    } else {
      s = ls; // non-symlink: lstat is already the stat, no second syscall
      followed = lok;
    }

    DirectoryModel::Entry e;
    e.name = QFile::decodeName(n);
    if (includePath)
      e.path = QFileInfo(QFile::decodeName(full)).absoluteFilePath();
    e.isSymlink = isLink;
    e.link = isLink ? (followed ? QStringLiteral("valid")
                                : QStringLiteral("broken"))
                    : QString();
    e.isDir = followed && S_ISDIR(s.st_mode);

    if (e.isDir) {
      e.type = QStringLiteral("dir");
      e.size = 0; // the script forces size 0 on folders
      e.mtime = static_cast<qint64>(s.st_mtime);
      dirs.push_back(std::move(e));
    } else {
      e.type = QStringLiteral("file");
      if (followed) {
        // Normal file or symlink that resolves: data of the target.
        e.size = static_cast<qint64>(s.st_size);
        e.mtime = static_cast<qint64>(s.st_mtime);
      } else if (lok) {
        // Broken symlink: fallback to lstat (size = length of the target,
        // mtime = of the link itself), like the `stat -c` without -L.
        e.size = static_cast<qint64>(ls.st_size);
        e.mtime = static_cast<qint64>(ls.st_mtime);
      } else {
        e.size = 0;
        e.mtime = 0;
      }
      files.push_back(std::move(e));
    }
  }
  ::closedir(dir);
  return 0;
}

// Sorts ONE group by name (case-insensitive, number-aware) with a
// Schwartzian transform: lowercases each name ONCE, sorts
// a vector of indices over those precomputed keys, and reorders the group with
// a single sweep of moves at the end. Before the toLower lived
// inside the comparator, which std::sort calls O(n log n) times -> at 100k it
// was ~1.7M comparisons × 2 toLower = allocation storm.
void sortGroup(QVector<DirectoryModel::Entry> &v) {
  const int n = v.size();
  if (n < 2)
    return;
  QVector<QString> keys(n);
  for (int i = 0; i < n; ++i)
    keys[i] = v[i].name.toLower();
  QVector<int> idx(n);
  for (int i = 0; i < n; ++i)
    idx[i] = i;
  std::sort(idx.begin(), idx.end(), [&keys, &v](int a, int b) {
    const int byName = naturalCompareLowered(keys[a], keys[b]);
    if (byName != 0)
      return byName < 0;
    // listMany() can contain equal display names from different trash roots.
    // Their exact payload paths make the order deterministic and preserve both
    // identities in signatures. Normal rows have empty paths and stay compatible.
    return v[a].path < v[b].path;
  });
  QVector<DirectoryModel::Entry> out;
  out.reserve(n);
  for (int i : idx)
    out.push_back(std::move(v[i]));
  v = std::move(out);
}

// Sorts dirs and files by name (folders first when concatenating) with the
// glibc collation, and leaves them in rows.
void sortInto(QVector<DirectoryModel::Entry> &dirs,
              QVector<DirectoryModel::Entry> &files,
              QVector<DirectoryModel::Entry> &rows) {
  sortGroup(dirs);
  sortGroup(files);
  rows = std::move(dirs); // folders first, then files
  rows += files;
}

// 64-bit hash (FNV-1a) of the VISIBLE content of the listing, in order. Covers
// exactly the fields that Utils.entriesEqual compared and that would decide a
// relayout: name, size, mtime, isDir (type) and link. Runs on the worker thread.
// Phase 27 (PERF_AUDIT_RC1). Returned as hex so QML compares it as a
// string (a JS double does not represent 64 exact bits).
QString signatureOf(const QVector<DirectoryModel::Entry> &rows) {
  quint64 h = 1469598103934665603ULL; // FNV-1a offset basis
  const auto mix = [&h](quint64 v) {
    h ^= v;
    h *= 1099511628211ULL; // FNV-1a prime
  };
  mix(static_cast<quint64>(rows.size()));
  for (const DirectoryModel::Entry &e : rows) {
    for (QChar c : e.name)
      mix(c.unicode());
    mix(0x1F); // field separator (avoids collisions by concatenation)
    for (QChar c : e.path)
      mix(c.unicode());
    mix(0x1E);
    mix(static_cast<quint64>(e.size));
    mix(static_cast<quint64>(e.mtime));
    mix(e.isDir ? 1u : 0u);
    // link: "" -> 0, "valid" -> 1, "broken" -> 2
    mix(e.link.isEmpty() ? 0u
                         : (e.link == QLatin1String("valid") ? 1u : 2u));
  }
  return QString::number(h, 16);
}

} // namespace

DirectoryModel::DirectoryModel(QObject *parent) : QObject(parent) {}

DirectoryModel::~DirectoryModel() {
  // Cut off the delivery of any in-flight worker: under the lock, mark it
  // dead. A worker that has not delivered yet will see alive=false and will not
  // do invokeMethod(this); one that already holds it blocks us here until
  // it releases (instant delivery, it only posts an event).
  std::lock_guard<std::mutex> lk(m_life->mtx);
  m_life->alive = false;
}

DirectoryModel::Result DirectoryModel::scan(const QString &path,
                                            bool showHidden) {
  Result r;
  QVector<Entry> dirs, files;
  r.error = gatherOne(QFile::encodeName(path), showHidden, dirs, files);
  if (r.error == 0)
    sortInto(dirs, files, r.rows);
  r.signature = signatureOf(r.rows); // on the worker, not on the UI
  return r;
}

DirectoryModel::Result DirectoryModel::scanMany(const QStringList &paths,
                                                bool showHidden) {
  // Trash: merges the content of several roots. The ones that fail (do not
  // exist / no permission) are skipped silently, like the
  // `[[ -d "$root/files" ]] &&` of list-trash.sh. error always 0.
  Result r;
  QVector<Entry> dirs, files;
  for (const QString &path : paths)
    gatherOne(QFile::encodeName(path), showHidden, dirs, files, true);
  sortInto(dirs, files, r.rows);
  r.signature = signatureOf(r.rows);
  return r;
}

void DirectoryModel::startScan(std::function<Result()> job) {
  const quint64 generation = ++m_generation;
  // The heavy scan (stat of each entry) goes to a pool thread so as not to
  // block the UI; the result is applied back on the UI thread. A
  // result of an old generation (fast navigation) is discarded.
  auto life = m_life; // copy of the control block, outlives the model
  QThreadPool::globalInstance()->start(QRunnable::create(
      [this, life, job = std::move(job), generation]() {
        Result result = job();
        // Safe delivery: only invoke on `this` if it is still alive. The
        // destructor takes this same lock, so either we see alive=false (and do
        // not touch the dead object), or we hold it and the destructor
        // waits for us to release.
        std::lock_guard<std::mutex> lk(life->mtx);
        if (!life->alive)
          return;
        QMetaObject::invokeMethod(
            this,
            [this, result = std::move(result), generation]() mutable {
              apply(std::move(result), generation);
            },
            Qt::QueuedConnection);
      }));
}

void DirectoryModel::list(const QString &path, bool showHidden) {
  startScan([path, showHidden]() { return scan(path, showHidden); });
}

void DirectoryModel::listMany(const QStringList &paths, bool showHidden) {
  // Aggregate of several roots (trash). The consumers use the
  // `entries` array (name/type/size/mtime/link) + trashInfo.
  startScan([paths, showHidden]() { return scanMany(paths, showHidden); });
}

bool DirectoryModel::watch(const QString &path) {
  if (!m_watcher) {
    m_watcher = new QFileSystemWatcher(this);
    // QFileSystemWatcher uses the kernel inotify directly. It re-emits directoryChanged();
    // the debounce + refresh with rename-guard stay in NavigationController.
    connect(m_watcher, &QFileSystemWatcher::directoryChanged, this,
            [this](const QString &changed) {
              // Cancellation token: only propagate the event if it is from the
              // folder being watched NOW. A late event from an old
              // watcher (different path) is discarded -> it does not repopulate
              // the folder the user has already navigated to.
              if (changed == m_watchedPath)
                emit directoryChanged();
            });
  }
  // Watch only one directory at a time: remove the previous one.
  const QStringList prev = m_watcher->directories();
  if (!prev.isEmpty())
    m_watcher->removePaths(prev);
  m_watchedPath = path;
  return m_watcher->addPath(path); // false if it could not (limit/path)
}

void DirectoryModel::unwatch() {
  // Invalidate the token: any in-flight event from a previous watcher will
  // be discarded on not matching m_watchedPath (empty).
  m_watchedPath.clear();
  if (!m_watcher)
    return;
  const QStringList prev = m_watcher->directories();
  if (!prev.isEmpty())
    m_watcher->removePaths(prev);
}

void DirectoryModel::apply(Result result, quint64 generation) {
  // Discard if another listing was already requested after this one.
  if (generation != m_generation)
    return;

  m_rows = std::move(result.rows);
  m_signature = std::move(result.signature);

  if (m_error != result.error) {
    m_error = result.error;
    emit errorChanged();
  }
  emit listed();
}

QVariantList DirectoryModel::entries() const {
  QVariantList out;
  out.reserve(m_rows.size());
  for (const Entry &e : m_rows) {
    // Same five keys that Utils.parseEntries(list-dir.sh) produced,
    // to compare and, later, replace without the consumer changing.
    QVariantMap m;
    m[QStringLiteral("type")] = e.type;
    m[QStringLiteral("name")] = e.name;
    m[QStringLiteral("size")] = e.size;
    m[QStringLiteral("mtime")] = e.mtime;
    m[QStringLiteral("link")] = e.link;
    if (!e.path.isEmpty())
      m[QStringLiteral("path")] = e.path;
    out.push_back(m);
  }
  return out;
}

#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVector>
#include <functional>
#include <memory>
#include <mutex>
#include <qqmlregistration.h>

class QFileSystemWatcher;

// Asynchronous directory listing and file system watching.
// replacement for list-dir.sh + Utils.parseEntries: it scans with direct
// readdir/stat/lstat, without a fork per file nor a NUL-delimited shell pipe.
// See BACKEND_DESIGN.md 5.3.
//
// DATA PROVIDER, not a Qt model: the architectural
// decision of AUDIT-V2 was Option B. The UI NEVER consumed this as
// ListView.model -- `NavState.entries` (the real list model) is
// fed from FOUR heterogeneous sources (normal dir, recursive search,
// file content, trash), which produce arrays; a QAbstractListModel
// could not represent the last three. So this type exposes only the
// `entries` array (+error/watch) and the dead roles, the
// QAbstractListModel and its interface (rowCount/data/roleNames) were removed.
// Measured: the scan dominates (~80% of the listing at 50k); the only cost that
// a model-with-roles would have avoided (building the QVariantList) is <20% and
// only in rare folders >10k. See the table in the AUDIT-V2 revalidation.
//
// EXACT parity with list-dir.sh (which is what allows comparing and, later,
// replacing without changing behaviour):
//   - folders first, then files;
//   - within each group, case-insensitive order with the SAME glibc
//     collation that `sort -f` uses (wcscoll_l over a locale_t from the env);
//   - a symlink to a dir counts as a dir; a broken one goes to files with the
//     link's own size/mtime (lstat), state "broken";
//   - folder size forced to 0, like the script;
//   - error codes equivalent to the exit codes (2/3/4/1).
//
// It is registered as the QML type Omafiles.Backend.DirectoryModel; consumed by
// list different paths at once, each its own instance).
class DirectoryModel : public QObject {
  Q_OBJECT
  QML_ELEMENT

  // Code of the last listing, with the SAME values as the exit codes
  // of list-dir.sh so logic/ can map them the same:
  //   0 = ok, 2 = no permission (r/x), 3 = does not exist, 4 = not a folder,
  //   1 = other (could not open).
  Q_PROPERTY(int error READ error NOTIFY errorChanged)

  // Snapshot of the rows as an array of objects {type,name,size,mtime,
  // link} -- EXACTLY the shape that the rest of NavState.entries's sources
  // produce (SearchWorker, file content, trash). It is the
  // ONLY data API: the UI sorts it and sets it as ListView.model.
  Q_PROPERTY(QVariantList entries READ entries NOTIFY listed)

  // CONTENT signature of the last listing (hex of a 64-bit hash over
  // name/size/mtime/type/link of all the rows, in order). Phase 27
  // (PERF_AUDIT_RC1): it lets DirLister decide "did the folder change or not?"
  // with an O(1) string comparison on the UI thread, instead of the
  // O(n) Utils.entriesEqual that iterated the 100k entries and, in doing so,
  // FORCED the lazy materialization of the whole array (measured: 342 ms of
  // UI blocking at 100k per refresh). The hash is computed on the worker thread,
  // during the scan that already ran there. Collision -> visual refresh lost
  // until the next event (never corruption); 64 bits makes it
  // practically impossible for this use.
  Q_PROPERTY(QString signature READ signature NOTIFY listed)

public:
  explicit DirectoryModel(QObject *parent = nullptr);
  ~DirectoryModel() override;

  // A listing entry. Public because the scan functions of the
  // .cpp (gatherOne/sortInto) handle it by value; it exposes nothing
  // sensitive, it is a data POD.
  struct Entry {
    QString name;
    // Exact absolute payload identity for aggregate listMany() rows. Empty for
    // normal list() rows to keep their public shape compatible.
    QString path;
    QString type; // "dir" | "file"
    QString link; // "" | "valid" | "broken"
    bool isDir = false;
    qint64 size = 0;
    qint64 mtime = 0;
  };

  // Launches the ASYNCHRONOUS listing of `path`. `showHidden` includes
  // dotfiles. Returns immediately; the scan runs on a pool thread and the
  // result is applied on the UI thread (listed()/errorChanged). A
  // listing that arrives with an old generation is discarded (generation
  // counter, project pattern: PreviewLoader/previewRequestId).
  Q_INVOKABLE void list(const QString &path, bool showHidden = false);

  // Like list() but merges the content of SEVERAL directories into a
  // single listing. Replaces list-trash.sh,
  // which did the same by launching list-dir.sh for each XDG root and
  // concatenating. Directories that do not exist or cannot be read are
  // skipped silently (like the script's `[[ -d ]] &&`). Same
  // async contract and same listed()/entries signal.
  Q_INVOKABLE void listMany(const QStringList &paths, bool showHidden = false);

  // Native watching of the last requested directory via QFileSystemWatcher.
  // Emits directoryChanged() when its content changes; the debounce + refresh
  // are handled in NavigationController.
  Q_INVOKABLE bool watch(const QString &path);
  // Stops watching. No-op if there was no watching.
  Q_INVOKABLE void unwatch();

  int error() const { return m_error; }
  QVariantList entries() const;
  QString signature() const { return m_signature; }

signals:
  void errorChanged();
  // Emitted every time a listing is actually applied (parity with
  // DirLister.listed): whoever resets scroll/selection on EACH listing hooks
  // here, not to a *Changed that QML might not fire.
  void listed();
  // The content of the watched directory changed (see watch()).
  void directoryChanged();

private:
  struct Result {
    int error = 0;
    QVector<Entry> rows;
    QString signature; // content hash, computed on the worker
  };

  // Runs on the worker thread: scans ONE directory (error
  // checks + readdir + stat/lstat + order). Static on purpose: it touches
  // neither the model nor any member, so it is safe even if the model is
  // destroyed while the thread runs. Creates its own locale_t per call.
  static Result scan(const QString &path, bool showHidden);
  // Same, but merges several directories (trash). The ones that fail are
  // skipped; error always 0 (aggregate, without the concept of "this folder
  // failed").
  static Result scanMany(const QStringList &paths, bool showHidden);
  // Runs on the UI thread: replaces the rows and emits the signals.
  void apply(Result result, quint64 generation);
  // Launches a scan (one or several dirs) on the pool and applies async.
  void startScan(std::function<Result()> job);

  int m_error = 0;
  QVector<Entry> m_rows;
  QString m_signature;      // content signature of the last applied listing
  quint64 m_generation = 0; // last requested generation (scan)

  // Life flag shared with the pool workers. The
  // scan is static, but the DELIVERY of the result does
  // invokeMethod(this): if the model is destroyed (closing a tab)
  // while a worker is still in flight, that would dereference a dead
  // QObject. The worker takes the lock and only invokes if alive is still true;
  // the destructor takes the same lock and sets it to false, so they never
  // coincide.
  struct Life {
    std::mutex mtx;
    bool alive = true;
  };
  std::shared_ptr<Life> m_life = std::make_shared<Life>();

  QFileSystemWatcher *m_watcher = nullptr; // native watching (lazy)
  // The path watched RIGHT NOW: acts as a cancellation token for the
  // watcher, the equivalent of m_generation for the scan. An event from
  // QFileSystemWatcher whose path is not this one is from an old watcher (the
  // user changed folder) and is discarded before re-emitting
  // directoryChanged, so it does not repopulate the new folder.
  QString m_watchedPath;
};

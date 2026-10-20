#pragma once

#include <QObject>
#include <QString>
#include <QVariantList>
#include <atomic>
#include <memory>
#include <mutex>
#include <qqmlregistration.h>

// Native recursive search. Replacement for
// search-recursive.sh: walks `root` breadth first, filters by substring
// (case-insensitive) over the file/folder NAME, skips
// hidden ones unless showHidden, prunes known dependency/cache contents, and
// returns the best 200 entries with the same
// shape as DirectoryModel ({type,name,size,mtime,link}) -- `name` is the path
// RELATIVE to root, so the rest of the code (join with currentPath,
// rename, delete, open...) works the same as with the script.
//
// Async (QThreadPool) and cancelable: each search() opens a "generation"; a
// new search or cancel() invalidates the previous one (neither walks too much
// nor emits obsolete results). Filename search keeps a ranked, bounded top
// 200 while continuing the cancellable walk; any further match sets truncated.
// Content search uses the existing 201st-match sentinel and trims to 200.
// Delivery rechecks the generation on the receiver thread as well as enqueue.
//
// Instantiable (QML_ELEMENT, like DirectoryModel/ProcessRunner): SearchOps
// has its own instance. No dependency on Quickshell.
class SearchWorker : public QObject {
  Q_OBJECT
  QML_ELEMENT

public:
  explicit SearchWorker(QObject *parent = nullptr);
  ~SearchWorker() override;

  // Launches a recursive search by file/folder name under `root`.
  Q_INVOKABLE void search(const QString &root, const QString &query,
                          bool showHidden);

  // Launches a recursive content search INSIDE files under `root`.
  // Searches for text matches line by line (case-insensitive).
  // Skips binary files and files larger than 5 MB.
  Q_INVOKABLE void searchContent(const QString &root, const QString &query,
                                 bool showHidden);

  // Cancels the search in progress (invalidates its generation): no result
  // is emitted. Idempotent.
  Q_INVOKABLE void cancel();

signals:
  // Results of the last active search. `entries` are objects
  // {type,name,size,mtime,link}; `truncated` = more than 200 matches.
  // Legacy final-only signal, retained for existing callers/selfchecks.
  void results(const QVariantList &entries, bool truncated);
  // Progressive name snapshots; content emits one complete=true snapshot.
  void snapshot(const QVariantList &entries, bool truncated, bool complete);

private:
  // Generation of the active search. search() increments and captures it;
  // the worker discards (does not emit) if it stopped being the active one --
  // covers both cancel() and a search that supersedes another.
  //
  // Heap-allocated and shared (not a plain member), P0 concurrency audit
  // (forensic audit 2026-08-16): the scan loop below used to check
  // `this->m_gen` directly, on every single iterated entry, for the ENTIRE
  // duration of a potentially long recursive scan -- all of it BEFORE the
  // Life/mutex guard is ever consulted (that only guards the final result
  // delivery). Destroying the worker (e.g. closing the tab/panel that owns
  // it) while a scan was still walking a large tree was a confirmed
  // use-after-free (reproduced with AddressSanitizer). The worker lambda now
  // captures its own shared_ptr copy of this counter and never needs `this`
  // to check it, so the check stays valid regardless of whether the
  // SearchWorker itself still exists.
  std::shared_ptr<std::atomic<quint64>> m_gen =
      std::make_shared<std::atomic<quint64>>(0);

  // Life guard against the dangling `this` (same pattern as
  // DirectoryModel/FileOperations): a worker that finishes after the object is
  // destroyed would check `alive` under the mutex before delivering.
  struct Life {
    std::mutex mtx;
    bool alive = true;
  };
  std::shared_ptr<Life> m_life = std::make_shared<Life>();
};

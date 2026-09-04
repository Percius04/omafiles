#pragma once

#include <QFileSystemWatcher>
#include <QObject>
#include <QStringList>
#include <qqmlregistration.h>

// Thin QML wrapper over QFileSystemWatcher: `paths` (files or directories)
// to watch, `changed` on any event. Paths are re-armed after every event
// because Qt drops a watch when the file is replaced (write-to-temp + mv)
// and a path can only be added once it exists -- so watching the parent
// directory of a not-yet-created file is enough to pick it up later.
class FileWatcher : public QObject {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QStringList paths READ paths WRITE setPaths NOTIFY pathsChanged)

public:
  explicit FileWatcher(QObject *parent = nullptr);

  QStringList paths() const;
  void setPaths(const QStringList &paths);

signals:
  void pathsChanged();
  void changed(const QString &path);

private:
  void arm();

  QFileSystemWatcher m_watcher;
  QStringList m_paths;
};

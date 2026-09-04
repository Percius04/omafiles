#include "FileWatcher.h"

#include <QFileInfo>

FileWatcher::FileWatcher(QObject *parent) : QObject(parent) {
  auto onEvent = [this](const QString &path) {
    arm();
    emit changed(path);
  };
  connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, onEvent);
  connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, onEvent);
}

QStringList FileWatcher::paths() const { return m_paths; }

void FileWatcher::setPaths(const QStringList &paths) {
  if (paths == m_paths)
    return;
  m_paths = paths;
  const QStringList old = m_watcher.files() + m_watcher.directories();
  if (!old.isEmpty())
    m_watcher.removePaths(old);
  arm();
  emit pathsChanged();
}

// Adds every existing path that is not already watched.
void FileWatcher::arm() {
  const QStringList active = m_watcher.files() + m_watcher.directories();
  for (const QString &p : m_paths)
    if (!active.contains(p) && QFileInfo::exists(p))
      m_watcher.addPath(p);
}

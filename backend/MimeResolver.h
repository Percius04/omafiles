#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <qqmlregistration.h>

// High-speed native MIME resolution and application launching
// Replaces open-with-list.sh and gtk-launch
class MimeResolver : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
public:
  explicit MimeResolver(QObject *parent = nullptr);

  // Returns a list of maps: [{"name": "Foo", "id": "foo.desktop"}, ...]
  Q_INVOKABLE QVariantList getAppsForFile(const QString &path);

  // Launches an application via its desktop ID
  Q_INVOKABLE void launchApp(const QString &desktopId, const QString &path);

private:
  // Launches a Terminal=true app inside the user's terminal emulator.
  void startInTerminal(const QString &program, const QStringList &args);
};

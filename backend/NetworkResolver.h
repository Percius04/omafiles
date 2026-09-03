#pragma once

#include <QObject>
#include <QString>
#include <qqmlregistration.h>

class NetworkResolver : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON

public:
  explicit NetworkResolver(QObject *parent = nullptr);
  ~NetworkResolver() override;

  // Normalizes and attempts to mount the given URL (sftp, smb, ftp, dav, etc)
  Q_INVOKABLE void mountUrl(const QString &url);

  // Submits credentials after an authRequested signal
  Q_INVOKABLE void submitAuth(const QString &username, const QString &password, bool rememberSession);

  // Cancels the ongoing authentication request
  Q_INVOKABLE void cancelAuth();

  // Disconnects an active mount
  Q_INVOKABLE void disconnectMount(const QString &url);

Q_SIGNALS:
  // Emitted when the server requires credentials (ephemeral interaction)
  void authRequested(const QString &message, const QString &defaultUser);

  // Emitted when the mount completes (success or failure). On success
  // `localPath` is the gvfs FUSE path of the mount ROOT and `homePath` is
  // the FUSE path of the mount's DEFAULT location (remote home dir for
  // sftp, reachable /-equivalent for the others -- what Nautilus opens);
  // both are empty on failure.
  void mountFinished(bool success, const QString &errorMessage, const QString &localPath, const QString &homePath);

  // Emitted when a disconnect completes
  void disconnectFinished(bool success, const QString &errorMessage);

private:
  class Private;
  Private *d;
};

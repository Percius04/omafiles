#include "NetworkResolver.h"

#include "GioCompat.h"

#include <QDebug>
#include <QUrl>

class NetworkResolver::Private {
public:
  NetworkResolver *q;
  GMountOperation *currentOp = nullptr;

  static void onAskPassword(GMountOperation *op, const gchar *message, const gchar *defaultUser, const gchar *defaultDomain, GAskPasswordFlags flags, gpointer userData) {
    Q_UNUSED(defaultDomain)
    Q_UNUSED(flags)
    auto *self = static_cast<NetworkResolver::Private *>(userData);
    self->currentOp = op; // Store the active operation waiting for credentials
    emit self->q->authRequested(QString::fromUtf8(message), QString::fromUtf8(defaultUser));
  }

  static void onMountDone(GObject *source, GAsyncResult *res, gpointer userData) {
    auto *self = static_cast<NetworkResolver::Private *>(userData);
    GError *error = nullptr;
    gboolean success = g_file_mount_enclosing_volume_finish(G_FILE(source), res, &error);
    
    QString localPath;
    if (success) {
      GMount *mount = g_file_find_enclosing_mount(G_FILE(source), nullptr, nullptr);
      if (mount) {
        GFile *root = g_mount_get_root(mount);
        char *path = g_file_get_path(root);
        if (path) {
          localPath = QString::fromUtf8(path);
          g_free(path);
        }
        g_object_unref(root);
        g_object_unref(mount);
      }
    }

    QString errorMsg = error ? QString::fromUtf8(error->message) : QString();
    if (error) g_error_free(error);

    self->currentOp = nullptr;
    emit self->q->mountFinished(success, errorMsg, localPath);
    
    // Clean up
    g_object_unref(source);
  }

  static void onUnmountDone(GObject *source, GAsyncResult *res, gpointer userData) {
    auto *self = static_cast<NetworkResolver::Private *>(userData);
    GError *error = nullptr;
    gboolean success = g_mount_unmount_with_operation_finish(G_MOUNT(source), res, &error);
    
    QString errorMsg = error ? QString::fromUtf8(error->message) : QString();
    if (error) g_error_free(error);

    emit self->q->disconnectFinished(success, errorMsg);
    g_object_unref(source);
  }
};

NetworkResolver::NetworkResolver(QObject *parent) : QObject(parent), d(new Private{this}) {}

NetworkResolver::~NetworkResolver() {
  delete d;
}

void NetworkResolver::mountUrl(const QString &url) {
  // Normalize URL
  QUrl parsed(url);
  if (parsed.scheme().isEmpty()) {
    // If user typed "10.0.0.1/share", default to smb
    parsed.setScheme(QStringLiteral("smb"));
  }

  GFile *file = g_file_new_for_uri(parsed.toString().toUtf8().constData());
  GMountOperation *op = g_mount_operation_new();
  
  g_signal_connect(op, "ask-password", G_CALLBACK(Private::onAskPassword), d);

  g_file_mount_enclosing_volume(file, G_MOUNT_MOUNT_NONE, op, nullptr, Private::onMountDone, d);
  
  g_object_unref(op);
  // GFile is unref'd in onMountDone
}

void NetworkResolver::submitAuth(const QString &username, const QString &password, bool rememberSession) {
  if (!d->currentOp) return;
  
  g_mount_operation_set_username(d->currentOp, username.toUtf8().constData());
  g_mount_operation_set_password(d->currentOp, password.toUtf8().constData());
  g_mount_operation_set_password_save(d->currentOp, rememberSession ? G_PASSWORD_SAVE_FOR_SESSION : G_PASSWORD_SAVE_NEVER);
  
  g_mount_operation_reply(d->currentOp, G_MOUNT_OPERATION_HANDLED);
  d->currentOp = nullptr;
}

void NetworkResolver::cancelAuth() {
  if (!d->currentOp) return;
  
  g_mount_operation_reply(d->currentOp, G_MOUNT_OPERATION_ABORTED);
  d->currentOp = nullptr;
}

void NetworkResolver::disconnectMount(const QString &url) {
  GFile *file = g_file_new_for_uri(url.toUtf8().constData());
  GError *error = nullptr;
  GMount *mount = g_file_find_enclosing_mount(file, nullptr, &error);
  
  if (mount) {
    g_mount_unmount_with_operation(mount, G_MOUNT_UNMOUNT_NONE, nullptr, nullptr, Private::onUnmountDone, d);
  } else {
    QString errorMsg = error ? QString::fromUtf8(error->message) : QStringLiteral("Not mounted");
    if (error) g_error_free(error);
    emit disconnectFinished(false, errorMsg);
  }
  
  g_object_unref(file);
}

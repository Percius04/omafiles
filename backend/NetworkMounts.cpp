#include "NetworkMounts.h"

#include "GioCompat.h"

#include <QDir>
#include <QFileInfo>
#include <QUrl>
#include <QVariantMap>

#include <unistd.h>

NetworkMounts::NetworkMounts(QObject *parent) : QObject(parent) {}

QVariantList NetworkMounts::list() const {
  QVariantList out;
  const QString runtime = qEnvironmentVariable(
      "XDG_RUNTIME_DIR",
      QStringLiteral("/run/user/%1").arg(::getuid()));
  QDir gvfs(runtime + QStringLiteral("/gvfs"));
  if (!gvfs.exists())
    return out;

  const auto dirs = gvfs.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot);
  for (const QFileInfo &fi : dirs) {
    // Internal mount name: "scheme:key=value,key=value,...".
    const QString name = fi.fileName();
    const int colon = name.indexOf(QLatin1Char(':'));
    const QString scheme = colon >= 0 ? name.left(colon) : name;
    const QString rest = colon >= 0 ? name.mid(colon + 1) : QString();

    // The values in the gvfs mount name come percent-encoded (a
    // "My Share" resource is share=My%20Share). They are decoded natively
    // with QUrl::fromPercentEncoding (UTF-8-aware) so the sidebar label
    // comes out readable.
    QString host, share, user;
    const auto pairs = rest.split(QLatin1Char(','), Qt::SkipEmptyParts);
    for (const QString &pair : pairs) {
      if (pair.startsWith(QLatin1String("host=")))
        host = QUrl::fromPercentEncoding(pair.mid(5).toUtf8());
      else if (pair.startsWith(QLatin1String("server=")))
        host = QUrl::fromPercentEncoding(pair.mid(7).toUtf8());
      else if (pair.startsWith(QLatin1String("share=")))
        share = QUrl::fromPercentEncoding(pair.mid(6).toUtf8());
      else if (pair.startsWith(QLatin1String("user=")))
        user = QUrl::fromPercentEncoding(pair.mid(5).toUtf8());
    }

    QString proto;
    if (scheme == QLatin1String("sftp"))
      proto = QStringLiteral("SFTP");
    else if (scheme == QLatin1String("ftp") || scheme == QLatin1String("ftps"))
      proto = QStringLiteral("FTP");
    else if (scheme == QLatin1String("dav") || scheme == QLatin1String("davs"))
      proto = QStringLiteral("WebDAV");
    else if (scheme == QLatin1String("smb-share") ||
             scheme == QLatin1String("smb"))
      proto = QStringLiteral("SMB");
    else
      proto = scheme;

    QString label = proto + QStringLiteral(": ") + (host.isEmpty() ? name : host);
    if (!share.isEmpty())
      label += QLatin1Char('/') + share;
    if (!user.isEmpty())
      label += QStringLiteral(" (") + user + QLatin1Char(')');

    QVariantMap m;
    m[QStringLiteral("label")] = label;
    m[QStringLiteral("path")] = fi.absoluteFilePath();
    m[QStringLiteral("scheme")] = scheme;

    // Real mount URI (scheme://host), NOT the local gvfs FUSE path.
    // Unmounting needs the URI: a local path has no enclosing GVolume
    // mount, so g_file_find_enclosing_mount on it fails with
    // "Containing mount doesn't exist" (2026-08-30).
    QString uriScheme = scheme;
    if (scheme == QLatin1String("smb-share"))
      uriScheme = QStringLiteral("smb");
    QUrl uri;
    uri.setScheme(uriScheme);
    if (!user.isEmpty()) uri.setUserName(user);
    if (!host.isEmpty()) uri.setHost(host);
    if (!share.isEmpty()) uri.setPath(QLatin1Char('/') + share);
    m[QStringLiteral("uri")] = uri.toString();

    // Nautilus-like home: the FUSE path of the mount's GIO default
    // location -- the remote HOME for sftp (what a fresh connect opens,
    // see NetworkResolver's mountFinished homePath), the root for the
    // other schemes. The sidebar "Open" uses this so the mount always
    // opens the same place the connect flow opens (requested 2026-08-30).
    QString homePath = fi.absoluteFilePath();
    if (!host.isEmpty()) {
      GError *probeError = nullptr;
      GFile *file = g_file_new_for_uri(uri.toString().toUtf8().constData());
      GMount *mount = g_file_find_enclosing_mount(file, nullptr, &probeError);
      if (mount) {
        GFile *def = static_cast<GFile *>(g_mount_get_default_location(mount));
        if (def) {
          QUrl defUrl(QString::fromUtf8(g_file_get_uri(def)));
          const QString defaultPath = defUrl.path();
          if (!defaultPath.isEmpty() && defaultPath != QLatin1String("/"))
            homePath += defaultPath;
          g_object_unref(def);
        }
        g_object_unref(mount);
      }
      g_object_unref(file);
      if (probeError) g_error_free(probeError);
    }
    m[QStringLiteral("homePath")] = homePath;
    out.append(m);
  }
  return out;
}

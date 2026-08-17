#include "MimeResolver.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMimeDatabase>
#include <QMimeType>
#include <QProcess>
#include <QRegularExpression>
#include <QSet>
#include <QVariantMap>
#include <QStandardPaths>
#include <QStringList>
#include <QTextStream>

namespace {

QStringList parseMimeAssociations(const QString &filePath, const QStringList &mimeTypes) {
  QStringList results;
  QFile file(filePath);
  if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
    return results;
  }

  QTextStream in(&file);
  bool inRelevantSection = true; // For mimeinfo.cache there's only [MIME Cache]
  
  while (!in.atEnd()) {
    QString line = in.readLine().trimmed();
    if (line.isEmpty() || line.startsWith(QLatin1Char('#'))) continue;

    if (line.startsWith(QLatin1Char('['))) {
      // In mimeapps.list, [Removed Associations] shouldn't add to our list.
      if (line == QLatin1String("[Removed Associations]")) {
        inRelevantSection = false;
      } else {
        inRelevantSection = true;
      }
      continue;
    }

    if (!inRelevantSection) continue;

    int eqIdx = line.indexOf(QLatin1Char('='));
    if (eqIdx == -1) continue;

    QString mime = line.left(eqIdx).trimmed();
    if (mimeTypes.contains(mime)) {
      QString apps = line.mid(eqIdx + 1).trimmed();
      const auto ids = apps.split(QLatin1Char(';'), Qt::SkipEmptyParts);
      for (const QString &id : ids) {
        results.append(id);
      }
    }
  }

  return results;
}

QString findDesktopFile(const QString &id) {
  QStringList dataDirs = QStandardPaths::standardLocations(QStandardPaths::ApplicationsLocation);
  for (const QString &dir : dataDirs) {
    QString path = dir + QLatin1Char('/') + id;
    if (QFileInfo::exists(path)) {
      return path;
    }
    // Some desktop IDs might be subdirectories e.g. kde4/foo.desktop
    // but the XDG spec requires them to be mapped with hyphens. We'll stick to exact match.
  }
  return QString();
}

QString parseDesktopName(const QString &desktopPath, const QString &fallbackId) {
  QFile file(desktopPath);
  if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
    return fallbackId;
  }
  
  QTextStream in(&file);
  bool inDesktopEntry = false;
  while (!in.atEnd()) {
    QString line = in.readLine().trimmed();
    if (line == QLatin1String("[Desktop Entry]")) {
      inDesktopEntry = true;
      continue;
    } else if (line.startsWith(QLatin1Char('['))) {
      inDesktopEntry = false;
      continue;
    }
    
    if (inDesktopEntry && line.startsWith(QLatin1String("Name="))) {
      return line.mid(5).trimmed();
    }
  }
  return fallbackId;
}

} // namespace

MimeResolver::MimeResolver(QObject *parent) : QObject(parent) {}

QVariantList MimeResolver::getAppsForFile(const QString &path) {
  QVariantList out;
  if (path.isEmpty()) return out;

  QMimeDatabase db;
  QMimeType mimeType = db.mimeTypeForFile(path);
  if (!mimeType.isValid()) return out;

  QStringList typesToCheck;
  typesToCheck.append(mimeType.name());
  typesToCheck.append(mimeType.allAncestors());

  QStringList desktopIds;
  
  // 1. User mimeapps.list
  QString userMimeApps = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation) + QLatin1String("/mimeapps.list");
  desktopIds.append(parseMimeAssociations(userMimeApps, typesToCheck));

  // 2. System mimeapps.list and mimeinfo.cache
  QStringList appDirs = QStandardPaths::standardLocations(QStandardPaths::ApplicationsLocation);
  for (const QString &dir : appDirs) {
    desktopIds.append(parseMimeAssociations(dir + QLatin1String("/mimeapps.list"), typesToCheck));
    desktopIds.append(parseMimeAssociations(dir + QLatin1String("/mimeinfo.cache"), typesToCheck));
  }

  QSet<QString> seen;
  for (const QString &id : desktopIds) {
    if (id.isEmpty() || seen.contains(id)) continue;
    seen.insert(id);

    QString desktopPath = findDesktopFile(id);
    if (!desktopPath.isEmpty()) {
      QVariantMap app;
      app[QStringLiteral("id")] = id;
      app[QStringLiteral("name")] = parseDesktopName(desktopPath, id);
      out.append(app);
    }
  }

  return out;
}

bool MimeResolver::matchesFilter(const QString &path, const QVariantList &rules) {
  if (path.isEmpty() || rules.isEmpty()) return false;
  const QFileInfo fileInfo(path);
  QMimeDatabase database;
  QMimeType actualMime;
  for (const QVariant &ruleValue : rules) {
    const QVariantMap rule = ruleValue.toMap();
    bool ok = false;
    const int type = rule.value(QStringLiteral("type")).toInt(&ok);
    const QString value = rule.value(QStringLiteral("value")).toString();
    if (!ok || value.isEmpty()) continue;
    if (type == 0) {
      const QRegularExpression expression(
          QRegularExpression::wildcardToRegularExpression(value));
      if (expression.isValid() && expression.match(fileInfo.fileName()).hasMatch())
        return true;
    } else if (type == 1) {
      if (!actualMime.isValid())
        actualMime = database.mimeTypeForFile(fileInfo, QMimeDatabase::MatchDefault);
      if (!actualMime.isValid()) continue;
      if (value.endsWith(QLatin1String("/*"))) {
        if (actualMime.name().startsWith(value.left(value.size() - 1))) return true;
      } else if (actualMime.name() == value || actualMime.inherits(value)) {
        return true;
      }
    }
  }
  return false;
}

void MimeResolver::launchApp(const QString &desktopId, const QString &path) {
  if (desktopId.isEmpty() || path.isEmpty()) return;

  QString desktopPath = findDesktopFile(desktopId);
  if (desktopPath.isEmpty()) return;

  QFile file(desktopPath);
  if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) return;

  QString execCmd;
  QTextStream in(&file);
  bool inDesktopEntry = false;
  while (!in.atEnd()) {
    QString line = in.readLine().trimmed();
    if (line == QLatin1String("[Desktop Entry]")) {
      inDesktopEntry = true;
    } else if (line.startsWith(QLatin1Char('['))) {
      inDesktopEntry = false;
    } else if (inDesktopEntry && line.startsWith(QLatin1String("Exec="))) {
      execCmd = line.mid(5).trimmed();
      break;
    }
  }

  if (execCmd.isEmpty()) return;

  // Substitute %f, %F, %u, %U with the path
  // Proper shell-quoting is complex, but for basic QProcess::startDetached,
  // we just replace the placeholder. A full spec implementation would parse args correctly.
  
  // Quick & safe implementation: build arguments for QProcess
  // Since Exec line can contain quotes and spaces, we parse it manually.
  QStringList args;
  QString currentArg;
  bool inQuotes = false;
  
  for (int i = 0; i < execCmd.size(); ++i) {
    QChar c = execCmd.at(i);
    if (c == QLatin1Char('"')) {
      inQuotes = !inQuotes;
    } else if (c.isSpace() && !inQuotes) {
      if (!currentArg.isEmpty()) {
        args.append(currentArg);
        currentArg.clear();
      }
    } else {
      currentArg.append(c);
    }
  }
  if (!currentArg.isEmpty()) {
    args.append(currentArg);
  }

  if (args.isEmpty()) return;

  QString program = args.takeFirst();
  
  // Replace % placeholders in args
  for (QString &arg : args) {
    if (arg == QLatin1String("%f") || arg == QLatin1String("%F") ||
        arg == QLatin1String("%u") || arg == QLatin1String("%U")) {
      arg = path;
    }
  }

  // Remove other placeholders like %i, %c, %k
  args.erase(std::remove_if(args.begin(), args.end(), [](const QString &a) {
    return a.startsWith(QLatin1Char('%'));
  }), args.end());

  QProcess::startDetached(program, args);
}

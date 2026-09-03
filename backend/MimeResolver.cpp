#include "MimeResolver.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMimeDatabase>
#include <QMimeType>
#include <QProcess>
#include <QSet>
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

// Reads the [Removed Associations] section of a mimeapps.list. Per the XDG
// spec these desktop IDs must be filtered out of the final association list,
// regardless of which mimeapps.list/mimeinfo.cache added them.
QSet<QString> parseRemovedAssociations(const QString &filePath, const QStringList &mimeTypes) {
  QSet<QString> removed;
  QFile file(filePath);
  if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
    return removed;
  }

  QTextStream in(&file);
  bool inRemovedSection = false;
  while (!in.atEnd()) {
    QString line = in.readLine().trimmed();
    if (line.isEmpty() || line.startsWith(QLatin1Char('#'))) continue;

    if (line.startsWith(QLatin1Char('['))) {
      inRemovedSection = (line == QLatin1String("[Removed Associations]"));
      continue;
    }

    if (!inRemovedSection) continue;

    int eqIdx = line.indexOf(QLatin1Char('='));
    if (eqIdx == -1) continue;

    QString mime = line.left(eqIdx).trimmed();
    if (mimeTypes.contains(mime)) {
      QString apps = line.mid(eqIdx + 1).trimmed();
      const auto ids = apps.split(QLatin1Char(';'), Qt::SkipEmptyParts);
      for (const QString &id : ids) removed.insert(id);
    }
  }

  return removed;
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

  // 3. XDG [Removed Associations] from the user mimeapps.list: these desktop
  //    IDs are excluded no matter which of the sources above listed them.
  const QSet<QString> removed = parseRemovedAssociations(userMimeApps, typesToCheck);

  QSet<QString> seen;
  for (const QString &id : desktopIds) {
    if (id.isEmpty() || seen.contains(id) || removed.contains(id)) continue;
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

void MimeResolver::launchApp(const QString &desktopId, const QString &path) {
  if (desktopId.isEmpty() || path.isEmpty()) return;

  QString desktopPath = findDesktopFile(desktopId);
  if (desktopPath.isEmpty()) return;

  QFile file(desktopPath);
  if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) return;

  QString execCmd;
  bool needsTerminal = false;
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
    } else if (inDesktopEntry && line.startsWith(QLatin1String("Terminal="))) {
      needsTerminal = line.mid(9).trimmed().compare(QLatin1String("true"), Qt::CaseInsensitive) == 0;
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

  // Terminal=true apps (nvim, vim, htop, ...) have NO GUI and expect a real TTY:
  // launching them detached leaves them with no terminal and they refuse to start.
  // Wrap the command in the user's terminal emulator (same resolution order as
  // TerminalResolver::launchTerminal, minus the /tmp-directory duty).
  if (needsTerminal) {
    startInTerminal(program, args);
    return;
  }

  qint64 pid = 0;
  if (!QProcess::startDetached(program, args, QString(), &pid)) {
    qWarning("launchApp: could not start '%s'", qPrintable(program));
  }
}

// Launches `program` + `args` inside the user's terminal emulator so TTY-only
// apps (Terminal=true) get a working terminal. Resolution matches
// TerminalResolver: $TERMINAL first, then the known modern ones.
void MimeResolver::startInTerminal(const QString &program, const QStringList &args) {
  if (qEnvironmentVariable("OMAFILES_SELFCHECK") == "1") return;

  // 1. User's explicit choice, 2. known terminal emulators.
  QStringList candidates;
  const QByteArray termEnv = qgetenv("TERMINAL");
  if (!termEnv.isEmpty()) {
    candidates << QString::fromLocal8Bit(termEnv);
  }
  candidates << QStringLiteral("kitty")
             << QStringLiteral("foot")
             << QStringLiteral("alacritty")
             << QStringLiteral("wezterm")
             << QStringLiteral("ghostty")
             << QStringLiteral("gnome-terminal")
             << QStringLiteral("konsole")
             << QStringLiteral("xfce4-terminal")
             << QStringLiteral("xterm");

  QStringList run;
  for (const QString &term : candidates) {
    const QString exe = QStandardPaths::findExecutable(term);
    if (!exe.isEmpty()) {
      run << exe;
      if (term == QLatin1String("xdg-terminal-exec")) {
        // freedesktop executor: takes the command directly, no -e/-- flag.
      } else if (term == QLatin1String("wezterm")) {
        run << QStringLiteral("start") << QStringLiteral("--");
      } else if (term == QLatin1String("gnome-terminal")) {
        run << QStringLiteral("--");
      } else {
        run << QStringLiteral("-e");
      }
      break;
    }
  }

  // 'gnome-terminal -- CMD args' passes CMD+args as ONE shell string, not as
  // separate argv entries; the '-e' family runs them as argv. Normalize for both.
  if (!run.isEmpty()) {
    QString termExe = run.takeFirst();
    // xdg-terminal-exec mirrors the -e/argv family: it gets program+args as-is.
    if (run.contains(QStringLiteral("--"))) {
      // gnome-terminal/wezterm: '-- "cmd arg" ' executes a shell line.
      QStringList line = args;
      line.prepend(program);
      run << line.join(QLatin1Char(' '));
    } else {
      run << program << args;
    }
    if (QProcess::startDetached(termExe, run))
      return;
  }

  qWarning("launchApp: Terminal=true but no usable terminal emulator found for '%s'",
           qPrintable(program));
}

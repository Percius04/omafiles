#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusInterface>
#include <QDBusMessage>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QLocalServer>
#include <QLocalSocket>
#include <QPageSize>
#include <QPainter>
#include <QPdfWriter>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QObject>
#include <QQuickStyle>
#include <QRegularExpression>
#include <QStringList>
#include <QTemporaryDir>
#include <QTimer>
#include <QUrl>
#include <QVariantList>
#include <cstdio>
#include <utility>
#include <unistd.h>

// Selfcheck reporter: DETERMINISTIC output to stdout (does not depend on the
// QML logging rules, which in release may silence console.log).
// Exposed to QML as the context property `SelfCheckOut`.
class SelfCheckReporter : public QObject {
  Q_OBJECT
 public:
  using QObject::QObject;
  Q_INVOKABLE void line(const QString &text) {
    printf("%s\n", text.toLocal8Bit().constData());
    fflush(stdout);
  }
};

// Qt6 bootstrap of the standalone frontend. In normal mode it
// loads app/Main.qml, which instantiates the SAME
// core/OmafilesContent.qml as the frontend, inside a real
// ApplicationWindow.
//
// Phase 12 (josema): adds `--selfcheck`. In that mode the executable stops
// being an alternative host and becomes the OFFICIAL environment for automatic
// validation: it starts headless (offscreen), sets up fixtures in a
// self-cleaning temporary directory and loads
// app/SelfCheck.qml, which exercises the
// backend/frontend/integration subsystems and ends with Qt.exit(number of
// failures). See AUDIT-V2.md and SelfCheck.qml.
//
// OMAFILES_SOURCE_DIR / OMAFILES_QML_IMPORT_DIR are defined by CMakeLists.txt.

namespace {

// Phase 29 (josema): resolves the RESOURCE root (.sh scripts + QML tree).
// Omafiles no longer depends on the repository: if it is installed in
// $XDG_DATA_HOME/omafiles (or wherever CMake put it), it loads from there; if
// not, from the development tree. The first candidate whose Main.qml exists
// wins, so the binary works both after `cmake --install` (even if the repo is
// deleted) and running from the development checkout.
QString resolveResourceDir() {
  QStringList candidates;
  // 1. Development tree (the repo). It goes FIRST on purpose: if the repo
  //    exists, it runs from it (live QML editing, as always). If
  //    the repo is deleted, this path stops existing and it falls back to the
  //    installation.
  candidates << QStringLiteral(OMAFILES_SOURCE_DIR);
  // 2. Where CMake installed the resources (respects a configure -D).
  candidates << QStringLiteral(OMAFILES_DATA_INSTALL_DIR) + "/omafiles";
  // 3. $XDG_DATA_HOME/omafiles at runtime (in case it differs from configure's).
  const QByteArray xdg = qgetenv("XDG_DATA_HOME");
  const QString dataHome = (!xdg.isEmpty() && xdg.startsWith('/'))
                               ? QString::fromLocal8Bit(xdg)
                               : QDir::homePath() + "/.local/share";
  candidates << dataHome + "/omafiles";
  for (const QString &c : candidates) {
    if (QFileInfo::exists(c + "/app/Main.qml"))
      return c;
  }
  // Fallback: the standard installation (clear error message if it is not there either).
  return QDir::homePath() + "/.local/share/omafiles";
}

// Adds to the engine the import paths the core needs: the
// qs.Commons/qs.Ui adapters (under the resource root) and the C++ plugin
// Omafiles.Backend. For the backend the TWO possible locations are added -- the
// development build/ and the stable installation in ~/.local/lib/qt6/qml -- and
// Qt ignores the one that does not exist, so it works in both modes.
void addImportPaths(QQmlApplicationEngine &engine, const QString &resourceDir) {
  engine.addImportPath(resourceDir + "/app/qml_modules");
  engine.addImportPath(QStringLiteral(OMAFILES_QML_IMPORT_DIR));  // dev build/qml
  engine.addImportPath(QStringLiteral(OMAFILES_QML_INSTALL_DIR)); // installed
}

// Name of the single-instance socket, per user (to not clash between
// users nor with a headless selfcheck session). It lives under
// XDG_RUNTIME_DIR (QLocalServer resolves it by name).
QString instanceSocketName() {
  return QStringLiteral("omafiles-instance-%1").arg(static_cast<uint>(getuid()));
}

bool validPickerBasename(const QString &name) {
  return !name.isEmpty() && name != QLatin1String(".") &&
         name != QLatin1String("..") && !name.contains(QLatin1Char('/')) &&
         !name.contains(QChar::Null);
}

// Picker payloads use a strict, non-secret JSON schema. This classifier is
// shared by command routing and the test seam so picker processes can never
// contact or claim the normal single-instance socket.
bool validatedPickerPayload(const QString &payload, QJsonObject *result = nullptr) {
  QJsonParseError error;
  const QJsonDocument document = QJsonDocument::fromJson(payload.toUtf8(), &error);
  if (error.error != QJsonParseError::NoError || !document.isObject()) return false;
  const QJsonObject object = document.object();
  const QString mode = object.value(QStringLiteral("mode")).toString();
  const QString folder = object.value(QStringLiteral("folder")).toString();
  const QString requestId = object.value(QStringLiteral("requestId")).toString();
  const QJsonValue filesValue = object.value(QStringLiteral("files"));
  static const QRegularExpression objectPathPattern(
      QStringLiteral("^/(?:[A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)*)?$"));
  static const QStringList pickerKeys{
      QStringLiteral("files"), QStringLiteral("folder"), QStringLiteral("kind"),
      QStringLiteral("mode"), QStringLiteral("multiple"), QStringLiteral("requestId"),
      QStringLiteral("suggestedName")};
  if (object.keys() != pickerKeys ||
      object.value(QStringLiteral("kind")).toString() != QLatin1String("picker") ||
      !objectPathPattern.match(requestId).hasMatch() || !folder.startsWith(QLatin1Char('/')) ||
      folder.contains(QChar::Null) ||
      !object.value(QStringLiteral("multiple")).isBool() ||
      !object.value(QStringLiteral("suggestedName")).isString() || !filesValue.isArray() ||
      (mode != QLatin1String("open-file") && mode != QLatin1String("open-dir") &&
       mode != QLatin1String("save-file") && mode != QLatin1String("save-files"))) {
    return false;
  }
  const QJsonArray files = filesValue.toArray();
  if (mode == QLatin1String("save-files") && files.isEmpty()) return false;
  for (const QJsonValue &file : files) {
    if (!file.isString() || !validPickerBasename(file.toString())) return false;
  }
  if (result) *result = object;
  return true;
}

// Normalizes the command-line argument to the "payload" that
// core/OmafilesContent.open() understands: an absolute folder path, optionally
// followed by "\n" and names to select (separated by \x1f). Rules:
//   · empty            -> "" (open() restores the previous session).
//   · starts with "/"  -> forwarded AS IS. Covers both an absolute path
//                         and a payload already built by dbus-filemanager1.py
//                         ("/folder\nname") -- that is why it is not touched.
//   · file:// URI      -> decoded; if it is a file, "dir\nname".
//   · relative path    -> made absolute; if it is a file, "dir\nname".
// The file->folder+selection logic only applies to the last two
// (direct use `omafiles ~/x` or xdg-open); the scripts already send something clean.
QString normalizePayload(const QString &arg) {
  if (arg.isEmpty()) return QString();
  if (arg.startsWith(QLatin1Char('/'))) return arg;
  if (arg.startsWith(QLatin1Char('{')))
    return validatedPickerPayload(arg) ? arg : QString();

  QString path;
  if (arg.startsWith(QLatin1String("file://"))) {
    const QUrl u(arg);
    path = u.isLocalFile() ? u.toLocalFile() : QString();
  } else {
    path = arg;  // relative path
  }
  if (path.isEmpty()) return QString();

  const QFileInfo fi(path);
  if (!fi.exists()) return QString();
  if (fi.isFile())
    return fi.absolutePath() + QLatin1Char('\n') + fi.fileName();
  return fi.absoluteFilePath();
}

// Single instance. The FIRST instance listens on a QLocalServer and exposes
// received(payload) to QML (Main.qml connects it to content.open + raise). A
// SECOND invocation (e.g. opening a folder from another app) connects to the
// socket, sends its payload and exits, instead of opening another window.
class PickerResponder : public QObject {
  Q_OBJECT
  Q_PROPERTY(bool ready READ ready CONSTANT)
 public:
  PickerResponder(QString requestId, QByteArray token, QObject *parent = nullptr)
      : QObject(parent), m_requestId(std::move(requestId)), m_token(std::move(token)) {}

  bool ready() const { return m_registered && !m_completed; }

  bool registerPicker() {
    if (m_requestId.isEmpty() || m_token.isEmpty()) return false;
    QDBusInterface portal(
        QStringLiteral("org.freedesktop.impl.portal.desktop.omafiles"),
        QStringLiteral("/org/freedesktop/portal/desktop"),
        QStringLiteral("org.freedesktop.impl.portal.desktop.omafiles"),
        QDBusConnection::sessionBus());
    const QDBusMessage reply = portal.call(
        QDBus::Block, QStringLiteral("RegisterPicker"), m_requestId,
        QString::fromLatin1(m_token));
    m_token.fill('\0');
    m_token.clear();
    m_registered = reply.type() == QDBusMessage::ReplyMessage;
    return m_registered;
  }

  Q_INVOKABLE bool submit(int responseCode, const QVariantList &results) {
    if (!ready() || responseCode < 0) return false;
    const QString resultsJson = QString::fromUtf8(
        QJsonDocument(QJsonArray::fromVariantList(results)).toJson(QJsonDocument::Compact));
    QDBusInterface portal(
        QStringLiteral("org.freedesktop.impl.portal.desktop.omafiles"),
        QStringLiteral("/org/freedesktop/portal/desktop"),
        QStringLiteral("org.freedesktop.impl.portal.desktop.omafiles"),
        QDBusConnection::sessionBus());
    const QDBusMessage reply = portal.call(
        QDBus::Block, QStringLiteral("SubmitResponse"), m_requestId,
        static_cast<quint32>(responseCode), resultsJson);
    if (reply.type() != QDBusMessage::ReplyMessage) return false;
    m_completed = true;
    m_requestId.clear();
    return true;
  }

 private:
  QString m_requestId;
  QByteArray m_token;
  bool m_registered = false;
  bool m_completed = false;
};

class SingleInstance : public QObject {
  Q_OBJECT
 public:
  using QObject::QObject;

  // Tries to deliver `payload` to an already-running instance. Returns true if
  // it succeeded (this invocation must exit without opening a window).
  static bool deliverToRunning(const QString &payload) {
    QLocalSocket sock;
    sock.connectToServer(instanceSocketName());
    if (!sock.waitForConnected(300)) return false;
    sock.write(payload.toUtf8());
    sock.flush();
    sock.waitForBytesWritten(300);
    sock.disconnectFromServer();
    if (sock.state() != QLocalSocket::UnconnectedState)
      sock.waitForDisconnected(300);
    return true;
  }

  // Starts listening. removeServer() cleans up an orphan socket from a
  // previous instance that died without closing it.
  bool listen() {
    QLocalServer::removeServer(instanceSocketName());
    connect(&m_server, &QLocalServer::newConnection, this,
            &SingleInstance::onConnection);
    return m_server.listen(instanceSocketName());
  }

 signals:
  void received(const QString &payload);

 private slots:
  void onConnection() {
    QLocalSocket *c = m_server.nextPendingConnection();
    if (!c) return;
    connect(c, &QLocalSocket::readyRead, this, [this, c]() {
      emit received(QString::fromUtf8(c->readAll()));
    });
    connect(c, &QLocalSocket::disconnected, c, &QObject::deleteLater);
  }

 private:
  QLocalServer m_server;
};

// Generates the deterministic test files the selfcheck needs.
// Everything hangs off `base` (a QTemporaryDir), so it is deleted on its own on
// exit. Requires a live QGuiApplication (QImage/QPdfWriter/QPainter).
bool writeSelfCheckFixtures(const QString &base) {
  QDir d(base);
  if (!d.mkpath("list/sub") || !d.mkpath("watch") || !d.mkpath("ops") ||
      !d.mkpath("json")) {
    return false;
  }

  // Directory with known content for DirectoryModel (natural order:
  // the subfolder first, then the .txt).
  for (const QString &name : {QStringLiteral("alpha.txt"),
                              QStringLiteral("beta.txt"),
                              QStringLiteral("gamma.txt")}) {
    QFile f(base + "/list/" + name);
    if (!f.open(QIODevice::WriteOnly)) return false;
    f.write("x");
    f.close();
  }

  // Text file for PreviewProvider.
  QFile note(base + "/note.txt");
  if (!note.open(QIODevice::WriteOnly)) return false;
  note.write("hello selfcheck\nsecond line\n");
  note.close();

  // Symlink to validate that copy/move preserve links as links.
  QFile::remove(base + "/link.txt");
  QFile::link(base + "/note.txt", base + "/link.txt");

  // Large file (32 MiB) to test cooperative cancellation mid-copy:
  // large enough that the copy spans many chunks and
  // the cancel() lands in the middle.
  {
    QFile big(base + "/big.bin");
    if (!big.open(QIODevice::WriteOnly)) return false;
    const QByteArray chunk(1 << 20, '\0'); // 1 MiB
    for (int i = 0; i < 32; ++i) big.write(chunk);
    big.close();
  }

  // Folder with many files: for the cancellation of a recursive delete
  // (removeTree walks entry by entry checking the flag, so with
  // enough entries the synchronous cancel aborts mid-way
  // deterministically).
  if (!d.mkpath("bigdir")) return false;
  for (int i = 0; i < 500; ++i) {
    QFile f(base + QStringLiteral("/bigdir/f%1").arg(i));
    if (!f.open(QIODevice::WriteOnly)) return false;
    f.write("x");
    f.close();
  }

  // Read-only folder with a file inside: deleting the child fails
  // (EACCES, write permission on the parent is needed). It is restored to
  // writable after the run (see runSelfCheck) so that QTemporaryDir
  // can clean it up.
  if (!d.mkpath("readonly")) return false;
  {
    QFile f(base + "/readonly/locked.txt");
    if (!f.open(QIODevice::WriteOnly)) return false;
    f.write("x");
    f.close();
  }
  QFile::setPermissions(base + "/readonly",
                        QFileDevice::ReadOwner | QFileDevice::ExeOwner);

  // Real PNG for ThumbnailProvider (QImageReader path).
  QImage img(16, 16, QImage::Format_RGB32);
  img.fill(Qt::red);
  if (!img.save(base + "/img.png", "PNG")) return false;

  // Real one-page PDF for ThumbnailProvider (QPdfDocument/qpdf path).
  {
    QPdfWriter pdf(base + "/doc.pdf");
    pdf.setPageSize(QPageSize(QPageSize::A4));
    QPainter p(&pdf);
    if (!p.isActive()) return false;
    p.drawText(200, 200, QStringLiteral("selfcheck"));
    p.end();
  }

  // Real synthetic WAV for MediaInfo / PreviewProvider audio metadata.
  {
    QFile wav(base + "/audio.wav");
    if (wav.open(QIODevice::WriteOnly)) {
      QByteArray w;
      w.append("RIFF", 4);
      quint32 riffSize = 36 + 44100 * 4;
      w.append(reinterpret_cast<const char *>(&riffSize), 4);
      w.append("WAVEfmt ", 8);
      quint32 fmtSize = 16;
      quint16 audioFmt = 1; // PCM
      quint16 numCh = 2;    // Stereo
      quint32 sampleRate = 44100;
      quint32 byteRate = 44100 * 4;
      quint16 blockAlign = 4;
      quint16 bitsPerSample = 16;
      w.append(reinterpret_cast<const char *>(&fmtSize), 4);
      w.append(reinterpret_cast<const char *>(&audioFmt), 2);
      w.append(reinterpret_cast<const char *>(&numCh), 2);
      w.append(reinterpret_cast<const char *>(&sampleRate), 4);
      w.append(reinterpret_cast<const char *>(&byteRate), 4);
      w.append(reinterpret_cast<const char *>(&blockAlign), 2);
      w.append(reinterpret_cast<const char *>(&bitsPerSample), 2);
      w.append("data", 4);
      quint32 dataSize = 44100 * 4;
      w.append(reinterpret_cast<const char *>(&dataSize), 4);
      w.append(QByteArray(1024, '\0'));
      wav.write(w);
      wav.close();
    }
  }

  return QFile::exists(base + "/img.png") && QFile::exists(base + "/doc.pdf");
}

int runSelfCheck(int argc, char *argv[]) {
  // Headless by default (CI): if the user did not force a platform, offscreen.
  if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM")) {
    qputenv("QT_QPA_PLATFORM", "offscreen");
  }
  // The core reads this in AppBindings to NOT self-register as the file
  // manager during validation (no side effects on the system).
  qputenv("OMAFILES_SELFCHECK", "1");

  QGuiApplication app(argc, argv);
  QQuickStyle::setStyle("Basic");

  // Phase 29: same resource resolution as normal mode, so the
  // selfcheck works both from the development tree and from the
  // installation (without the repo). The test-only override lets the installed-
  // tree CTest prove that it does not fall back to the source checkout.
  QString resourceDir = resolveResourceDir();
  const QByteArray selfCheckResource = qgetenv("OMAFILES_SELFCHECK_RESOURCE_DIR");
  if (!selfCheckResource.isEmpty()) {
    const QString requested = QString::fromLocal8Bit(selfCheckResource);
    if (!QDir::isAbsolutePath(requested) ||
        !QFileInfo::exists(requested + "/app/SelfCheck.qml")) {
      fprintf(stderr, "[selfcheck] invalid installed resource tree\n");
      return 2;
    }
    resourceDir = requested;
  }
  qputenv("OMAFILES_RESOURCE_DIR", resourceDir.toLocal8Bit());

  // Under $HOME/.cache (not /tmp): this way the fixtures live on the SAME mount
  // as the user's XDG trash, and trash/restore round-trip as in
  // real use (in /tmp, a separate tmpfs, moveToTrash and restore use
  // different trashes). It is still self-cleaning (QTemporaryDir).
  QDir().mkpath(QDir::homePath() + "/.cache");
  QTemporaryDir tmp(QDir::homePath() + "/.cache/omafiles-selfcheck-XXXXXX");
  if (!tmp.isValid() || !writeSelfCheckFixtures(tmp.path())) {
    fprintf(stderr, "[selfcheck] could not create the fixtures\n");
    return 2;
  }

  QQmlApplicationEngine engine;
  addImportPaths(engine, resourceDir);
  const QByteArray selfCheckImport = qgetenv("OMAFILES_SELFCHECK_QML_IMPORT_DIR");
  if (!selfCheckImport.isEmpty()) {
    const QString requested = QString::fromLocal8Bit(selfCheckImport);
    if (!QDir::isAbsolutePath(requested) ||
        !QFileInfo::exists(requested + "/Omafiles/Backend/qmldir")) {
      fprintf(stderr, "[selfcheck] invalid installed QML import tree\n");
      return 2;
    }
    // addImportPath prepends, so the staged installed module wins over build/qml.
    engine.addImportPath(requested);
  }
  SelfCheckReporter reporter;
  engine.rootContext()->setContextProperty("selfCheckTmpDir", tmp.path());
  engine.rootContext()->setContextProperty("SelfCheckOut", &reporter);

  bool failedToCreate = false;
  QObject::connect(
      &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
      [&failedToCreate]() {
        failedToCreate = true;
        QCoreApplication::exit(2);
      },
      Qt::QueuedConnection);

  engine.load(QUrl::fromLocalFile(resourceDir +
                                  "/app/SelfCheck.qml"));
  if (failedToCreate || engine.rootObjects().isEmpty()) {
    fprintf(stderr, "[selfcheck] could not load SelfCheck.qml\n");
    return 2;
  }

  // SelfCheck.qml calls Qt.exit(number of failures) on finishing; that code
  // exits through app.exec().
  const int rc = app.exec();
  // Restore permissions of the readonly folder (permission-failure fixture)
  // so QTemporaryDir can delete it when destroying tmp.
  QFile::setPermissions(tmp.path() + "/readonly",
                        QFileDevice::ReadOwner | QFileDevice::WriteOwner |
                            QFileDevice::ExeOwner);
  return rc; // tmp is destroyed (and cleaned) on returning from main.
}

int runInstanceServerTest(int argc, char *argv[], const QString &readyPath) {
  QCoreApplication app(argc, argv);
  SingleInstance instance;
  if (!instance.listen()) return 2;
  QFile ready(readyPath);
  if (!ready.open(QIODevice::WriteOnly) || ready.write("ready\n") < 0) return 2;
  ready.close();
  QTimer::singleShot(10000, &app, &QCoreApplication::quit);
  return app.exec();
}

int runNormal(int argc, char *argv[]) {
  QGuiApplication app(argc, argv);
  app.setApplicationName(QStringLiteral("omafiles"));
  // Wayland app_id = "omafiles" (kept on purpose: any
  // Hyprland windowrule with class:omafiles keeps working). The installed
  // .desktop has a different basename (io.github.percius04.omafiles, mandatory
  // for D-Bus activation), so it is matched to this window via
  // StartupWMClass=omafiles in the .desktop itself -> the dock/taskbar resolves
  // Icon=omafiles without changing the app_id.


  // First positional argument = path/URI/payload to open (empty = normal
  // start, which restores the previous session ).
  QString payload;
  for (int i = 1; i < argc; ++i) {
    const QString a = QString::fromLocal8Bit(argv[i]);
    if (a.startsWith(QLatin1String("--"))) continue;  // flags (there are none in normal mode)
    payload = normalizePayload(a);
    break;
  }

  QJsonObject pickerObject;
  const bool isPicker = validatedPickerPayload(payload, &pickerObject);

  // Executable integration seam: use the production classifier and socket
  // routing without loading QML. It is enabled only by the test environment.
  if (qEnvironmentVariableIsSet("OMAFILES_TEST_CLASSIFY_ONLY")) {
    if (isPicker) {
      printf("picker-independent\n");
      return 0;
    }
    if (SingleInstance::deliverToRunning(payload)) {
      printf("normal-delivered\n");
      return 0;
    }
    return 2;
  }

  app.setDesktopFileName(isPicker ? QStringLiteral("omafiles-picker")
                                  : QStringLiteral("omafiles"));

  // A picker neither delivers to nor listens on the normal socket.
  if (!isPicker && SingleInstance::deliverToRunning(payload)) return 0;

  QByteArray pickerToken;
  if (isPicker) {
    QFile input;
    if (!input.open(stdin, QIODevice::ReadOnly)) return 2;
    pickerToken = input.readLine().trimmed();
    if (pickerToken.isEmpty()) return 2;
  }

  PickerResponder pickerResponder(
      isPicker ? pickerObject.value(QStringLiteral("requestId")).toString() : QString(),
      std::move(pickerToken));
  if (isPicker && !pickerResponder.registerPicker()) return 2;

  // qs.Ui uses QtQuick.Controls (Button/TextField) -- Basic is the style that
  // does not depend on any extra native backend, the safest.
  QQuickStyle::setStyle("Basic");

  QQmlApplicationEngine engine;
  // Phase 29: resolved resource root (installed vs dev). It is published by env
  // so state/Paths.qml (resourceDir) locates the .sh scripts without knowing
  // the repo.
  const QString resourceDir = resolveResourceDir();
  qputenv("OMAFILES_RESOURCE_DIR", resourceDir.toLocal8Bit());
  addImportPaths(engine, resourceDir);

  SingleInstance instance;
  if (!isPicker) {
    instance.listen();  // if a normal-instance race took the name, this window
                        // simply does not receive later summons.
  }
  engine.rootContext()->setContextProperty("SingleInstance", &instance);
  engine.rootContext()->setContextProperty("PickerResponder", &pickerResponder);
  engine.rootContext()->setContextProperty("omafilesInitialPayload", payload);
  engine.rootContext()->setContextProperty("omafilesInitialIsPicker", isPicker);

  QObject::connect(
      &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
      []() { QCoreApplication::exit(-1); }, Qt::QueuedConnection);

  engine.load(
      QUrl::fromLocalFile(resourceDir + "/app/Main.qml"));
  if (engine.rootObjects().isEmpty()) return -1;

  return app.exec();
}

}  // namespace

int main(int argc, char *argv[]) {
  // Qt6 blocks, for security, file:// reads via XMLHttpRequest unless
  // they are explicitly enabled. The standalone's qs.Commons/ThemeSource
  // adapter reads Omarchy's live theme files this way
  // (colors.toml/shell.toml). Without this, ThemeSource falls back to grey.
  // It must go before
  // creating the QML engine.
  qputenv("QML_XHR_ALLOW_FILE_READ", "1");
  for (int i = 1; i < argc; ++i) {
    const QString argument = QString::fromLocal8Bit(argv[i]);
    if (argument == QLatin1String("--selfcheck")) return runSelfCheck(argc, argv);
    if (argument == QLatin1String("--test-instance-server") && i + 1 < argc)
      return runInstanceServerTest(argc, argv, QString::fromLocal8Bit(argv[i + 1]));
  }
  return runNormal(argc, argv);
}

#include "main.moc"

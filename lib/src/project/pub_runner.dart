/// Finding the Flutter SDK and running `pub get` from inside a running app.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package_info.dart';
import 'windows_batch.dart';

/// A Flutter SDK on this machine.
final class FlutterSdk {
  /// The SDK in [root] (the folder holding `bin/flutter`).
  FlutterSdk(String root) : root = root.replaceAll(r'\', '/');

  /// The SDK folder, with `/` between parts.
  final String root;

  /// The Dart executable the SDK ships.
  String get dart =>
      '$root/bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}';

  /// The `flutter` launcher.
  String get flutter => '$root/bin/flutter${Platform.isWindows ? '.bat' : ''}';

  /// Whether it looks like an SDK: its launcher exists.
  bool get exists => File(flutter).existsSync();

  /// Its Flutter version: from `bin/cache/flutter.version.json` (newer
  /// SDKs), else the old `version` file; null when neither can be read.
  String? get flutterVersion {
    final json = File('$root/bin/cache/flutter.version.json');
    try {
      if (json.existsSync()) {
        final v = jsonDecode(json.readAsStringSync());
        final framework = v is Map ? v['frameworkVersion'] : null;
        if (framework is String) return framework;
      }
    } on FormatException {
      // Fall back to the version file.
    } on FileSystemException {
      // Fall back to the version file.
    }
    return _firstWord('$root/version');
  }

  /// The version of the Dart SDK it ships (`bin/cache/dart-sdk/version`);
  /// null when it can't be read.
  String? get dartVersion => _firstWord('$root/bin/cache/dart-sdk/version');

  static String? _firstWord(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      final word = f.readAsStringSync().trim().split(RegExp(r'\s')).first;
      return word.isEmpty ? null : word;
    } on FileSystemException {
      return null;
    }
  }
}

/// Finds the Flutter SDK a project uses.
abstract final class SdkLocator {
  /// The SDK for [projectRoot], trying in order: [configured] (a setting),
  /// the `FLUTTER_ROOT` environment variable, the SDK that last ran pub
  /// (`flutterRoot` in package_config.json), and `flutter` on the `PATH`
  /// where it is a link into an SDK. Null when none is found. It never
  /// starts a program; [find] also asks a launcher outside an SDK (a
  /// snap's, a version manager's shim), and [locate] then reuses its
  /// answer. Setting `FLUTTER_ROOT` to the SDK's folder always works.
  static FlutterSdk? locate(
    String projectRoot, {
    String? configured,
    Map<String, String>? environment,
  }) {
    final env = environment ?? Platform.environment;
    final candidates = [
      configured,
      env['FLUTTER_ROOT'],
      PackageConfig.read(projectRoot)?.flutterRoot,
      _fromPath(env),
      for (final l in _launchers(env).take(1)) _asked[l],
    ];
    for (final c in candidates) {
      if (c == null || c.isEmpty) continue;
      final sdk = FlutterSdk(c);
      if (sdk.exists) return sdk;
    }
    return null;
  }

  /// [locate], and when that finds nothing, the SDK the first `flutter` on
  /// the `PATH` says it runs (`flutterRoot` from `flutter --version
  /// --machine`): how a snap's launcher, or a version manager's shim, is
  /// found. The launcher gets [timeout] (a first run can set its SDK up
  /// for minutes); then it is stopped, with what it started, and taken as
  /// not knowing. Its answer is kept for the rest of this process.
  static Future<FlutterSdk?> find(
    String projectRoot, {
    String? configured,
    Map<String, String>? environment,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final env = environment ?? Platform.environment;
    final found = locate(projectRoot, configured: configured, environment: env);
    if (found != null) return found;
    final launcher = _launchers(env).firstOrNull;
    if (launcher == null || _asked.containsKey(launcher)) return null;
    final root = _asked[launcher] = await _askLauncher(launcher, env, timeout);
    return root != null && FlutterSdk(root).exists ? FlutterSdk(root) : null;
  }

  /// Each launcher asked in this process → the SDK it named (null: none).
  static final Map<String, String?> _asked = {};

  /// The SDK [launcher] says it runs, or null when it can't say within
  /// [timeout].
  static Future<String?> _askLauncher(
    String launcher,
    Map<String, String> env,
    Duration timeout,
  ) async {
    final Process process;
    try {
      process = await Process.start(
        launcher,
        ['--version', '--machine'],
        environment: env,
        runInShell: runsThroughCmd(launcher),
      );
    } on Object {
      return null;
    }
    final out = StringBuffer();
    final read = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach(out.write);
    process.stderr.drain<void>().ignore();
    final int code;
    try {
      code = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      read.ignore();
      _stopTree(process);
      return null;
    }
    // A child that keeps its output open doesn't keep this waiting.
    await read.timeout(_drainTime, onTimeout: () {});
    if (code != 0) return null;
    try {
      final text = '$out';
      final start = text.indexOf('{');
      if (start < 0) return null;
      final json = jsonDecode(text.substring(start));
      final root = json is Map ? json['flutterRoot'] : null;
      return root is String ? root : null;
    } on FormatException {
      return null;
    }
  }

  /// Every `flutter` launcher on the PATH, in order.
  static Iterable<String> _launchers(Map<String, String> env) sync* {
    final path = env['PATH'] ?? env['Path'] ?? '';
    final separator = Platform.isWindows ? ';' : ':';
    final launcher = Platform.isWindows ? 'flutter.bat' : 'flutter';
    for (var dir in path.split(separator)) {
      dir = dir.trim();
      if (dir.length >= 2 && dir.startsWith('"') && dir.endsWith('"')) {
        dir = dir.substring(1, dir.length - 1);
      }
      if (dir.isEmpty) continue;
      final file = File('$dir/$launcher');
      if (file.existsSync()) yield file.path;
    }
  }

  static String? _fromPath(Map<String, String> env) {
    final path = env['PATH'] ?? env['Path'] ?? '';
    final separator = Platform.isWindows ? ';' : ':';
    final launcher = Platform.isWindows ? 'flutter.bat' : 'flutter';
    for (var dir in path.split(separator)) {
      dir = dir.trim();
      // Windows lets an entry be quoted.
      if (dir.length >= 2 && dir.startsWith('"') && dir.endsWith('"')) {
        dir = dir.substring(1, dir.length - 1);
      }
      if (dir.isEmpty) continue;
      final file = File('$dir/$launcher');
      if (!file.existsSync()) continue;
      // Homebrew and the like put a link to the launcher on the PATH: the
      // SDK is where it leads.
      var real = file.path;
      try {
        if (FileSystemEntity.isLinkSync(file.path)) {
          real = file.resolveSymbolicLinksSync();
        }
      } on FileSystemException {
        // Kept as found.
      }
      // <sdk>/bin/flutter → <sdk>; a launcher outside an SDK (a version
      // manager's shim) is passed over.
      final root = File(real).parent.parent.path;
      if (FlutterSdk(root).exists) return root;
    }
    return null;
  }
}

/// What a `pub get` run printed, and whether it worked.
final class PubResult {
  /// A run that exited with [exitCode].
  const PubResult(this.exitCode, this.stdout, this.stderr, {this.command = ''});

  /// The exit code; 0 is success.
  final int exitCode;

  /// What it printed.
  final String stdout;

  /// What it printed as errors.
  final String stderr;

  /// The command, for the log.
  final String command;

  /// Whether it succeeded.
  bool get ok => exitCode == 0;

  /// The lines worth showing a user: pub's errors, else its last lines.
  String get summary {
    final lines = [
      ...LineSplitter.split(stderr),
      ...LineSplitter.split(stdout),
    ].where((l) => l.trim().isNotEmpty).toList();
    final failing = lines.where(
      (l) =>
          l.contains('Because') ||
          l.contains('version solving failed') ||
          l.startsWith('Error') ||
          l.contains('Could not'),
    );
    final pick = failing.isNotEmpty ? failing.toList() : lines;
    return pick.skip(pick.length > 12 ? pick.length - 12 : 0).join('\n');
  }
}

/// Runs `pub get` for a project. Tests use a fake.
abstract interface class PubRunner {
  /// Resolves [projectRoot]'s dependencies. [offline] uses only the cache
  /// (as rollbacks do).
  Future<PubResult> get(String projectRoot, {bool offline = false});
}

/// Runs the SDK's own `dart pub get`, which needs no Flutter tool lock — so
/// it works while `flutter run` holds one — and falls back to
/// `flutter pub get`.
final class ProcessPubRunner implements PubRunner {
  /// A runner using [sdk], giving up after [timeout].
  ProcessPubRunner(this.sdk, {this.timeout = const Duration(minutes: 5)});

  /// The SDK to run.
  final FlutterSdk sdk;

  /// How long one run may take.
  final Duration timeout;

  @override
  Future<PubResult> get(String projectRoot, {bool offline = false}) async {
    final args = ['pub', 'get', if (offline) '--offline'];
    final env = {
      'FLUTTER_ROOT': sdk.root.replaceAll('/', Platform.pathSeparator),
    };
    if (File(sdk.dart).existsSync()) {
      final result = await _run(sdk.dart, args, projectRoot, env);
      if (result.exitCode != _couldNotStart) return result;
    }
    // flutter.bat runs through cmd.exe, which would read some characters
    // in its path as commands.
    final problem = batchArgumentProblem(sdk.flutter, args);
    if (problem != null) {
      return PubResult(
        _couldNotStart,
        '',
        problem,
        command: '${sdk.flutter} ${args.join(' ')}',
      );
    }
    return _run(sdk.flutter, args, projectRoot, env);
  }

  static const int _couldNotStart = -1;

  static const Utf8Decoder _decoder = Utf8Decoder(allowMalformed: true);

  Future<PubResult> _run(
    String exe,
    List<String> args,
    String dir,
    Map<String, String> env,
  ) async {
    final command = '$exe ${args.join(' ')}';
    final Process process;
    try {
      process = await Process.start(
        exe,
        args,
        workingDirectory: dir,
        environment: env,
        runInShell: runsThroughCmd(exe),
      );
    } on ProcessException catch (e) {
      return PubResult(_couldNotStart, '', e.message, command: command);
    }
    final out = StringBuffer();
    final err = StringBuffer();
    final done = Future.wait([
      // Text that isn't UTF-8 (cmd.exe speaks the console's code page) is
      // shown with replacement characters rather than failing the run.
      process.stdout.transform(_decoder).forEach(out.write),
      process.stderr.transform(_decoder).forEach(err.write),
    ]);
    try {
      final code = await process.exitCode.timeout(timeout);
      // A child that keeps the output open (a daemon pub started) doesn't
      // keep the run waiting once pub itself is done.
      await done.timeout(_drainTime, onTimeout: () => const []);
      return PubResult(code, '$out', '$err', command: command);
    } on TimeoutException {
      done.ignore();
      _stopTree(process);
      return PubResult(
        124,
        '$out',
        '$err\npub get took longer than ${timeout.inMinutes} minutes and was '
            'stopped.',
        command: command,
      );
    }
  }
}

/// How long a finished program's output may stay open — held by a child it
/// left running — before it is read as it is.
const Duration _drainTime = Duration(seconds: 10);

/// Stops [process] and what it started: on Windows the whole tree
/// (`taskkill /T /F`) — a `.bat` runs under cmd.exe, which alone would
/// otherwise be stopped, leaving its Dart running — and elsewhere its
/// children first (`pkill -P`), then itself.
void _stopTree(Process process) {
  try {
    if (Platform.isWindows) {
      final r = Process.runSync('taskkill', [
        '/T',
        '/F',
        '/PID',
        '${process.pid}',
      ]);
      if (r.exitCode == 0) return;
    } else {
      Process.runSync('pkill', ['-KILL', '-P', '${process.pid}']);
    }
  } on Object {
    // Stopped below, alone.
  }
  process.kill(ProcessSignal.sigkill);
}

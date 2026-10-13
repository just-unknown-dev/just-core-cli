/// What a command runs in: where it is, what it may print, and whether it
/// may ask.
library;

import 'dart:io';

import '../project/just_project.dart';
import 'launcher.dart';
import 'version.dart';

/// The world one run of the tool sees. Commands read and print only through
/// this, so tests run them against a temporary folder and captured output.
final class JustContext {
  /// A context for a run in [workingDirectory], printing to [out] and [err],
  /// reading answers with [readLine].
  JustContext({
    String? workingDirectory,
    StringSink? out,
    StringSink? err,
    String? Function()? readLine,
    bool? interactive,
    Map<String, String>? environment,
    this.invokedAs = 'just',
    this.version = justCoreCliVersion,
    this.launcher = const ProcessLauncher(),
  }) : workingDirectory = normalPath(
         workingDirectory ?? Directory.current.path,
       ),
       out = out ?? stdout,
       err = err ?? stderr,
       readLine = readLine ?? stdin.readLineSync,
       environment = environment ?? Platform.environment,
       interactive = interactive ?? _hasTerminal();

  /// The folder the tool was run in.
  final String workingDirectory;

  /// Where results go. With `--json`, only the one JSON document.
  final StringSink out;

  /// Where messages for a person go: progress, warnings, errors.
  final StringSink err;

  /// Reads one line of the user's answer; null at the end of input.
  final String? Function() readLine;

  /// Whether a person is there to answer: stdin and stdout are a terminal.
  final bool interactive;

  /// The environment variables.
  final Map<String, String> environment;

  /// The name the tool was started as — `just` or `ju` — for help and
  /// messages.
  final String invokedAs;

  /// This tool's version.
  final String version;

  /// Starts other programs: `dart run` for plugins, `flutter`.
  final Launcher launcher;

  /// The project the tool was run in: the nearest folder at or above
  /// [workingDirectory] with a `pubspec.yaml`, or the one [projectOverride]
  /// names when it holds one. Null when there is none.
  JustProject? get project {
    if (!_found) {
      final named = _projectOverride;
      if (named != null) {
        // A folder `--project` names is a project only with a pubspec in
        // it: a typo is no project, not a new one.
        final p = JustProject(
          File(named).isAbsolute ? named : '$workingDirectory/$named',
        );
        _project = p.exists ? p : null;
      } else {
        _project = JustProject.find(workingDirectory);
      }
      _found = true;
    }
    return _project;
  }

  JustProject? _project;
  bool _found = false;

  /// The folder `--project` named (absolute, or relative to
  /// [workingDirectory]), when it did. Setting it changes [project] from
  /// then on.
  String? get projectOverride => _projectOverride;
  set projectOverride(String? folder) {
    if (folder == _projectOverride) return;
    _projectOverride = folder;
    _found = false;
  }

  String? _projectOverride;

  static bool _hasTerminal() {
    try {
      return stdin.hasTerminal && stdout.hasTerminal;
    } on Object {
      return false;
    }
  }
}

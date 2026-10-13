/// The tool's entry points: `just` itself, and a plugin's.
library;

import 'dart:io';

import '../commands/check_command.dart';
import '../commands/create_command.dart';
import '../commands/dev_command.dart';
import '../commands/doctor_command.dart';
import '../commands/upgrade_command.dart';
import '../project/pub_runner.dart';
import 'command.dart';
import 'context.dart';
import 'failures.dart';
import 'output.dart';
import 'pinning.dart';
import 'plugin_command.dart';
import 'runner.dart';
import 'version.dart';

/// Runs the `just` tool on [args] and returns its exit code.
///
/// [invokedAs] is the name it was started as — `just`, or `ju` for people
/// whose `just` is another program — and shows in help and messages.
/// [context] replaces the real terminal and folder, for tests.
///
/// `--version` before the command name prints this tool's version (and
/// the project's pinned one, when it differs). Otherwise, in a project that
/// pins another version of just_core_cli, the run is handed to that version
/// ([ProjectPin]) — except `upgrade`, which moves the pin. Else the tool's
/// own commands run, and the commands plugins add: the project's packages'
/// first, then packages activated globally, the ecosystem's own winning a
/// name clash. `help <a plugin's command> [subcommand…]` is that plugin's
/// own help.
Future<int> runJust(
  List<String> args, {
  String invokedAs = 'just',
  JustContext? context,
}) async {
  final ctx = context ?? contextForRun(invokedAs);
  final project = _projectOption(args);
  if (project != null) ctx.projectOverride = project;
  final json = _hasFlag(args, '--json');
  final lead = _lead(args);

  if (lead.version) {
    return JustRunner(
      ctx,
      commands: [VersionCommand()],
    ).run(['version', if (json) '--json']);
  }

  try {
    final handedOver = await _handOver(ctx, args, lead.command, json: json);
    if (handedOver != null) return handedOver;
  } on CommandFailure catch (e) {
    return _failBeforeRunner(ctx, e.message, e.exitCode, json: json);
  } on ProcessException catch (e) {
    return _failBeforeRunner(
      ctx,
      'Could not start ${e.executable}: ${e.message.trim()}.',
      ExitCodes.failure,
      json: json,
    );
  } on Object catch (e) {
    // An unreadable pubspec, a broken package config: a message, not a
    // stack trace.
    return _failBeforeRunner(ctx, _describe(e), ExitCodes.failure, json: json);
  }

  final problems = <String>[];
  final builtIn = builtInCommands();
  final List<PluginCommand> plugins;
  try {
    plugins = discoverPluginCommands(
      ctx,
      taken: {for (final c in builtIn) c.name, 'help'},
      problems: problems,
    );
  } on Object catch (e) {
    return _failBeforeRunner(ctx, _describe(e), ExitCodes.failure, json: json);
  }
  final runner = JustRunner(ctx, commands: [...builtIn, ...plugins])
    ..argParser.addFlag(
      'version',
      negatable: false,
      help: "Print the tool's version (before a command's name).",
    );
  if (_hasFlag(args, '--verbose') || _hasFlag(args, '-v')) {
    for (final p in problems) {
      ctx.err.writeln('! $p');
    }
  }
  return runner.run(args);
}

/// The context for a real run in [environment] (this process's when
/// null): the user's folder is the one `just` was started in, or — for a
/// run handed over from a global `just` ([ProjectPin.delegatedVariable]
/// is `1`) — the one that `just` was started in, under the name it was
/// started as. Those variables mean nothing otherwise: a `just` a plugin
/// starts inherits the plugin's, and is a run of its own.
JustContext contextForRun(
  String invokedAs, {
  Map<String, String>? environment,
}) {
  final base = JustContext(invokedAs: invokedAs, environment: environment);
  final env = base.environment;
  if (env[ProjectPin.delegatedVariable] != '1') return base;
  final cwd = env[ProjectPin.cwdVariable];
  final asName = env['JUST_CORE_CLI_INVOKED_AS'];
  if (cwd == null && asName == null) return base;
  return JustContext(
    workingDirectory: cwd,
    invokedAs: asName ?? invokedAs,
    environment: environment,
  );
}

/// Whether [flag] is in [args] before any `--` (after which arguments are
/// another program's).
bool _hasFlag(List<String> args, String flag) {
  for (final a in args) {
    if (a == '--') return false;
    if (a == flag) return true;
  }
  return false;
}

/// The folder `--project` names in [args], if any.
String? _projectOption(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--') return null;
    if (a == '--project' && i + 1 < args.length) return args[i + 1];
    if (a.startsWith('--project=')) return a.substring('--project='.length);
  }
  return null;
}

/// The command [args] name — the first word that is neither an option nor
/// `--project`'s value — and whether `--version` comes before it.
({String? command, bool version}) _lead(List<String> args) {
  var version = false;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--') break;
    if (a == '--project') {
      i++;
      continue;
    }
    if (a.startsWith('-')) {
      if (a == '--version') version = true;
      continue;
    }
    return (command: a, version: version);
  }
  return (command: null, version: version);
}

/// [error] as a person reads it: a file's path and the system's reason for
/// a [FileSystemException], the message of anything else that has one.
String _describe(Object error) => switch (error) {
  FileSystemException(:final message, :final path, :final osError) =>
    '$message${path == null ? '' : ' ($path)'}'
        '${osError == null ? '' : ': ${osError.message}'}',
  CommandFailure(:final message) => message,
  FormatException(:final message) => message,
  _ => 'Unexpected error: $error',
};

/// A failure before the runner started: [message] on stderr, and with
/// `--json` the document saying so.
int _failBeforeRunner(
  JustContext ctx,
  String message,
  int code, {
  required bool json,
}) {
  ctx.err.writeln(message);
  Output(
    ctx,
    json: json,
  ).finish(command: ctx.invokedAs, exitCode: code, error: message);
  return code;
}

/// Runs [args] with the project's own just_core_cli when it pins another
/// version, returning its exit code; null when this one should run.
/// [command] is the command [args] name; with [json], what pub prints on
/// the way goes to stderr.
Future<int?> _handOver(
  JustContext ctx,
  List<String> args,
  String? command, {
  required bool json,
}) async {
  final project = ctx.project;
  if (project == null) return null;
  if (ctx.environment[ProjectPin.delegatedVariable] == '1') return null;
  if (!ProjectPin.declares(project)) return null;
  // `upgrade` moves the pin itself: it runs as this version, newer or not.
  if (command == 'upgrade') return null;
  final sdk = await SdkLocator.find(project.root, environment: ctx.environment);
  if (!ProjectPin.resolved(project)) {
    // A fresh clone: get its packages, as `dart run` would, to learn which
    // just it pins.
    ctx.err.writeln(
      "This project pins its own just; getting its packages first.",
    );
    await ctx.launcher.run(
      sdk?.flutter ?? 'dart',
      ['pub', 'get'],
      workingDirectory: project.root,
      toStderr: json,
    );
  }
  final pinned = ProjectPin.resolvedVersion(project);
  if (pinned == null || pinned == ctx.version) return null;
  if (_hasFlag(args, '--verbose') || _hasFlag(args, '-v')) {
    ctx.err.writeln(
      'Using the project\'s just_core_cli $pinned (this is ${ctx.version}).',
    );
  }
  return ctx.launcher.run(
    dartExecutable(sdk),
    ['run', 'just_core_cli:just', ...args],
    workingDirectory: project.root,
    environment: {
      ProjectPin.delegatedVariable: '1',
      ProjectPin.cwdVariable: ctx.workingDirectory,
      'JUST_CORE_CLI_INVOKED_AS': ctx.invokedAs,
      'FLUTTER_ROOT': ?sdk?.root,
    },
  );
}

/// The commands built into `just`: those every project of the ecosystem
/// has. A product's own commands come from its plugin.
List<JustCommand> builtInCommands() => [
  CheckCommand(),
  CreateCommand(),
  DevCommand(),
  DoctorCommand(),
  UpgradeCommand(),
  VersionCommand(),
];

/// Runs a plugin's [commands] on [args] — what a package's
/// `bin/just_plugin.dart` calls:
///
/// ```dart
/// import 'dart:io';
///
/// import 'package:just_core_cli/just_core_cli.dart';
/// import 'package:my_plugin/commands.dart';
///
/// Future<void> main(List<String> args) async =>
///     exitCode = await runJustPlugin(args, [MyPluginCommand()]);
/// ```
///
/// `just` runs it with `dart run <package>:just_plugin`, passing the whole
/// command line (the plugin's own command name first) and, in the
/// environment, the name it was started as (`JUST_CORE_CLI_INVOKED_AS`), the
/// project (`JUST_CORE_CLI_PROJECT`) and the folder the user was in
/// (`JUST_CORE_CLI_CWD`). The plugin gets the same global options, help, `--json`
/// output and exit codes as the tool's own commands.
Future<int> runJustPlugin(
  List<String> args,
  List<JustCommand> commands, {
  JustContext? context,
}) {
  final base = context ?? JustContext();
  final env = base.environment;
  final ctx =
      context ??
      JustContext(
        workingDirectory: env[ProjectPin.cwdVariable],
        invokedAs: env['JUST_CORE_CLI_INVOKED_AS'] ?? 'just',
        version: env['JUST_CORE_CLI_VERSION'] ?? justCoreCliVersion,
      );
  final project = _projectOption(args) ?? env['JUST_CORE_CLI_PROJECT'];
  if (project != null && project.isNotEmpty) ctx.projectOverride = project;
  return JustRunner(ctx, commands: commands).run(args);
}

/// `just version`: the tool's version, and the project's when it pins one.
final class VersionCommand extends JustCommand {
  /// The command.
  VersionCommand();

  @override
  String get name => 'version';

  @override
  String get description => "Print the tool's version.";

  @override
  Future<int> run() async {
    final project = context.project;
    final pinned = project == null ? null : ProjectPin.resolvedVersion(project);
    output
      ..result = {'version': context.version, 'project': pinned}
      ..line('just_core_cli ${context.version}');
    if (pinned != null && pinned != context.version) {
      output.line('(this project pins just_core_cli $pinned)');
    }
    return 0;
  }
}

/// Running `just` commands: global options, errors and exit codes.
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import '../json/json.dart';
import '../project/pubspec_editor.dart';
import '../project/transaction.dart';
import 'command.dart';
import 'context.dart';
import 'failures.dart';
import 'output.dart';

/// Runs `just` commands — the tool's own, or a plugin's.
///
/// Every run takes the same global options:
///
/// - `--json`: print one JSON document (see [Output]) and nothing else on
///   stdout.
/// - `--yes` / `-y`: go ahead without asking.
/// - `--verbose` / `-v`: more detail, and a stack trace for a crash.
/// - `--project <folder>`: the project to work on, instead of the nearest
///   one above the current folder.
///
/// [run] never throws: a failure is a message on stderr and an exit code
/// ([ExitCodes]).
class JustRunner extends CommandRunner<int> {
  /// A runner called [executableName] (as the user typed it), in [context].
  JustRunner(
    this.context, {
    String? executableName,
    String description = "The Just ecosystem's command-line tool.",
    Iterable<JustCommand> commands = const [],
  }) : super(executableName ?? context.invokedAs, description) {
    JustCommand.addGlobalOptions(argParser);
    commands.forEach(addCommand);
  }

  /// What this run sees.
  final JustContext context;

  // Help goes to the context's out, not print(): tests and plugins capture
  // it, and with --json it must not mix with the document.
  @override
  void printUsage() {
    if (!output.json) context.out.writeln(usage);
  }

  Output? _output;

  /// What this run prints. Set once the global options are read.
  Output get output => _output ??= Output(context, json: false);

  /// Whether `--yes` was given. Known once [run] has read the options.
  bool get yes => _yes;
  bool _yes = false;

  /// Runs [args] and returns the exit code. Never throws.
  @override
  Future<int> run(Iterable<String> args) async {
    final list = _pluginHelp(args.toList());
    ArgResults? parsed;
    var command = executableName;
    // Known before parsing, so even a run that fails to parse answers in
    // JSON when asked to.
    final options = _beforeDashDash(list);
    _output = Output(
      context,
      json: options.contains('--json'),
      verbose: options.contains('--verbose') || options.contains('-v'),
    );
    try {
      parsed = parse(list);
      // The global options may come before the command or after any part of
      // it; each parser in the chain has them.
      // (args' own `help` command has none of them.)
      bool given(String flag) {
        for (ArgResults? r = parsed; r != null; r = r.command) {
          if (r.options.contains(flag) && r.flag(flag)) return true;
        }
        return false;
      }

      String? project;
      for (ArgResults? r = parsed; r != null; r = r.command) {
        if (r.options.contains('project')) {
          project = r.option('project') ?? project;
        }
      }
      // A plugin's command passes its options on unparsed; `--json` and
      // `--yes` among them — before a `--` — still count here. Nothing
      // else does: an option's value (`--title --json`) is a value.
      final passed = _passedOn(parsed);
      _output = Output(
        context,
        json: given('json') || passed.contains('--json'),
        verbose: given('verbose'),
      );
      _yes = given('yes') || passed.contains('--yes');
      if (project != null) context.projectOverride = project;
      command = _commandPath(parsed);
      final code = await runCommand(parsed) ?? ExitCodes.ok;
      final ran = _commandOf(parsed);
      if (ran is! JustCommand || !ran.printsOwnDocument) {
        output.finish(command: command, exitCode: code);
      }
      return code;
    } on UsageException catch (e) {
      return _fail(command, ExitCodes.usage, e.message, usage: e.usage);
    } on UsageFailure catch (e) {
      final usage = _usageOf(parsed);
      return _fail(command, ExitCodes.usage, e.message, usage: usage);
    } on CommandFailure catch (e) {
      return _fail(command, e.exitCode, e.message);
    } on ProjectBusyException catch (e) {
      return _fail(command, ExitCodes.failure, e.message);
    } on JsonFormatException catch (e) {
      return _fail(command, ExitCodes.failure, '$e');
    } on PubspecEditException catch (e) {
      return _fail(command, ExitCodes.failure, e.message);
    } on FileSystemException catch (e) {
      final path = e.path == null ? '' : ' (${e.path})';
      final why = e.osError?.message ?? '';
      return _fail(
        command,
        ExitCodes.failure,
        '${e.message}$path${why.isEmpty ? '' : ': $why'}',
      );
    } on FormatException catch (e) {
      return _fail(command, ExitCodes.failure, e.message);
    } on Object catch (e, stack) {
      final verbose = _output?.verbose ?? false;
      return _fail(
        command,
        ExitCodes.failure,
        'Unexpected error: $e\n'
        '${verbose ? '$stack' : 'Run again with --verbose for details.'}',
      );
    }
  }

  /// [args] with `help <command> [subcommand…]` turned into
  /// `<command> [subcommand…] --help` when the command passes everything on
  /// (a plugin's): only the plugin knows its subcommands. Anything else as
  /// it is.
  List<String> _pluginHelp(List<String> args) {
    final words = <int>[];
    for (var i = 0; i < args.length && words.length < 2; i++) {
      final a = args[i];
      if (a == '--') break;
      if (a == '--project') {
        i++;
        continue;
      }
      if (!a.startsWith('-')) words.add(i);
    }
    if (words.length < 2 || args[words[0]] != 'help') return args;
    final command = commands[args[words[1]]];
    if (command == null || !command.argParser.allowsAnything) return args;
    return [
      ...args.take(words[0]),
      ...args.skip(words[0] + 1).takeWhile((a) => a != '--'),
      '--help',
    ];
  }

  /// [args] up to the first `--`: after it, arguments are another
  /// program's.
  static List<String> _beforeDashDash(List<String> args) =>
      args.takeWhile((a) => a != '--').toList();

  /// What a command that takes anything (a plugin's) was given, up to a
  /// `--`; empty for any other command.
  List<String> _passedOn(ArgResults parsed) {
    final command = _commandOf(parsed);
    if (command == null || !command.argParser.allowsAnything) return const [];
    var r = parsed;
    while (r.command != null) {
      r = r.command!;
    }
    return _beforeDashDash(r.rest);
  }

  String _commandPath(ArgResults parsed) {
    final names = <String>[];
    ArgResults? r = parsed.command;
    while (r != null) {
      names.add(r.name!);
      r = r.command;
    }
    return names.isEmpty ? executableName : names.join(' ');
  }

  String _usageOf(ArgResults? parsed) => _commandOf(parsed)?.usage ?? usage;

  /// The command [parsed] names (the innermost subcommand), or null.
  Command<int>? _commandOf(ArgResults? parsed) {
    Command<int>? c;
    var r = parsed?.command;
    var commands = this.commands;
    while (r != null) {
      final next = commands[r.name];
      if (next == null) break;
      c = next;
      commands = next.subcommands;
      r = r.command;
    }
    return c;
  }

  int _fail(String command, int code, String message, {String? usage}) {
    final out = output;
    context.err.writeln(message);
    if (usage != null && !out.json) {
      context.err
        ..writeln()
        ..writeln(usage);
    }
    out.finish(command: command, exitCode: code, error: message);
    return code;
  }
}

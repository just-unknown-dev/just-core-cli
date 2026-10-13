/// The base of every `just` command, built in or from a plugin.
library;

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import '../project/just_project.dart';
import 'context.dart';
import 'failures.dart';
import 'output.dart';
import 'runner.dart';

/// A `just` command.
///
/// Subclasses set [name], [description] and their options in the
/// constructor (`argParser.addFlag(...)`), and implement [run], returning
/// an exit code ([ExitCodes]). They print through [output] and read the
/// world through [context], and throw [CommandFailure] or [UsageFailure]
/// for what the user can fix — the runner turns those into a message and
/// an exit code, never a stack trace.
///
/// A command with subcommands adds them with [addSubcommand] and has no
/// [run] of its own.
abstract class JustCommand extends Command<int> {
  /// A command taking the global options too, so they work after its name:
  /// `just dev link ../packages --json` as well as `just --json dev link …`.
  JustCommand() {
    // A plugin's command passes everything on, options included.
    if (!argParser.allowsAnything) addGlobalOptions(argParser);
  }

  /// Adds `--json`, `--yes`, `--verbose` and `--project` to [parser].
  static void addGlobalOptions(ArgParser parser) {
    parser
      ..addFlag(
        'json',
        negatable: false,
        help: 'Print one JSON document on stdout; messages go to stderr.',
      )
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Go ahead without asking (for scripts and CI).',
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help: 'Show more detail.',
      )
      ..addOption(
        'project',
        valueHelp: 'folder',
        help:
            'The project to work on (default: the nearest one at or above '
            'the current folder).',
      );
  }

  /// The runner running this command.
  JustRunner get justRunner => runner! as JustRunner;

  /// What this run sees.
  JustContext get context => justRunner.context;

  /// What it prints.
  Output get output => justRunner.output;

  /// Whether `--yes` was given: go ahead without asking.
  bool get yes => justRunner.yes;

  /// Whether a successful run prints its own `--json` document — it hands
  /// the run to another program that does (a plugin), or has no document
  /// (a command that runs an app, whose output is the app's). The runner
  /// then prints none.
  /// Failures before the hand-over still get the runner's document.
  bool get printsOwnDocument => false;

  @override
  void printUsage() {
    if (!output.json) context.out.writeln(usage);
  }

  /// The arguments after the command's name and options.
  List<String> get rest => argResults?.rest ?? const [];

  /// The command as typed: `dev link`.
  String get path {
    final names = <String>[];
    Command<int>? c = this;
    while (c != null) {
      names.insert(0, c.name);
      c = c.parent;
    }
    return names.join(' ');
  }

  /// The project the command runs in. Throws [CommandFailure] when there is
  /// none.
  JustProject requireProject() {
    final project = context.project;
    if (project != null) return project;
    final named = context.projectOverride;
    throw CommandFailure(
      named != null
          ? 'No pubspec.yaml in $named (--project): it is not a project.'
          : 'No pubspec.yaml in ${context.workingDirectory} or any folder '
                'above it. Run this in a project, or pass --project <folder>.',
    );
  }

  /// The one argument after the options, named [what] in the error when it
  /// is missing or there are more.
  String singleArgument(String what) {
    if (rest.length != 1) {
      throw UsageFailure(
        rest.isEmpty
            ? '$name needs $what.'
            : '$name takes one $what, not ${rest.length}.',
      );
    }
    return rest.single;
  }

  /// Asks [question] and returns whether the user said yes. With `--yes`,
  /// yes without asking. With nobody to ask (a script, CI), throws a
  /// [CommandFailure] that says to pass `--yes`.
  bool confirm(String question) {
    if (yes) return true;
    if (!context.interactive) {
      throw CommandFailure(
        'Nothing was changed: $question needs a yes. Run again with --yes '
        'to go ahead without asking (in a script or CI).',
      );
    }
    context.err.write('$question [y/N] ');
    final answer = context.readLine()?.trim().toLowerCase() ?? '';
    return answer == 'y' || answer == 'yes';
  }
}

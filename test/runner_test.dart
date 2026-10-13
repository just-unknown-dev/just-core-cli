// The command framework: global options, one JSON document, asking, and
// the exit codes every command shares.

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:just_core_cli/just_core_cli.dart';
import 'package:just_core_cli/src/cli/entry.dart' show contextForRun;
import 'package:test/test.dart';

final class _Fails extends JustCommand {
  _Fails(this.error);
  final Object error;

  @override
  String get name => 'fails';

  @override
  String get description => 'Throws.';

  @override
  Future<int> run() async => throw error;
}

final class _Asks extends JustCommand {
  @override
  String get name => 'asks';

  @override
  String get description => 'Asks before it changes anything.';

  @override
  Future<int> run() async {
    if (!confirm('Change it?')) {
      output.line('Left alone.');
      return 1;
    }
    output
      ..result = {'changed': true}
      ..line('Changed.');
    return 0;
  }
}

final class _Own extends JustCommand {
  _Own(this.error);
  final Object? error;

  @override
  String get name => 'own';

  @override
  String get description => 'Prints its own document.';

  @override
  bool get printsOwnDocument => true;

  @override
  Future<int> run() async {
    if (error case final e?) throw e;
    return 0;
  }
}

final class _Group extends JustCommand {
  _Group() {
    addSubcommand(_Asks());
  }

  @override
  String get name => 'group';

  @override
  String get description => 'Has subcommands.';
}

void main() {
  late StringBuffer out, err;
  late List<String> answers;

  JustContext context({bool interactive = false, Map<String, String>? env}) =>
      JustContext(
        workingDirectory: Directory.systemTemp.path,
        out: out,
        err: err,
        interactive: interactive,
        readLine: () => answers.isEmpty ? null : answers.removeAt(0),
        environment: env ?? const {},
      );

  Future<int> run(
    List<String> args,
    List<JustCommand> commands, {
    bool interactive = false,
  }) => JustRunner(
    context(interactive: interactive),
    commands: commands,
  ).run(args);

  setUp(() {
    out = StringBuffer();
    err = StringBuffer();
    answers = [];
  });

  test('an unknown command is a usage error', () async {
    expect(await run(['nope'], [_Asks()]), ExitCodes.usage);
    expect('$err', contains('Could not find a command named "nope"'));
  });

  test('a CommandFailure is its message and exit code, no stack', () async {
    final code = await run(
      ['fails'],
      [_Fails(const CommandFailure('Broken.', exitCode: 3))],
    );
    expect(code, 3);
    expect('$err'.trim(), 'Broken.');
  });

  test("a UsageFailure prints the command's usage", () async {
    final code = await run(['fails'], [_Fails(const UsageFailure('Wrong.'))]);
    expect(code, ExitCodes.usage);
    expect('$err', contains('Wrong.'));
    expect('$err', contains('Usage: just fails'));
  });

  test('anything else is a failure, with details only on --verbose', () async {
    expect(await run(['fails'], [_Fails(StateError('oops'))]), 1);
    expect('$err', contains('Unexpected error: Bad state: oops'));
    expect('$err', contains('--verbose'));
    err.clear();
    await run(['fails', '-v'], [_Fails(StateError('oops'))]);
    expect('$err', contains('runner_test.dart'));
  });

  test('a file that is not there is a plain message', () async {
    final code = await run(
      ['fails'],
      [_Fails(const FileSystemException('Cannot open file', 'x.json'))],
    );
    expect(code, 1);
    expect('$err', contains('Cannot open file (x.json)'));
  });

  group('asking', () {
    test(
      'with nobody to ask, nothing changes and --yes is suggested',
      () async {
        expect(await run(['asks'], [_Asks()]), 1);
        expect('$err', contains('--yes'));
        expect('$out', isEmpty);
      },
    );

    test('--yes goes ahead', () async {
      expect(await run(['asks', '--yes'], [_Asks()]), 0);
      expect('$out', contains('Changed.'));
    });

    test('a person can say yes or no', () async {
      answers = ['y'];
      expect(await run(['asks'], [_Asks()], interactive: true), 0);
      answers = ['n'];
      expect(await run(['asks'], [_Asks()], interactive: true), 1);
      expect('$out', contains('Left alone.'));
    });
  });

  group('--json', () {
    test('prints one document, with the result', () async {
      expect(await run(['group', 'asks', '-y', '--json'], [_Group()]), 0);
      final doc = jsonDecode('$out') as Map;
      expect(doc['ok'], isTrue);
      expect(doc['command'], 'group asks');
      expect(doc['result'], {'changed': true});
      expect(doc['error'], isNull);
    });

    test('a failure is a document too', () async {
      await run(['fails', '--json'], [_Fails(const CommandFailure('No.'))]);
      final doc = jsonDecode('$out') as Map;
      expect(doc['ok'], isFalse);
      expect(doc['exitCode'], 1);
      expect(doc['error'], 'No.');
    });

    test('even when the options do not parse', () async {
      expect(await run(['--nope', '--json'], [_Asks()]), ExitCodes.usage);
      expect((jsonDecode('$out') as Map)['ok'], isFalse);
    });
  });

  group('a command that prints its own document', () {
    test(
      'gets none from the runner when it succeeds, one when it fails',
      () async {
        expect(await run(['own', '--json'], [_Own(null)]), 0);
        expect('$out', isEmpty);
        expect(
          await run(['own', '--json'], [_Own(const CommandFailure('No.'))]),
          1,
        );
        expect((jsonDecode('$out') as Map)['error'], 'No.');
      },
    );
  });

  group('the launcher', () {
    test('a program that is not there is a CommandFailure', () async {
      await expectLater(
        const ProcessLauncher().run('just_core_cli_no_such_program', const []),
        throwsA(isA<CommandFailure>()),
      );
    });

    test(
      "an argument cmd.exe would read as a command is refused, unstarted",
      () async {
        final dir = Directory.systemTemp.createTempSync('just_bat_');
        addTearDown(() => dir.deleteSync(recursive: true));
        final marker = File('${dir.path}/ran.txt');
        final bat = File('${dir.path}/tool.bat')
          ..writeAsStringSync('@echo off\r\necho ran> "${marker.path}"\r\n');
        for (final arg in ['R&D', '100%PATH%', 'a|b']) {
          await expectLater(
            const ProcessLauncher().run(bat.path, ['create', 'C:/x/$arg/game']),
            throwsA(isA<CommandFailure>()),
            reason: arg,
          );
        }
        expect(marker.existsSync(), isFalse);
        expect(await const ProcessLauncher().run(bat.path, ['plain']), 0);
        expect(marker.existsSync(), isTrue);
      },
      skip: Platform.isWindows ? false : 'cmd.exe is Windows-only',
    );

    test('a program ended by a signal reports 128 + the signal', () {
      expect(ProcessLauncher.exitCodeOf(-2, isWindows: false), 130);
      expect(ProcessLauncher.exitCodeOf(-15, isWindows: false), 143);
      expect(ProcessLauncher.exitCodeOf(3, isWindows: false), 3);
      expect(
        ProcessLauncher.exitCodeOf(-1073741510, isWindows: true),
        -1073741510,
      );
    });
  });

  group('the entry points', () {
    test('--version, and the name it was started as', () async {
      final ctx = context();
      expect(await runJust(['--version'], context: ctx), 0);
      expect('$out', 'just_core_cli $justCoreCliVersion\n');
      out.clear();
      final ju = JustContext(
        workingDirectory: Directory.systemTemp.path,
        out: out,
        err: err,
        invokedAs: 'ju',
        interactive: false,
      );
      await runJust(['--help'], context: ju);
      expect('$out', contains('Usage: ju <command>'));
    });

    test('a plugin reads the project and name from the environment', () async {
      final dir = Directory.systemTemp.createTempSync('just_plugin_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/pubspec.yaml').writeAsStringSync('name: x\n');
      final ctx = context(
        env: {
          'JUST_CORE_CLI_PROJECT': dir.path,
          'JUST_CORE_CLI_INVOKED_AS': 'ju',
        },
      );
      final code = await runJustPlugin(['asks', '-y'], [_Asks()], context: ctx);
      expect(code, 0);
      expect(ctx.project!.root, dir.absolute.path.replaceAll(r'\', '/'));
    });
  });

  test("a run takes the user's folder and name from a hand-over only", () {
    final env = {
      'JUST_CORE_CLI_CWD': '/somewhere/else',
      'JUST_CORE_CLI_INVOKED_AS': 'zz',
    };
    // A `just` a plugin started inherits the plugin's variables: its own.
    final own = contextForRun('ju', environment: env);
    expect(own.invokedAs, 'ju');
    expect(own.workingDirectory, Directory.current.path.replaceAll(r'\', '/'));
    final handed = contextForRun(
      'ju',
      environment: {...env, ProjectPin.delegatedVariable: '1'},
    );
    expect(handed.invokedAs, 'zz');
    expect(handed.workingDirectory, '/somewhere/else');
  });
}

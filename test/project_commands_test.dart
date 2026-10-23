// `just create`, `just dev link|unlink` and `just doctor`, with a launcher
// that plays flutter, pub and the plugins instead of running them.

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:just_core_cli/just_core_cli.dart';
import 'package:just_core_cli/project.dart';
import 'package:test/test.dart';

/// One program run, as the launcher saw it.
final class _Run {
  _Run(
    this.arguments,
    this.workingDirectory,
    this.env,
    this.toStderr,
    this.captured,
  );
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String> env;
  final bool toStderr;

  /// Whether its stdout was read (a plugin's `--json` document).
  final bool captured;
}

/// Plays `flutter create`, `pub get` and the plugins.
final class _Flutter implements Launcher {
  /// [plugins] are what `pub get` resolves: each package's folder, with
  /// where the lockfile says it came from (`path`, or a package server's
  /// URL).
  _Flutter([this.plugins = const {}]);

  final Map<Directory, String> plugins;

  final List<_Run> runs = [];

  /// The run (counting from 0) that fails, if any, and its exit code.
  int failOn = -1;
  int failCode = 1;

  @override
  Future<int> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String> environment = const {},
    bool toStderr = false,
    StringSink? stdout,
  }) async {
    runs.add(
      _Run(arguments, workingDirectory, environment, toStderr, stdout != null),
    );
    if (runs.length - 1 == failOn) return failCode;
    // A plugin's document: what it ran.
    stdout?.write(
      jsonEncode({
        'ok': true,
        'result': {'ran': arguments.skip(2).take(2).join(' ')},
      }),
    );
    if (arguments.first == 'create') {
      // What `flutter create --empty` leaves that create builds on.
      final dir = Directory(arguments.last)..createSync(recursive: true);
      File('${dir.path}/pubspec.yaml').writeAsStringSync(
        'name: ${arguments[3]}\n'
        'environment:\n  sdk: ^3.12.2\n\n'
        'dependencies:\n  flutter:\n    sdk: flutter\n\n'
        'dev_dependencies:\n  flutter_test:\n    sdk: flutter\n',
      );
      File('${dir.path}/.gitignore').writeAsStringSync('build/\n');
    }
    if (arguments.length >= 2 &&
        arguments[0] == 'pub' &&
        arguments[1] == 'get') {
      final lock = StringBuffer('packages:\n');
      plugins.forEach((dir, source) {
        final name = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
        lock.writeln(
          '  $name:\n    dependency: "direct dev"\n    description:',
        );
        if (source == 'path') {
          final path = normalPath(dir.absolute.path).replaceAll(r'\', r'\\');
          lock.writeln(
            '      path: "$path"\n      relative: false\n    source: path',
          );
        } else {
          lock.writeln(
            '      name: $name\n      url: "$source"\n    source: hosted',
          );
        }
        lock.writeln('    version: "0.1.0"');
      });
      File('$workingDirectory/pubspec.lock').writeAsStringSync('$lock');
      File('$workingDirectory/.dart_tool/package_config.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              for (final dir in plugins.keys)
                {
                  'name': dir.uri.pathSegments.where((s) => s.isNotEmpty).last,
                  'rootUri': dir.absolute.uri.toString(),
                  'packageUri': 'lib/',
                },
            ],
          }),
        );
    }
    return 0;
  }
}

void main() {
  late Directory tmp;
  late _Flutter flutter;
  late StringBuffer out, err;

  JustContext context(String cwd, {bool interactive = false}) => JustContext(
    workingDirectory: cwd,
    out: out,
    err: err,
    interactive: interactive,
    readLine: () => 'y',
    environment: {
      'FLUTTER_ROOT': '${tmp.path}/flutter',
      'PUB_CACHE': '${tmp.path}/none',
    },
    launcher: flutter,
  );

  const gameManifest = {
    'schema': 1,
    'commands': [
      {'name': 'game', 'summary': 'Games.'},
    ],
    'hooks': {
      'create': 'game init',
      'doctor': 'game doctor',
      'migrate': 'game migrate',
      'link': 'game link',
    },
  };

  /// Local checkouts: the tools, the game plugin, two store items, a
  /// library, and an old copy.
  Directory checkouts({Object? game = gameManifest}) {
    final dir = Directory('${tmp.path}/packages');
    for (final (name, item) in [
      ('just_core_cli', false),
      ('just_game_engine_cli', false),
      ('just_game_engine', false),
      ('just_game_engine_editor', true),
      ('just_asset_store', true),
      ('just_sprite_editor', true),
      ('just_game_engine_old', false),
    ]) {
      final p = Directory('${dir.path}/$name')..createSync(recursive: true);
      File(
        '${p.path}/pubspec.yaml',
      ).writeAsStringSync('name: $name\nversion: 0.1.0\n');
      if (item) File('${p.path}/just_store.json').writeAsStringSync('{}');
    }
    File('${dir.path}/just_asset_store/just_plugin.json').writeAsStringSync(
      jsonEncode({
        'commands': [
          {'name': 'store'},
        ],
      }),
    );
    if (game != null) {
      File(
        '${dir.path}/just_game_engine_cli/just_plugin.json',
      ).writeAsStringSync(jsonEncode(game));
    }
    return dir;
  }

  /// What `pub get` resolves from [packages]: the game plugin and the
  /// store, the game plugin from [gameSource].
  /// A plugin checkout named [name] in [plugins].
  void pluginCheckout(Directory plugins, String name) {
    File('${plugins.path}/$name/pubspec.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('name: $name\nversion: 0.1.0\n');
  }

  /// A workspace's other folder of checkouts, beside [checkouts]: the
  /// plugins (a kit).
  Directory pluginCheckouts() {
    final dir = Directory('${tmp.path}/plugins')..createSync();
    pluginCheckout(dir, 'just_world_builder_kit');
    return dir;
  }

  _Flutter resolving(
    Directory packages, {
    String gameSource = 'path',
    String storeSource = 'path',
  }) => _Flutter({
    Directory('${packages.path}/just_game_engine_cli'): gameSource,
    Directory('${packages.path}/just_asset_store'): storeSource,
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('just_cmds_');
    // A Flutter SDK SdkLocator accepts.
    File(
      '${tmp.path}/flutter/bin/flutter${Platform.isWindows ? '.bat' : ''}',
    ).createSync(recursive: true);
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('create', () {
    test('--local makes a linked project and hands it to the kind\'s '
        'plugin', () async {
      final packages = checkouts();
      flutter = resolving(packages);
      final code = await runJust([
        'create',
        'space_game',
        '--local',
        packages.path,
        '--title',
        'Space Game',
      ], context: context(tmp.path));
      expect(code, 0, reason: '$err');
      final project = JustProject('${tmp.path}/space_game');

      expect(flutter.runs.first.arguments.take(4), [
        'create',
        '--empty',
        '--project-name',
        'space_game',
      ]);
      expect(flutter.runs[1].arguments, ['pub', 'get']);
      final hook = flutter.runs[2];
      expect(hook.arguments, [
        'run',
        'just_game_engine_cli:just_plugin',
        'game',
        'init',
        '--title=Space Game',
        '--org=com.example',
        '--platforms=windows,macos,linux,android,ios,web',
        '--local=${normalPath(packages.absolute.path)}',
      ], reason: 'no --yes: the user gave none');
      expect(hook.workingDirectory, project.root);
      expect(hook.env['JUST_CORE_CLI_PROJECT'], project.root);
      expect(hook.captured, isFalse);
      expect(flutter.runs, hasLength(3));

      final file = project.readProjectFile();
      expect((file.title, file.set), ('Space Game', ToolSet.current.id));
      final pubspec = project.readText('pubspec.yaml')!;
      expect(
        pubspec,
        endsWith(
          '  flutter_test:\n    sdk: flutter\n'
          '  just_core_cli: ^0.1.0\n'
          '  just_game_engine_cli: ^0.1.0\n',
        ),
        reason: 'plain entries, as a person writes them',
      );
      expect(pubspec, isNot(contains('managed')));
      final links = DevLinks.linked(project);
      expect(
        links.keys,
        containsAll([
          'just_core_cli',
          'just_game_engine_cli',
          'just_game_engine',
        ]),
      );
      expect(links.keys, isNot(contains('just_game_engine_old')));
      expect(
        project.readText('.gitignore'),
        allOf(contains('pubspec_overrides.yaml\n'), contains('.just_trash/\n')),
      );
      expect('$out', contains('Created Space Game in ${project.root}.'));
    });

    test('--local more than once links each folder, and hands each to the '
        "kind's plugin; a package in two of them stops it first", () async {
      final packages = checkouts();
      final plugins = pluginCheckouts();
      flutter = resolving(packages);
      expect(
        await runJust([
          'create',
          'space_game',
          '--local',
          packages.path,
          '--local',
          plugins.path,
        ], context: context(tmp.path)),
        0,
        reason: '$err',
      );
      final project = JustProject('${tmp.path}/space_game');
      expect(flutter.runs[2].arguments.where((a) => a.startsWith('--local=')), [
        '--local=${normalPath(packages.absolute.path)}',
        '--local=${normalPath(plugins.absolute.path)}',
      ]);
      expect(
        DevLinks.linked(project)['just_world_builder_kit'],
        '../plugins/just_world_builder_kit',
      );
      expect(DevLinks.linked(project), contains('just_game_engine'));

      // The same package in both folders: which to link is the developer's.
      pluginCheckout(plugins, 'just_game_engine');
      flutter = resolving(packages);
      expect(
        await runJust([
          'create',
          'other_game',
          '--local',
          packages.path,
          '--local',
          plugins.path,
        ], context: context(tmp.path)),
        1,
      );
      expect(
        '$err',
        contains('just_game_engine is checked out in more than one folder'),
      );
      expect(flutter.runs, isEmpty, reason: 'nothing was created');
      expect(Directory('${tmp.path}/other_game').existsSync(), isFalse);
    });

    test('with --json the tools print to stderr, and the hook gets --yes, '
        "--json, --verbose, --template and --source; its document is in the "
        'result', () async {
      final packages = checkouts();
      flutter = resolving(packages);
      final code = await runJust([
        'create',
        'quiet_game',
        '--local',
        packages.path,
        '--template',
        'studio_kit',
        '--source',
        'a',
        '--source',
        'b',
        '--yes',
        '--json',
        '-v',
      ], context: context(tmp.path));
      expect(code, 0, reason: '$err');
      expect(flutter.runs.take(2).every((r) => r.toStderr), isTrue);
      expect(flutter.runs.last.captured, isTrue);
      final hook = flutter.runs.last.arguments.join(' ');
      expect(
        hook,
        contains('--template=studio_kit --source=a --source=b --local='),
      );
      expect(hook, endsWith('--yes --json --verbose'));
      final doc = jsonDecode('$out') as Map;
      expect(doc['ok'], isTrue);
      final result = doc['result'] as Map;
      expect(result['kind'], 'game');
      expect(result['template'], 'studio_kit');
      expect(result['just_game_engine_cli'], {
        'hook': 'game init',
        'ok': true,
        'exitCode': 0,
        'result': {'ran': 'game init'},
      });
    });

    test('a title reaches the hook exactly as typed', () async {
      final packages = checkouts();
      flutter = resolving(packages);
      const title = r'''Bob's "Big" $Game\ & <Co>''';
      expect(
        await runJust([
          'create',
          'bobs_game',
          '--local',
          packages.path,
          '--title',
          title,
        ], context: context(tmp.path)),
        0,
        reason: '$err',
      );
      final args = flutter.runs.last.arguments;
      expect(args, contains('--title=$title'));
      expect(
        JustProject('${tmp.path}/bobs_game').readProjectFile().title,
        title,
      );
    });

    test("upgrade moves the tools create added", () async {
      final packages = checkouts();
      flutter = resolving(packages);
      expect(
        await runJust([
          'create',
          'old_game',
          '--local',
          packages.path,
        ], context: context(tmp.path)),
        0,
        reason: '$err',
      );
      final project = JustProject('${tmp.path}/old_game');
      final pubspec = project.file('pubspec.yaml');
      pubspec.writeAsStringSync(
        pubspec.readAsStringSync().replaceAll('^0.1.0', '^0.0.1'),
      );
      expect(
        await runJust(['upgrade', '--yes'], context: context(project.root)),
        0,
        reason: '$err',
      );
      for (final tool in ['just_core_cli', 'just_game_engine_cli']) {
        expect(
          PubspecConstraints.of(
            project.readText('pubspec.yaml')!,
            'dev_dependencies',
            tool,
          ),
          ToolSet.current[tool]!.constraint,
          reason: tool,
        );
      }
      expect([
        for (final r in flutter.runs) r.arguments.skip(2).join(' '),
      ], containsAll(['game migrate --check', 'game migrate --yes']));
    });

    test("behind a package mirror the kind's plugin is asked about, and an "
        "answer is kept in the new project's just.json", () async {
      final packages = checkouts();
      flutter = resolving(packages, gameSource: 'https://pub.example.com');
      expect(
        await runJust([
          'create',
          'mirror_game',
          '--local',
          packages.path,
        ], context: context(tmp.path, interactive: true)),
        0,
        reason: '$err',
      );
      expect('$err', contains('Allow just_game_engine_cli to run'));
      expect(
        JustProject('${tmp.path}/mirror_game').readProjectFile().allowedPlugins,
        ['just_game_engine_cli'],
      );
      expect(flutter.runs.last.arguments.skip(2).take(2), ['game', 'init']);
    });

    test('a failing hook leaves no half-made folder behind', () async {
      final packages = checkouts();
      flutter = resolving(packages)..failOn = 2;
      final code = await runJust([
        'create',
        'broken',
        '--local',
        packages.path,
      ], context: context(tmp.path));
      expect(code, 1);
      expect('$err', contains('`create` hook) failed'));
      expect(Directory('${tmp.path}/broken').existsSync(), isFalse);
    });

    test('an empty folder that was there is emptied again on a failure, and '
        'kept', () async {
      final packages = checkouts();
      flutter = resolving(packages)..failOn = 2;
      final dir = Directory('${tmp.path}/ready')..createSync();
      expect(
        await runJust([
          'create',
          'ready',
          '--local',
          packages.path,
        ], context: context(tmp.path)),
        1,
      );
      expect(dir.existsSync(), isTrue);
      expect(dir.listSync(), isEmpty);
    });

    test("a title that looks like an option is a title, and doesn't turn on "
        'JSON', () async {
      final packages = checkouts();
      flutter = resolving(packages);
      expect(
        await runJust([
          'create',
          'odd_game',
          '--local',
          packages.path,
          '--title',
          '--json',
        ], context: context(tmp.path)),
        0,
        reason: '$err',
      );
      expect('$out', contains('Created --json in'));
      expect(flutter.runs.last.arguments, contains('--title=--json'));
      expect(flutter.runs.last.arguments, isNot(contains('--json')));
    });

    test('a failing pub get leaves no half-made folder behind', () async {
      final packages = checkouts();
      flutter = resolving(packages)..failOn = 1;
      expect(
        await runJust([
          'create',
          'broken',
          '--local',
          packages.path,
        ], context: context(tmp.path)),
        1,
      );
      expect('$err', contains('flutter pub get failed'));
      expect(Directory('${tmp.path}/broken').existsSync(), isFalse);
    });

    test("a kind's plugin that isn't the ecosystem's, or has no create "
        'hook, is not run', () async {
      var packages = checkouts();
      flutter = resolving(packages, gameSource: 'https://pub.example.com');
      expect(
        await runJust([
          'create',
          'a_game',
          '--local',
          packages.path,
        ], context: context(tmp.path)),
        1,
      );
      expect('$err', contains('not from a local checkout'));
      expect(flutter.runs, hasLength(2), reason: 'flutter create, pub get');
      expect(Directory('${tmp.path}/a_game').existsSync(), isFalse);

      packages.deleteSync(recursive: true);
      packages = checkouts(
        game: {
          'commands': [
            {'name': 'game'},
          ],
        },
      );
      flutter = resolving(packages);
      err.clear();
      expect(
        await runJust([
          'create',
          'a_game',
          '--local',
          packages.path,
        ], context: context(tmp.path)),
        1,
      );
      expect('$err', contains('has no `create` hook'));
      expect(Directory('${tmp.path}/a_game').existsSync(), isFalse);
    });

    test('a title with a control character is refused', () async {
      flutter = _Flutter();
      expect(
        await runJust([
          'create',
          'my_game',
          '--title',
          'Line\nbreak',
        ], context: context(tmp.path)),
        ExitCodes.usage,
      );
      expect('$err', contains('control character'));
      expect(flutter.runs, isEmpty);
    });

    test('a name that is not a package name, a full folder, an unknown kind '
        'or a template that is no id is refused', () async {
      flutter = _Flutter();
      expect(
        await runJust(['create', 'My Game'], context: context(tmp.path)),
        ExitCodes.usage,
      );
      Directory('${tmp.path}/taken/lib').createSync(recursive: true);
      expect(await runJust(['create', 'taken'], context: context(tmp.path)), 1);
      expect('$err', contains('not empty'));
      expect(
        await runJust([
          'create',
          'x',
          '--kind',
          'spreadsheet',
        ], context: context(tmp.path)),
        ExitCodes.usage,
      );
      expect(
        await runJust([
          'create',
          'x',
          '--template',
          'Not An Id',
        ], context: context(tmp.path)),
        ExitCodes.usage,
      );
      expect(flutter.runs, isEmpty);
    });
  });

  group('dev link', () {
    late JustProject project;
    setUp(() {
      final dir = Directory('${tmp.path}/game')..createSync();
      File('${dir.path}/pubspec.yaml').writeAsStringSync(
        'name: game\ndependencies:\n  just_game_engine: ^2.0.0\n',
      );
      File(
        '${dir.path}/.gitignore',
      ).writeAsStringSync('pubspec_overrides.yaml\n');
      project = JustProject(dir.path);
    });

    test('links every checkout, and unlink takes them away again', () async {
      final packages = checkouts();
      flutter = resolving(packages);
      expect(
        await runJust([
          'dev',
          'link',
          packages.path,
        ], context: context(project.root)),
        0,
        reason: '$err',
      );
      expect(DevLinks.linked(project), hasLength(6));
      expect(
        DevLinks.linked(project)['just_game_engine'],
        '../packages/just_game_engine',
      );
      expect(
        await runJust(['dev', 'unlink'], context: context(project.root)),
        0,
      );
      expect(DevLinks.linked(project), isEmpty);
    });

    test('links the checkouts of several folders; a package in two of them '
        'is refused, and the links stay as they were', () async {
      final packages = checkouts();
      final plugins = pluginCheckouts();
      flutter = resolving(packages);
      expect(
        await runJust([
          'dev',
          'link',
          packages.path,
          plugins.path,
        ], context: context(project.root)),
        0,
        reason: '$err',
      );
      expect(DevLinks.linked(project), hasLength(7));
      expect(
        DevLinks.linked(project)['just_world_builder_kit'],
        '../plugins/just_world_builder_kit',
      );

      pluginCheckout(plugins, 'just_game_engine');
      final before = project.readText(JustProject.overrides);
      expect(
        await runJust([
          'dev',
          'link',
          packages.path,
          plugins.path,
        ], context: context(project.root)),
        1,
      );
      expect(
        '$err',
        contains('just_game_engine is checked out in more than one folder'),
      );
      expect(project.readText(JustProject.overrides), before);
    });

    test('needs at least one folder', () async {
      expect(
        await runJust(['dev', 'link'], context: context(project.root)),
        isNot(0),
      );
      expect('$err', contains('Name the folders holding the checkouts.'));
    });

    test("each plugin's link hook gets every checkout; one that may not run "
        'is skipped with a word, and a failing one keeps the links', () async {
      final packages = checkouts();
      flutter = resolving(packages);
      expect(
        await runJust([
          'dev',
          'link',
          packages.path,
        ], context: context(project.root)),
        0,
        reason: '$err',
      );
      final hook = flutter.runs.last.arguments;
      expect(hook.take(4), [
        'run',
        'just_game_engine_cli:just_plugin',
        'game',
        'link',
      ]);
      expect(hook.skip(4), [
        for (final c in DevLinks.scan(packages)) '${c.name}=${c.path}',
      ]);

      // The game plugin from a package mirror: skipped, until allowed.
      flutter = resolving(packages, gameSource: 'https://pub.example.com');
      await flutter.run('flutter', [
        'pub',
        'get',
      ], workingDirectory: project.root);
      flutter.runs.clear();
      expect(
        await runJust([
          'dev',
          'link',
          packages.path,
        ], context: context(project.root)),
        0,
      );
      expect(flutter.runs.last.arguments, ['pub', 'get']);
      expect('$err', contains("Skipped just_game_engine_cli's `link` hook"));
      project.writeProjectFile(
        const JustProjectFile(allowedPlugins: ['just_game_engine_cli']),
      );
      flutter.runs.clear();
      expect(
        await runJust([
          'dev',
          'link',
          packages.path,
        ], context: context(project.root)),
        0,
      );
      expect(flutter.runs.last.arguments.skip(2).take(2), ['game', 'link']);

      // A hook that fails: the links are made all the same.
      flutter
        ..runs.clear()
        ..failOn = 1;
      expect(
        await runJust([
          'dev',
          'link',
          packages.path,
        ], context: context(project.root)),
        1,
      );
      expect('$err', contains('`link` hook failed'));
      expect(DevLinks.linked(project), isNotEmpty);
    });

    test('unlink asks each plugin first: a no keeps the links, a hook that '
        "can't check is a warning", () async {
      final packages = checkouts();
      File('${project.root}/pubspec_overrides.yaml').writeAsStringSync(
        DevLinks.overridesText(project, DevLinks.scan(packages)),
      );
      final before = File(
        '${project.root}/pubspec_overrides.yaml',
      ).readAsStringSync();
      flutter = resolving(packages);
      await flutter.run('flutter', [
        'pub',
        'get',
      ], workingDirectory: project.root);
      flutter
        ..runs.clear()
        ..failOn = 0;
      expect(
        await runJust(['dev', 'unlink'], context: context(project.root)),
        1,
      );
      expect('$err', contains('still needs the links'));
      final check = flutter.runs.single.arguments;
      expect(check.skip(2).take(4), ['game', 'link', '--unlink', '--check']);
      expect(check, contains(startsWith('just_game_engine=')));
      expect(
        File('${project.root}/pubspec_overrides.yaml').readAsStringSync(),
        before,
        reason: 'refused before pub get',
      );

      flutter
        ..runs.clear()
        ..failOn = 0
        ..failCode = 64;
      err.clear();
      expect(
        await runJust(['dev', 'unlink'], context: context(project.root)),
        0,
        reason: '$err',
      );
      expect('$err', contains("can't say whether the project needs the links"));
      expect(DevLinks.linked(project), isEmpty);
      expect(flutter.runs.last.arguments.skip(2), [
        'game',
        'link',
        '--unlink',
        ...flutter.runs.first.arguments.skip(6),
      ], reason: 'and told after');
    });

    test('a failing pub get leaves the overrides as they were', () async {
      final packages = checkouts();
      File('${project.root}/pubspec_overrides.yaml').writeAsStringSync(
        '# mine\r\ndependency_overrides:\r\n  foo:\r\n    path: ../foo\r\n',
      );
      final before = File(
        '${project.root}/pubspec_overrides.yaml',
      ).readAsBytesSync();
      flutter = resolving(packages)..failOn = 0;
      expect(
        await runJust([
          'dev',
          'link',
          packages.path,
        ], context: context(project.root)),
        1,
      );
      expect(
        File('${project.root}/pubspec_overrides.yaml').readAsBytesSync(),
        before,
      );
    });
  });

  group('doctor', () {
    test('finds what would break a clone', () async {
      flutter = _Flutter();
      final dir = Directory('${tmp.path}/game')..createSync();
      File('${dir.path}/pubspec.yaml').writeAsStringSync(
        'name: game\ndependencies:\n  just_game_engine: ^2.0.0\n',
      );
      // An override hides that the engine wants another physics.
      final engine = Directory('${tmp.path}/engine')..createSync();
      File('${engine.path}/pubspec.yaml').writeAsStringSync(
        'name: just_game_engine\nversion: 2.0.0\n'
        'dependencies:\n  just_physics_engine: ^1.4.0\n',
      );
      final physics = Directory('${tmp.path}/physics')..createSync();
      File(
        '${physics.path}/pubspec.yaml',
      ).writeAsStringSync('name: just_physics_engine\nversion: 1.3.0\n');
      File('${dir.path}/.dart_tool/package_config.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {
                'name': 'just_game_engine',
                'rootUri': engine.absolute.uri.toString(),
              },
              {
                'name': 'just_physics_engine',
                'rootUri': physics.absolute.uri.toString(),
              },
            ],
          }),
        );
      final code = await runJust([
        'doctor',
        '--json',
      ], context: context(dir.path));
      expect(code, 1);
      final findings =
          ((jsonDecode('$out') as Map)['result'] as Map)['findings'] as List;
      String all(String severity) => [
        for (final f in findings)
          if ((f as Map)['severity'] == severity) f['message'],
      ].join('\n');
      expect(
        all('problem'),
        contains('just_game_engine asks for just_physics_engine ^1.4.0'),
      );
      expect(all('warning'), contains('pubspec_overrides.yaml'));
      expect(all('warning'), contains('does not pin just_core_cli'));
    });

    test(
      "runs the ecosystem's plugins' doctor hooks, passing on --json",
      () async {
        final packages = checkouts();
        flutter = resolving(packages);
        final dir = Directory('${tmp.path}/game')..createSync();
        File('${dir.path}/pubspec.yaml').writeAsStringSync('name: game\n');
        File(
          '${dir.path}/.gitignore',
        ).writeAsStringSync('pubspec_overrides.yaml\n');
        await flutter.run('flutter', [
          'pub',
          'get',
        ], workingDirectory: dir.path);
        flutter.runs.clear();
        await runJust(['doctor', '--json'], context: context(dir.path));
        expect(flutter.runs.single.arguments, [
          'run',
          'just_game_engine_cli:just_plugin',
          'game',
          'doctor',
          '--json',
        ]);
        expect(flutter.runs.single.captured, isTrue);
        final result = (jsonDecode('$out') as Map)['result'] as Map;
        expect(
          (result['findings'] as List).map((f) => (f as Map)['message']),
          contains('just_game_engine_cli: `game doctor` passed.'),
        );
        expect((result['just_game_engine_cli'] as Map)['result'], {
          'ran': 'game doctor',
        }, reason: "the plugin's own document, findings and all");

        flutter
          ..runs.clear()
          ..failOn = 0;
        out.clear();
        expect(await runJust(['doctor'], context: context(dir.path)), 1);
        expect('$out', isNot(contains('No problems found')));
      },
    );

    test('a broken just.json is a finding, not the end of the check', () async {
      flutter = _Flutter();
      final dir = Directory('${tmp.path}/game')..createSync();
      File('${dir.path}/pubspec.yaml').writeAsStringSync('name: game\n');
      File('${dir.path}/just.json').writeAsStringSync('{"schema": "x"');
      expect(
        await runJust(['doctor', '--json'], context: context(dir.path)),
        1,
      );
      final findings =
          ((jsonDecode('$out') as Map)['result'] as Map)['findings'] as List;
      expect(
        findings.map((f) => (f as Map)['message']),
        contains(contains('just.json')),
      );
      expect('$err', contains("plugins' checks were skipped"));
    });

    test('a --project that names no project fails the check', () async {
      flutter = _Flutter();
      expect(
        await runJust([
          'doctor',
          '--project',
          'gmae',
          '--json',
        ], context: context(tmp.path)),
        1,
      );
      final findings =
          ((jsonDecode('$out') as Map)['result'] as Map)['findings'] as List;
      expect(
        findings.where((f) => (f as Map)['severity'] == 'problem').single,
        containsPair('message', contains('No pubspec.yaml in gmae')),
      );
      // Run in no project at all, it only warns.
      out.clear();
      expect(await runJust(['doctor'], context: context(tmp.path)), 0);
      expect('$out$err', contains('Not in a project'));
    });

    test("a release's just, with its ju beside it, is this tool", () async {
      flutter = _Flutter();
      final ext = Platform.isWindows ? '.exe' : '';
      final bin = Directory('${tmp.path}/bin')..createSync();
      // Bigger than a launcher script: a compiled program.
      File('${bin.path}/just$ext').writeAsBytesSync(List.filled(70 * 1024, 1));
      File('${bin.path}/ju$ext').writeAsBytesSync(List.filled(70 * 1024, 1));
      final ctx = JustContext(
        workingDirectory: tmp.path,
        out: out,
        err: err,
        interactive: false,
        environment: {'PATH': bin.path, 'PUB_CACHE': '${tmp.path}/none'},
        launcher: flutter,
      );
      await runJust(['doctor'], context: ctx);
      expect('$out', contains('`just` on the PATH is this tool'));

      // Without its ju, a big `just` is someone else's.
      File('${bin.path}/ju$ext').deleteSync();
      out.clear();
      await runJust(['doctor'], context: ctx);
      expect('$out', contains('`just` on the PATH is another program'));
    });
  });
}

// `just upgrade`: the tools moved, each plugin's packages moved by its
// `upgrade` hook, all or nothing — and the plugins' migrations asked first,
// so one that can't run stops it before anything changes.

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:just_core_cli/just_core_cli.dart';
import 'package:just_core_cli/project.dart';
import 'package:test/test.dart';

/// Plays pub and the plugins: records each run, and answers a plugin's
/// `--json` run with a document.
final class _Pub implements Launcher {
  _Pub(this.project);

  final JustProject project;
  final List<List<String>> runs = [];

  /// The exit code for each run; 0 when null.
  int Function(List<String> arguments)? exitCodeFor;

  /// What a migration rewrote, in its `--json` document.
  List<String> migrated = const [];

  /// What a plugin's `upgrade` moves: name → (from, to). The real run
  /// rewrites the pubspec line, as `just game upgrade` does.
  Map<String, (String, String)> upgrades = const {};

  @override
  Future<int> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String> environment = const {},
    bool toStderr = false,
    StringSink? stdout,
  }) async {
    runs.add(arguments);
    final code = exitCodeFor?.call(arguments) ?? 0;
    final upgrade = arguments.contains('upgrade');
    final check = arguments.contains('--check');
    if (upgrade && !check && code == 0) {
      var text = project.readText('pubspec.yaml')!;
      upgrades.forEach((name, bump) {
        text = PubspecConstraints.set(text, 'dependencies', name, bump.$2);
      });
      project.file('pubspec.yaml').writeAsStringSync(text);
    }
    stdout?.write(
      'Building package executable...\n'
      '${jsonEncode({
        'ok': code == 0,
        'result': upgrade
            ? {
                'packages': {
                  for (final e in upgrades.entries) e.key: {'from': e.value.$1, 'to': e.value.$2},
                },
              }
            : check
            ? {'check': true}
            : {'migrated': migrated},
      })}\n',
    );
    return code;
  }
}

void main() {
  late Directory tmp;
  late JustProject project;
  late _Pub pub;
  late StringBuffer out, err;

  Future<int> just(List<String> args, {String? answer}) => runJust(
    args,
    context: JustContext(
      workingDirectory: project.root,
      out: out,
      err: err,
      interactive: answer != null,
      readLine: () => answer,
      environment: {
        'PUB_CACHE': '${tmp.path}/none',
        'JUST_CORE_CLI_CONFIG_DIR': '${tmp.path}/config',
      },
      launcher: pub,
    ),
  );

  String? read(String path) => project.readText(path);

  /// Plugins resolved in the project, by name, from [sources] (`path`: a
  /// local checkout; else a package server's URL). Each has a `migrate`
  /// hook, and an `upgrade` hook when [upgrade].
  void plugins(Map<String, String> sources, {bool upgrade = false}) {
    final dirs = <String, Directory>{};
    for (final name in sources.keys) {
      final dir = Directory('${tmp.path}/pkgs/$name')
        ..createSync(recursive: true);
      File('${dir.path}/pubspec.yaml').writeAsStringSync('name: $name\n');
      final command = name.replaceAll('_', '-');
      File('${dir.path}/just_plugin.json').writeAsStringSync(
        jsonEncode({
          'commands': [
            {'name': command},
          ],
          'hooks': {
            'migrate': '$command migrate',
            if (upgrade) 'upgrade': '$command upgrade',
          },
        }),
      );
      dirs[name] = dir;
    }
    project.file('.dart_tool/package_config.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            for (final e in dirs.entries)
              {'name': e.key, 'rootUri': e.value.absolute.uri.toString()},
          ],
        }),
      );
    final lock = StringBuffer('packages:\n');
    sources.forEach((name, source) {
      lock.writeln('  $name:\n    dependency: "direct dev"\n    description:');
      if (source == 'path') {
        final path = normalPath(
          dirs[name]!.absolute.path,
        ).replaceAll(r'\', r'\\');
        lock.writeln(
          '      path: "$path"\n      relative: false\n    source: path',
        );
      } else {
        lock.writeln(
          '      name: $name\n      url: "$source"\n    source: hosted',
        );
      }
      lock.writeln('    version: "1.0.0"');
    });
    project.file('pubspec.lock').writeAsStringSync('$lock');
  }

  /// What ran, each as `<hook words…>` or `pub get`.
  List<String> ran() => [
    for (final r in pub.runs)
      r.first == 'run' ? r.skip(3).join(' ') : r.join(' '),
  ];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('just_upgrade_');
    project = JustProject(tmp.path);
    File('${tmp.path}/pubspec.yaml').writeAsStringSync(
      'name: game\r\n'
      'dependencies:\r\n'
      '  just_game_engine: ^1.6.0 # the engine\r\n'
      'dev_dependencies:\r\n'
      '  just_core_cli: ^0.0.9\r\n'
      '  just_game_engine_editor:\r\n'
      '    path: ../editor\r\n',
    );
    pub = _Pub(project);
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('moves the tools — only the tools — and records the set', () async {
    project
        .file('just.json')
        .writeAsStringSync('{"title": "Game", "game": {"keep": true}}');
    expect(await just(['upgrade', '--yes']), 0, reason: '$err');
    final pubspec = read('pubspec.yaml')!;
    expect(pubspec, contains('  just_core_cli: ^0.1.0\r\n'));
    expect(
      pubspec,
      contains('  just_game_engine: ^1.6.0 # the engine\r\n'),
      reason: "the engine's version is its plugin's to move",
    );
    expect(
      pubspec,
      contains('    path: ../editor\r\n'),
      reason: 'blocks untouched',
    );
    expect(pub.runs.single, ['pub', 'get']);
    final file = project.readProjectFile();
    expect(file.set, ToolSet.current.id);
    expect(file.title, 'Game');
    expect(file.extra, {
      'game': {'keep': true},
    }, reason: "what just doesn't know stays");
    // Again: nothing left to do.
    pub.runs.clear();
    expect(await just(['upgrade', '--yes']), 0);
    expect('$out', contains('up to date'));
    expect(pub.runs, isEmpty);
  });

  test("the tools move, then each plugin's packages, fetched twice, all in "
      'one transaction', () async {
    plugins({'just_game_engine_cli': 'path'}, upgrade: true);
    pub.upgrades = {'just_game_engine': ('^1.6.0', '^2.0.0')};
    expect(await just(['upgrade', '--yes', '--json']), 0, reason: '$err');
    expect(ran(), [
      'migrate --check --json',
      'pub get',
      'upgrade --yes --json',
      'pub get',
      'migrate --check --json',
      'migrate --yes --json',
    ]);
    final pubspec = read('pubspec.yaml')!;
    expect(pubspec, contains('  just_core_cli: ^0.1.0\r\n'));
    expect(pubspec, contains('  just_game_engine: ^2.0.0 # the engine\r\n'));
    final result = (jsonDecode('$out') as Map)['result'] as Map;
    expect(result['changed'], isTrue);
    final plugin = result['just_game_engine_cli'] as Map;
    expect((plugin['upgrade'] as Map)['result'], {
      'packages': {
        'just_game_engine': {'from': '^1.6.0', 'to': '^2.0.0'},
      },
    });
    expect((plugin['migrate'] as Map)['ok'], isTrue);
  });

  test("when the tools stay, a plugin's bumps are asked first; none and "
      'nothing to do is up to date', () async {
    plugins({'just_game_engine_cli': 'path'}, upgrade: true);
    project
        .file('pubspec.yaml')
        .writeAsStringSync(
          'name: game\ndependencies:\n  just_game_engine: ^1.6.0\n',
        );
    project.writeProjectFile(JustProjectFile(set: ToolSet.current.id));
    expect(await just(['upgrade']), 0, reason: '$err');
    expect(ran(), [
      'upgrade --check --json',
      'migrate',
    ], reason: 'no --yes: the migration asks before it rewrites anything');
    expect('$out', contains('up to date'));

    // The plugin would move a package: the upgrade happens.
    pub
      ..runs.clear()
      ..upgrades = {'just_game_engine': ('^1.6.0', '^2.0.0')};
    out.clear();
    expect(await just(['upgrade', '--yes']), 0, reason: '$err');
    expect(ran(), [
      'upgrade --check --json',
      'migrate --check',
      'upgrade --yes --json',
      'pub get',
      'migrate --check',
      'migrate --yes',
    ]);
    expect('$out', contains('~ just_game_engine  ^1.6.0 -> ^2.0.0'));
    expect(read('pubspec.yaml'), contains('just_game_engine: ^2.0.0'));
  });

  test("a plugin's upgrade that fails rolls the whole upgrade back", () async {
    plugins({'just_game_engine_cli': 'path'}, upgrade: true);
    pub.upgrades = {'just_game_engine': ('^1.6.0', '^2.0.0')};
    final before = File('${tmp.path}/pubspec.yaml').readAsBytesSync();
    pub.exitCodeFor = (args) =>
        args.contains('upgrade') && !args.contains('--check') ? 1 : 0;
    expect(await just(['upgrade', '--yes']), 1);
    expect('$err', contains("just_game_engine_cli's upgrade failed"));
    expect(File('${tmp.path}/pubspec.yaml').readAsBytesSync(), before);
    expect(read('just.json'), isNull);
    expect(ran().where((r) => r == 'migrate --yes'), isEmpty);
  });

  test("an upgrade --check that can't check is a warning, and the upgrade "
      'runs', () async {
    plugins({'just_game_engine_cli': 'path'}, upgrade: true);
    project
        .file('pubspec.yaml')
        .writeAsStringSync(
          'name: game\ndependencies:\n  just_game_engine: ^1.6.0\n',
        );
    project.writeProjectFile(JustProjectFile(set: ToolSet.current.id));
    for (final code in PluginManifest.cannotCheck) {
      pub
        ..runs.clear()
        ..exitCodeFor = (args) =>
            args.contains('upgrade') && args.contains('--check') ? code : 0;
      err.clear();
      expect(await just(['upgrade', '--yes']), 0, reason: '$err');
      expect('$err', contains("can't say beforehand what it would move"));
      expect(ran(), contains('upgrade --yes --json'));
    }
  });

  test("trusted plugins' migrations are asked first, then run; --yes skips "
      'the rest', () async {
    plugins({'just_platformer_kit': 'path', 'studio_kit': 'https://pub.dev'});
    expect(await just(['upgrade', '--yes']), 0, reason: '$err');
    expect(ran(), [
      'migrate --check',
      'pub get',
      'migrate --check',
      'migrate --yes',
    ], reason: 'asked before anything changes, and with the new packages');
    expect('$err', contains("Skipped studio_kit's `migrate` hook"));
    expect('$err', contains('just.json'));

    // Up to date: nothing is fetched, so nothing to ask first; the
    // migrations still run.
    pub
      ..runs.clear()
      ..migrated = ['assets/scenes/old.scene.json'];
    out.clear();
    expect(await just(['upgrade', '--yes', '--json']), 0);
    expect(ran(), ['migrate --yes --json']);
    final result = (jsonDecode('$out') as Map)['result'] as Map;
    expect(result['changed'], isTrue, reason: 'files were rewritten');
    expect((result['just_platformer_kit'] as Map)['migrate'], {
      'hook': 'just-platformer-kit migrate',
      'ok': true,
      'exitCode': 0,
      'result': {
        'migrated': ['assets/scenes/old.scene.json'],
      },
    });
  });

  test('a migration that says it could not run stops the upgrade before '
      'anything changes', () async {
    plugins({'just_platformer_kit': 'path'});
    final before = File('${tmp.path}/pubspec.yaml').readAsBytesSync();
    pub.exitCodeFor = (args) => args.contains('--check') ? 1 : 0;
    expect(await just(['upgrade', '--yes']), 1);
    expect('$err', contains("just_platformer_kit's migration could not run"));
    expect('$err', contains('just-platformer-kit migrate --check'));
    expect(pub.runs, hasLength(1), reason: 'no pub get, no migration');
    expect(File('${tmp.path}/pubspec.yaml').readAsBytesSync(), before);
    expect(read('just.json'), isNull);
  });

  test(
    'a migration the new packages say no to rolls the upgrade back',
    () async {
      plugins({'just_platformer_kit': 'path'});
      final before = File('${tmp.path}/pubspec.yaml').readAsBytesSync();
      var checks = 0;
      pub.exitCodeFor = (args) =>
          args.contains('--check') && ++checks == 2 ? 1 : 0;
      expect(await just(['upgrade', '--yes']), 1);
      expect('$err', contains('with the new packages'));
      expect(pub.runs.where((r) => r.contains('pub')), hasLength(1));
      expect(pub.runs.where((r) => r.contains('--yes')), isEmpty);
      expect(File('${tmp.path}/pubspec.yaml').readAsBytesSync(), before);
      expect(read('just.json'), isNull);
    },
  );

  test("a migration that can't check is a warning, not a stop", () async {
    plugins({'just_platformer_kit': 'path'});
    for (final code in PluginManifest.cannotCheck) {
      pub
        ..runs.clear()
        ..exitCodeFor = (args) => args.contains('--check') ? code : 0;
      project
          .file('pubspec.yaml')
          .writeAsStringSync(
            'name: game\ndev_dependencies:\n  just_core_cli: ^0.0.1\n',
          );
      err.clear();
      expect(await just(['upgrade', '--yes']), 0, reason: '$err');
      expect('$err', contains("can't say beforehand"));
      expect(pub.runs.last, contains('--yes'), reason: 'it still runs');
    }
  });

  test('what comes after -- goes to every migration, the checks too', () async {
    plugins({'just_platformer_kit': 'path'});
    expect(
      await just(['upgrade', '--yes', '--', '--engine-only']),
      0,
      reason: '$err',
    );
    final hooks = pub.runs.where((r) => r.first == 'run').toList();
    expect(hooks, hasLength(3));
    for (final r in hooks) {
      expect(r.last, '--engine-only');
    }
  });

  test('a migration that fails afterwards fails the upgrade, and says how '
      'to run it again', () async {
    plugins({'just_platformer_kit': 'path'});
    pub.exitCodeFor = (args) => args.contains('--yes') ? 3 : 0;
    expect(await just(['upgrade', '--yes']), 1);
    expect(project.readProjectFile().set, ToolSet.current.id);
    expect('$err', contains('`just just-platformer-kit migrate`'));
  });

  test(
    "a --yes after -- is the migrations', not a yes to the upgrade",
    () async {
      expect(await just(['upgrade', '--', '--yes']), 1);
      expect('$err', contains('needs a yes'));
      expect(pub.runs, isEmpty);
      expect(read('just.json'), isNull);
    },
  );

  test('a declined upgrade says so, in the JSON document too', () async {
    expect(await just(['upgrade', '--json'], answer: 'n'), 1);
    final doc = jsonDecode('$out') as Map;
    expect(doc['error'], contains('declined'));
    expect(pub.runs, isEmpty);
  });

  test('a plugin allowed during the upgrade stays allowed', () async {
    plugins({'studio_kit': 'https://pub.dev'});
    expect(await just(['upgrade'], answer: 'y'), 0, reason: '$err');
    final file = project.readProjectFile();
    expect(file.set, ToolSet.current.id);
    expect(file.allowedPlugins, ['studio_kit']);
  });

  test('a failing pub get changes nothing', () async {
    final before = File('${tmp.path}/pubspec.yaml').readAsBytesSync();
    pub.exitCodeFor = (_) => 1;
    expect(await just(['upgrade', '--yes']), 1);
    expect(File('${tmp.path}/pubspec.yaml').readAsBytesSync(), before);
    expect(read('just.json'), isNull);
  });

  test('PubspecConstraints edits one line and nothing else', () {
    const text =
        'name: x\n'
        'dependencies:\n'
        '  just_any_kit: any\n'
        '  quoted: "^1.0.0"\n'
        'dev_dependencies:\n'
        '  just_any_kit: ^9.0.0\n';
    expect(PubspecConstraints.of(text, 'dependencies', 'just_any_kit'), 'any');
    final next = PubspecConstraints.set(
      text,
      'dependencies',
      'just_any_kit',
      '^1.2.0',
    );
    expect(next, contains('  just_any_kit: ^1.2.0\n'));
    expect(next, contains('dev_dependencies:\n  just_any_kit: ^9.0.0'));
    expect(
      PubspecConstraints.set(text, 'dependencies', 'quoted', '^2.0.0'),
      contains('  quoted: "^2.0.0"\n'),
    );
    expect(PubspecConstraints.set(text, 'dependencies', 'absent', '1'), text);
  });

  test('PubspecConstraints.add knows an entry from a key nested in one', () {
    const text =
        'name: x\n'
        'dependencies:\n'
        '  thing:\n'
        '    git:\n'
        '      url: https://example.com/thing\n'
        '      path: packages/thing\n';
    for (final name in ['path', 'git', 'url']) {
      expect(
        PubspecConstraints.add(text, 'dependencies', name, '^1.0.0'),
        '$text  $name: ^1.0.0\n',
        reason: name,
      );
    }
  });

  test('PubspecConstraints.add writes a line a person would', () {
    const crlf =
        'name: x\r\n'
        'dev_dependencies:\r\n'
        '  flutter_test:\r\n'
        '    sdk: flutter\r\n'
        '\r\n'
        'flutter:\r\n'
        '  uses-material-design: true\r\n';
    final added = PubspecConstraints.add(
      crlf,
      'dev_dependencies',
      'just_core_cli',
      '^0.1.0',
    );
    expect(
      added,
      contains('    sdk: flutter\r\n  just_core_cli: ^0.1.0\r\n\r\nflutter:'),
    );
    expect(
      PubspecConstraints.add(
        added,
        'dev_dependencies',
        'just_core_cli',
        '^0.2.0',
      ),
      contains('  just_core_cli: ^0.2.0\r\n'),
      reason: 'there already: moved',
    );
    expect(
      PubspecConstraints.add(
        'name: x',
        'dev_dependencies',
        'a',
        '>=1.0.0 <2.0.0',
      ),
      "name: x\n\ndev_dependencies:\n  a: '>=1.0.0 <2.0.0'\n",
    );
    const block = 'name: x\ndev_dependencies:\n  a:\n    path: ../a\n';
    expect(
      PubspecConstraints.add(block, 'dev_dependencies', 'a', '^1.0.0'),
      block,
    );
  });
}

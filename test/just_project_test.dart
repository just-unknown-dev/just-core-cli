// Finding a project, paths in it, and the two tools' pubspec blocks side by
// side.

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:just_core_cli/just_core_cli.dart';
import 'package:just_core_cli/project.dart';
import 'package:test/test.dart';

/// A tool's block, as a package store would keep one.
const _store = ManagedBlock('pkg_store', hint: 'edit in the store');

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('just_project_'));
  tearDown(() => root.deleteSync(recursive: true));

  group('JustProject', () {
    test('is found from any folder inside it', () {
      File('${root.path}/pubspec.yaml').writeAsStringSync('name: game\n');
      final deep = Directory('${root.path}/lib/game/boot')
        ..createSync(recursive: true);
      final found = JustProject.find(deep.path);
      expect(found, isNotNull);
      expect(found!.root, normalPath(root.absolute.path));
    });

    test('paths in it use / and know what is outside', () {
      final project = JustProject(root.path);
      expect(project.path(r'assets\scenes'), '${project.root}/assets/scenes');
      expect(
        project.relativeOf('${project.root}/lib/main.dart'),
        'lib/main.dart',
      );
      expect(project.relativeOf(Directory.systemTemp.parent.path), isNull);
      expect(project.relativeOf(project.root), '');
    });
  });

  test('FileHashes reads CRLF as LF only in text files', () {
    final lf = utf8.encode('a\nb\n');
    final crlf = utf8.encode('a\r\nb\r\n');
    expect(FileHashes.of('x.json', crlf), FileHashes.of('x.json', lf));
    expect(FileHashes.of('x.png', crlf), isNot(FileHashes.of('x.png', lf)));
  });

  test("the store's block and just dev link's live side by side", () {
    const text =
        'name: game\r\n'
        'dependency_overrides:\r\n'
        '  # >>> pkg_store managed (edit in the store) >>>\r\n'
        '  just_art:\r\n'
        '    path: packages/art/just_art\r\n'
        '  # <<< pkg_store managed <<<\r\n';
    final links = PubspecEditor.parse(text, marker: ManagedBlock.devLinks)
      ..setManaged('dependency_overrides', {
        'just_game_engine': const PathDependency('../engine'),
      });
    expect(
      links.text,
      contains('# >>> just_core_cli managed (just dev link) >>>'),
    );
    expect(links.text, contains('just_art:\r\n'));
    expect(links.text.contains(RegExp('[^\r]\n')), isFalse);
    // The store still sees its own block, and only its own.
    final store = PubspecEditor.parse(links.text, marker: _store);
    expect(store.managed('dependency_overrides').keys, ['just_art']);
  });

  group('JustProjectFile', () {
    test('keeps what it does not know when it writes the file', () {
      const text =
          '{"schema": 1, "title": "Game", "set": "2026.10",\n'
          ' "entry": {"game": "lib/play.dart", "tool": "bin/x.dart"},\n'
          ' "plugins": {"allowed": ["b"], "pinned": {"b": "1.0.0"}},\n'
          ' "game": {"lastScene": "cave"}, "future": [1, 2]}';
      final file = JustProjectFile.parse(text);
      expect(file.entries, {'game': 'lib/play.dart', 'tool': 'bin/x.dart'});
      expect(file.extra.keys, ['game', 'future']);
      final again = JustProjectFile.parse(
        file.allowing('a').copyWith(set: '2027.01').toText(),
      );
      expect(again.set, '2027.01');
      expect(again.allowedPlugins, ['a', 'b']);
      expect(again.entries, file.entries);
      expect(again.extra, {
        'game': {'lastScene': 'cave'},
        'future': [1, 2],
      });
      expect(jsonDecode(again.toText())['plugins'], {
        'allowed': ['a', 'b'],
        'pinned': {'b': '1.0.0'},
      }, reason: "a plugin's own keys in plugins stay too");
    });

    test('an empty one writes only its schema, and a newer one is refused', () {
      expect(const JustProjectFile().toText(), '{\n  "schema": 1\n}\n');
      expect(
        () => JustProjectFile.parse('{"schema": 9}'),
        throwsA(isA<JsonFormatException>()),
      );
    });

    test('an entry that is not a path is kept as it was, never refused', () {
      final odd = JustProjectFile.parse(
        '{"entry": {"game": "lib/play.dart", "web": {"main": "web.dart"}, '
        '"count": 2}}',
      );
      expect(odd.entries, {'game': 'lib/play.dart'});
      expect(jsonDecode(odd.copyWith(set: 'x').toText())['entry'], {
        'game': 'lib/play.dart',
        'web': {'main': 'web.dart'},
        'count': 2,
      });
      final raw = JustProjectFile.parse('{"entry": "lib/main.dart"}');
      expect(raw.entries, isEmpty);
      expect(jsonDecode(raw.toText())['entry'], 'lib/main.dart');
      expect(
        jsonDecode(
          raw.copyWith(entries: {'game': 'lib/a.dart'}).toText(),
        )['entry'],
        {'game': 'lib/a.dart'},
      );
    });
  });

  test("unknown keys are kept as they were, empty or null too", () {
    const text =
        '{"title": "x", "mine": null, "list": [], "map": {}, '
        '"plugins": {"allowed": [], "theirs": null, "more": {}}}';
    final again = jsonDecode(JustProjectFile.parse(text).toText()) as Map;
    expect(again, {
      'schema': 1,
      'title': 'x',
      'mine': null,
      'list': <Object>[],
      'map': <String, Object>{},
      'plugins': {'theirs': null, 'more': <String, Object>{}},
    });
  });

  test('a version in single quotes is read', () {
    final dir = Directory('${root.path}/pkg')..createSync();
    File(
      '${dir.path}/pubspec.yaml',
    ).writeAsStringSync("name: p\nversion: '1.2.3'\n");
    expect(
      '${ResolvedPackage('p', dir.path, '${dir.path}/lib').version}',
      '1.2.3',
    );
  });

  test("a package's own build/ is a tool's; a build folder deeper is not", () {
    expect(FileHashes.isToolPath('build/app.so'), isTrue);
    expect(FileHashes.isToolPath('assets/build/tiles.png'), isFalse);
    expect(FileHashes.isToolPath('lib/.dart_tool/x'), isTrue);
  });

  test("the version constant is the pubspec's", () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(pubspec)!.group(1);
    expect(justCoreCliVersion, version);
  });
}

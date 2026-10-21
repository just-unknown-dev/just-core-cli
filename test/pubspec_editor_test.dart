// The pubspec editor: the store's blocks change, every other byte stays,
// and anything it can't edit safely is refused.
@TestOn('vm')
library;

import 'dart:io';

import 'package:just_core_cli/project.dart';
import 'package:test/test.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

const knight = PathDependency('packages/characters/just_art_knight');
const sprites = PathDependency('packages/editors/just_sprite_editor');

/// A tool's block, as a package store would keep one.
const _store = ManagedBlock('pkg_store', hint: 'edit in the store');

void main() {
  // A copy of the template's own files: pubspec.yaml has CRLF endings and
  // long comments; pubspec_overrides.yaml has LF and a melos header.
  final pubspec = fixture('template_pubspec.yaml');
  final overrides = fixture('template_overrides.yaml');

  group('reading', () {
    test('unchanged text round-trips byte for byte', () {
      for (final text in [
        pubspec,
        overrides,
        '',
        'name: x',
        'name: x\n\n\n',
        '\uFEFFname: x\r\ndependencies:\r\n  a: ^1.0.0\r\n',
        'name: x\r\nmixed: 1\nendings: 2\r\n',
      ]) {
        expect(PubspecEditor.parse(text, marker: _store).text, text);
      }
    });

    test('keeps the file\'s line ending', () {
      expect(PubspecEditor.parse(pubspec, marker: _store).lineEnding, '\r\n');
      expect(PubspecEditor.parse(overrides, marker: _store).lineEnding, '\n');
    });

    test('lists the entries of a section', () {
      final deps = PubspecEditor.parse(
        pubspec,
        marker: _store,
      ).unmanaged('dependencies');
      expect(deps['just_game_engine'], const HostedDependency('^2.0.0'));
      expect(deps['cupertino_icons'], const HostedDependency('^1.0.8'));
      expect(deps['flutter'], isA<OtherDependency>(), reason: 'sdk: flutter');
      expect(deps.keys, contains('just_input_editor'));
      final dev = PubspecEditor.parse(
        pubspec,
        marker: _store,
      ).unmanaged('dev_dependencies');
      expect(dev.keys.toSet(), {'flutter_test', 'flutter_lints'});
    });

    test('reads path overrides and the melos header', () {
      final editor = PubspecEditor.parse(overrides, marker: _store);
      final o = editor.unmanaged('dependency_overrides');
      expect(
        o['just_sprite_editor'],
        const PathDependency('packages/just_sprite_editor'),
      );
      expect(editor.melosManaged, {
        'dart_mappable_builder',
        'digit_data_model',
      });
    });

    test('flow paths, quoted constraints, hosted urls and comments', () {
      final deps = PubspecEditor.parse(
        'dependencies:\n'
        '  a: {path: ../a}\n'
        "  b: '>=1.0.0 <2.0.0' # why\n"
        '  c:\n'
        '    hosted: https://pub.example.com\n'
        '    version: ^1.0.0\n'
        '  d:\n'
        '    git: https://example.com/d.git\n',
        marker: _store,
      ).unmanaged('dependencies');
      expect(deps['a'], const PathDependency('../a'));
      expect(deps['b'], const HostedDependency('>=1.0.0 <2.0.0'));
      expect(
        deps['c'],
        const HostedDependency('^1.0.0', url: 'https://pub.example.com'),
      );
      expect(deps['d'], isA<OtherDependency>());
    });

    test('a long line costs its length, not its square', () {
      final watch = Stopwatch()..start();
      final deps = PubspecEditor.parse(
        'dependencies:\n'
        '  a: {path: a${' ' * 40000}b\n'
        '  b: { path : ../b }\n',
        marker: _store,
      ).unmanaged('dependencies');
      expect(deps['a'], isA<OtherDependency>());
      expect(deps['b'], const PathDependency('../b'));
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    });
  });

  group('writing a block', () {
    test('into a new section, at the end, with the file\'s CRLF', () {
      final editor = PubspecEditor.parse(pubspec, marker: _store)
        ..setManaged('dependency_overrides', {'just_art_knight': knight});
      final text = editor.text;
      expect(
        text.startsWith(pubspec),
        isTrue,
        reason: 'nothing before changes',
      );
      expect(
        text.substring(pubspec.length),
        '\r\ndependency_overrides:\r\n'
        '  ${_store.start}\r\n'
        '  just_art_knight:\r\n'
        '    path: packages/characters/just_art_knight\r\n'
        '  ${_store.end}\r\n',
      );
      expect(
        PubspecEditor.parse(
          text,
          marker: _store,
        ).managed('dependency_overrides'),
        {'just_art_knight': knight},
      );
    });

    test('into an existing section, after its last entry', () {
      final editor = PubspecEditor.parse(pubspec, marker: _store)
        ..setManaged('dev_dependencies', {'just_sprite_editor': sprites});
      final lines = editor.text.split('\r\n');
      final lints = lines.indexOf('  flutter_lints: ^6.0.0');
      expect(lines[lints + 1], '  ${_store.start}');
      expect(lines[lints + 4], '  ${_store.end}');
      expect(
        lines[lints + 5],
        '',
        reason: 'the blank line before the comments',
      );
      expect(lines[lints + 6], startsWith('# For information'));
    });

    test('replaces the block, sorted by name', () {
      final editor = PubspecEditor.parse(pubspec, marker: _store)
        ..setManaged('dev_dependencies', {'just_sprite_editor': sprites})
        ..setManaged('dev_dependencies', {
          'zeta': const HostedDependency('^1.0.0'),
          'just_sprite_editor': sprites,
          'alpha': const HostedDependency('>=1.0.0 <2.0.0'),
        });
      final again = PubspecEditor.parse(editor.text, marker: _store);
      expect(again.managed('dev_dependencies').keys.toList(), [
        'alpha',
        'just_sprite_editor',
        'zeta',
      ]);
      expect(editor.text, contains("  alpha: '>=1.0.0 <2.0.0'\r\n"));
      expect(again.unmanaged('dev_dependencies').keys.toSet(), {
        'flutter_test',
        'flutter_lints',
      });
    });

    test('adding then removing gives back the original bytes', () {
      for (final section in [
        'dependency_overrides',
        'dev_dependencies',
        'dependencies',
      ]) {
        final editor = PubspecEditor.parse(pubspec, marker: _store)
          ..setManaged(section, {'just_art_knight': knight})
          ..setManaged(section, const {});
        expect(editor.text, pubspec, reason: section);
      }
      final o = PubspecEditor.parse(overrides, marker: _store)
        ..setManaged('dependency_overrides', {'just_art_knight': knight})
        ..setManaged('dependency_overrides', const {});
      expect(o.text, overrides);
    });

    test('an empty section the store made is removed with its block', () {
      final editor = PubspecEditor.parse('name: x\n', marker: _store)
        ..setManaged('dependency_overrides', {'a': knight});
      expect(editor.text, contains('dependency_overrides:'));
      editor.setManaged('dependency_overrides', const {});
      expect(editor.text, 'name: x\n');
    });

    test('keeps a byte order mark and a missing final newline', () {
      final editor = PubspecEditor.parse('\uFEFFname: x', marker: _store)
        ..setManaged('dependencies', {'a': knight});
      expect(editor.text, startsWith('\uFEFFname: x\n\ndependencies:\n'));
      expect(editor.text.endsWith('\n'), isFalse);
    });
  });

  group('lines the store does not own', () {
    test('an identical entry outside the block is adopted', () {
      final editor = PubspecEditor.parse(overrides, marker: _store)
        ..setManaged('dependency_overrides', {
          'just_sprite_editor': const PathDependency(
            'packages/just_sprite_editor/',
          ),
        });
      final again = PubspecEditor.parse(editor.text, marker: _store);
      expect(again.managed('dependency_overrides').keys, [
        'just_sprite_editor',
      ]);
      expect(
        again.unmanaged('dependency_overrides').keys,
        isNot(contains('just_sprite_editor')),
      );
      expect(
        again.unmanaged('dependency_overrides').keys,
        contains('just_ui_editor'),
      );
    });

    test('a different entry outside the block is a clash; nothing changes', () {
      final editor = PubspecEditor.parse(overrides, marker: _store);
      expect(
        () => editor.setManaged('dependency_overrides', {
          'just_sprite_editor': sprites,
        }),
        throwsA(
          isA<PubspecEditException>().having((e) => e.names, 'names', [
            'just_sprite_editor',
          ]),
        ),
      );
      expect(editor.text, overrides);
    });

    test('melos-managed names are never written', () {
      expect(
        () => PubspecEditor.parse(
          overrides,
          marker: _store,
        ).setManaged('dependency_overrides', {'digit_data_model': knight}),
        throwsA(isA<PubspecEditException>()),
      );
    });
  });

  group('refused files', () {
    for (final e in {
      'inline section': 'dependencies: {a: ^1.0.0}\n',
      'tabs': 'dependencies:\n\ta: ^1.0.0\n',
      'anchors': 'dependencies:\n  a: &x ^1.0.0\n  b: *x\n',
      'merge keys': 'dependencies:\n  <<: *base\n',
      'a block with no end': 'dependencies:\n  ${_store.start}\n  a: ^1.0.0\n',
      'a block with no start': 'dependencies:\n  a: ^1.0.0\n  ${_store.end}\n',
    }.entries) {
      test(e.key, () {
        expect(
          () => PubspecEditor.parse(
            e.value,
            marker: _store,
          ).setManaged('dependencies', {'z': knight}),
          throwsA(isA<PubspecEditException>()),
        );
      });
    }
  });

  group('blocks', () {
    const dup =
        'dependency_overrides:\n'
        '  # >>> pkg_store managed (edit in the store) >>>\n'
        '  a:\n'
        '    path: packages/a\n'
        '  # <<< pkg_store managed <<<\n'
        '  # >>> pkg_store managed (edit in the store) >>>\n'
        '  b:\n'
        '    path: packages/b\n'
        '  # <<< pkg_store managed <<<\n';

    test('a block written twice is an error, not entries of a person', () {
      final editor = PubspecEditor.parse(dup, marker: _store);
      for (final edit in <void Function()>[
        () => editor.managed('dependency_overrides'),
        () => editor.setManaged('dependency_overrides', const {}),
        () => editor.setManaged('dependency_overrides', {'a': knight}),
      ]) {
        expect(
          edit,
          throwsA(
            isA<PubspecEditException>().having(
              (e) => e.message,
              'message',
              contains('appears twice'),
            ),
          ),
        );
      }
      expect(editor.text, dup);
    });

    const linked =
        'dependency_overrides:\n'
        '  # >>> just_core_cli managed (just dev link) >>>\n'
        '  foo:\n'
        '    path: ../foo\n'
        '  # <<< just_core_cli managed <<<\n';

    test("another tool's entries are never taken over", () {
      final store = PubspecEditor.parse(linked, marker: _store);
      expect(
        () => store.setManaged('dependency_overrides', {
          'foo': const PathDependency('../foo'),
        }),
        throwsA(
          isA<PubspecEditException>()
              .having((e) => e.names, 'names', ['foo'])
              .having((e) => e.message, 'message', contains('just_core_cli')),
        ),
      );
      expect(store.text, linked);
      store.removeUnmanaged('dependency_overrides', 'foo');
      expect(store.text, linked, reason: 'not a person\'s entry');
      // Its own block next to it is fine, and leaves the other alone.
      store.setManaged('dependency_overrides', {'bar': knight});
      final links = PubspecEditor.parse(
        store.text,
        marker: ManagedBlock.devLinks,
      )..setManaged('dependency_overrides', const {});
      expect(links.text, isNot(contains('foo')));
      expect(
        PubspecEditor.parse(
          links.text,
          marker: _store,
        ).managed('dependency_overrides'),
        {'bar': knight},
      );
    });

    test('a section without the block is left as written', () {
      for (final text in [
        'name: x\ndependency_overrides:\n#  foo:\n#    path: ../foo\n',
        'name: x\ndependency_overrides:\n',
        'name: x\ndependency_overrides: # later\n',
      ]) {
        final editor = PubspecEditor.parse(text, marker: _store)
          ..setManaged('dependency_overrides', const {});
        expect(editor.text, text);
      }
    });

    test('a header with a comment of its own outlives the block', () {
      const text = 'name: x\ndependency_overrides: # mine\n';
      final editor = PubspecEditor.parse(text, marker: _store)
        ..setManaged('dependency_overrides', {'a': knight})
        ..setManaged('dependency_overrides', const {});
      expect(editor.text, text);
    });
  });

  group('entries', () {
    test('quoted keys are entries too', () {
      const text = 'dependencies:\n  "foo": ^1.0.0\n  \'bar\': ^1.0.0\n';
      final editor = PubspecEditor.parse(text, marker: _store);
      expect(editor.unmanaged('dependencies').keys, ['foo', 'bar']);
      expect(
        () => editor.setManaged('dependencies', {
          'foo': const HostedDependency('^2.0.0'),
        }),
        throwsA(isA<PubspecEditException>()),
      );
      editor.setManaged('dependencies', {
        'bar': const HostedDependency('^1.0.0'),
      });
      expect(editor.text, isNot(contains("'bar'")));
      expect(editor.managed('dependencies').keys, ['bar']);
    });

    test('an identical entry of another kind is adopted too', () {
      const text =
          'dependencies:\n'
          '  flutter:\n'
          '    sdk: flutter\n';
      final editor = PubspecEditor.parse(text, marker: _store);
      final flutter = editor.unmanaged('dependencies')['flutter']!;
      final copy = OtherDependency((flutter as OtherDependency).text);
      expect(copy, flutter);
      expect(copy.hashCode, flutter.hashCode);
      editor.setManaged('dependencies', {'flutter': copy});
      expect(editor.managed('dependencies'), {'flutter': flutter});
      expect(editor.unmanaged('dependencies'), isEmpty);
    });

    test('values YAML would read as something else are quoted', () {
      for (final path in [
        'null', '~', 'true', 'No', 'on', '123', '1.5', '1e3', '.inf', '0x1F', //
      ]) {
        final text = (PubspecEditor.parse(
          'name: x\n',
          marker: _store,
        )..setManaged('dependencies', {'a': PathDependency(path)})).text;
        expect(text, contains("path: '$path'"), reason: path);
        expect(
          PubspecEditor.parse(
            text,
            marker: _store,
          ).managed('dependencies')['a'],
          PathDependency(path),
        );
      }
      final plain =
          (PubspecEditor.parse('name: x\n', marker: _store)
                ..setManaged('dependencies', {
                  'a': const PathDependency('packages/a'),
                  'b': const HostedDependency('1.2.3'),
                  'c': const HostedDependency('^0.1.0-dev.1'),
                }))
              .text;
      expect(plain, contains('path: packages/a\n'));
      expect(plain, contains('b: 1.2.3\n'));
      expect(plain, contains('c: ^0.1.0-dev.1\n'));
    });
  });

  test('pub accepts what the editor writes', () async {
    // dart pub get --offline on a project whose pubspec the editor wrote: a
    // path dependency in a managed block, and an override pointing it
    // elsewhere.
    final dir = Directory.systemTemp.createTempSync('pubspec_editor');
    addTearDown(() => dir.deleteSync(recursive: true));
    for (final where in [
      'packages/characters/just_art_knight',
      'local/just_art_knight',
    ]) {
      Directory('${dir.path}/$where').createSync(recursive: true);
      File('${dir.path}/$where/pubspec.yaml').writeAsStringSync(
        'name: just_art_knight\nversion: 1.0.0\nenvironment:\n  sdk: ^3.0.0\n',
      );
    }
    final editor =
        PubspecEditor.parse(
            'name: app\r\npublish_to: none\r\nenvironment:\r\n  sdk: ^3.0.0\r\n'
            '# A comment the editor must keep.\r\n',
            marker: _store,
          )
          ..setManaged('dependencies', {'just_art_knight': knight})
          ..setManaged('dependency_overrides', {
            'just_art_knight': const PathDependency('local/just_art_knight'),
          });
    File('${dir.path}/pubspec.yaml').writeAsStringSync(editor.text);
    final result = await Process.run(Platform.resolvedExecutable, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: dir.path);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(
      File('${dir.path}/.dart_tool/package_config.json').readAsStringSync(),
      contains('local/just_art_knight'),
    );
  });
}

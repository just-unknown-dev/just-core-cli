// PubspecConstraints: one-line constraints change, and nothing else does.
import 'package:just_core_cli/just_core_cli.dart';
import 'package:test/test.dart';

void main() {
  test('a flow collection is not a constraint', () {
    const text =
        'name: g\n'
        'dependencies:\n'
        '  just_game_engine: {path: ../engine}\n'
        '  just_tiled: [1]\n';
    for (final name in ['just_game_engine', 'just_tiled']) {
      expect(PubspecConstraints.of(text, 'dependencies', name), isNull);
      expect(
        PubspecConstraints.set(text, 'dependencies', name, '^2.0.0'),
        text,
      );
    }
  });

  test("the section's own indent is used", () {
    const text =
        'name: g\r\n'
        'dependencies:\r\n'
        '    # four spaces here\r\n'
        '    just_game_engine: ^1.0.0 # pinned\r\n'
        '    path_dep:\r\n'
        '        path: ../x\r\n';
    expect(
      PubspecConstraints.of(text, 'dependencies', 'just_game_engine'),
      '^1.0.0',
    );
    expect(
      PubspecConstraints.set(
        text,
        'dependencies',
        'just_game_engine',
        '^2.0.0',
      ),
      text.replaceFirst('^1.0.0', '^2.0.0'),
    );
    expect(PubspecConstraints.of(text, 'dependencies', 'path'), isNull);
  });

  test('a constraint YAML would misread is quoted', () {
    const text = 'dependencies:\n  a: ^1.0.0\n  b: "^1.0.0"\n';
    final next = PubspecConstraints.set(
      text,
      'dependencies',
      'a',
      '>=1.0.0 <2.0.0',
    );
    expect(next, "dependencies:\n  a: '>=1.0.0 <2.0.0'\n  b: \"^1.0.0\"\n");
    expect(PubspecConstraints.of(next, 'dependencies', 'a'), '>=1.0.0 <2.0.0');
    expect(
      PubspecConstraints.set(text, 'dependencies', 'b', '>=1.0.0 <2.0.0'),
      contains('b: ">=1.0.0 <2.0.0"\n'),
    );
  });

  test('quoted keys, and entries in a managed block left alone', () {
    const text =
        'dependencies:\n'
        '  "a": ^1.0.0\n'
        '  # >>> pkg_store managed (edit in the store) >>>\n'
        '  b: ^1.0.0\n'
        '  # <<< pkg_store managed <<<\n';
    expect(
      PubspecConstraints.set(text, 'dependencies', 'a', '^2.0.0'),
      contains('  "a": ^2.0.0\n'),
    );
    expect(PubspecConstraints.of(text, 'dependencies', 'b'), isNull);
  });
}

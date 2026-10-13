// A new project's files: placeholders filled once and escaped for where
// they go, the pubspec lines for each package of the set, and the
// .gitignore entries added without disturbing the file.
import 'package:just_core_cli/just_core_cli.dart';
import 'package:test/test.dart';

void main() {
  group('render', () {
    const files = {
      'lib/main.dart': "// {{title}}\nconst title = '{{title.dart}}';\n",
      'pubspec.yaml':
          'name: {{name}}\n'
          'description: "{{title.yaml}}"\n'
          'dependencies:\n'
          '{{dependencies}}\n'
          'dev_dependencies:\n'
          '{{dev_dependencies}}\n'
          'flutter: {{unknown}}\n',
      'app.json': '{"title": "{{title.json}}", "app": "{{App}}"}',
      'Info.plist': '<string>{{title.xml}}</string>',
      'main.cpp': 'L"{{title.c}}"',
    };

    test('a title is written escaped for each file it goes into', () {
      const title = r'''Bob's "Big" $Game\ <&>''';
      final out = TemplateRenderer.render(
        files,
        names: ProjectNames('bobs_game', title: title),
      );
      expect(
        out['lib/main.dart'],
        "// $title\nconst title = 'Bob\\'s \"Big\" \\\$Game\\\\ <&>';\n",
      );
      expect(
        out['pubspec.yaml'],
        contains(r'''description: "Bob's \"Big\" $Game\\ <&>"'''),
      );
      expect(
        out['app.json'],
        r'''{"title": "Bob's \"Big\" $Game\\ <&>", "app": "BobsGameApp"}''',
      );
      expect(
        out['Info.plist'],
        '<string>Bob&apos;s &quot;Big&quot; \$Game\\ &lt;&amp;&gt;</string>',
      );
      expect(out['main.cpp'], r'''L"Bob's \"Big\" $Game\\ <&>"''');
    });

    test('lists become lines of their own; unknown keys stay', () {
      final out = TemplateRenderer.render(
        files,
        names: ProjectNames('x'),
        lines: {
          'dependencies': ['  a: ^1.0.0', '  b: ^2.0.0'],
          'dev_dependencies': const [],
        },
      );
      expect(
        out['pubspec.yaml'],
        'name: x\n'
        'description: "X"\n'
        'dependencies:\n'
        '  a: ^1.0.0\n'
        '  b: ^2.0.0\n'
        'dev_dependencies:\n'
        'flutter: {{unknown}}\n',
      );
      expect(
        TemplateRenderer.render(
          files,
          names: ProjectNames('x'),
          values: {'unknown': 'yes'},
        )['pubspec.yaml'],
        endsWith('flutter: yes\n'),
      );
    });

    test('what a placeholder is filled with is never filled again', () {
      final out = TemplateRenderer.render(
        files,
        names: ProjectNames('x', title: '{{App}} {{name}}'),
      );
      expect(out['lib/main.dart'], startsWith('// {{App}} {{name}}\n'));
    });

    test('a title with a control character is refused', () {
      expect(ProjectNames.titleProblem('Line\nbreak'), contains('U+000A'));
      expect(ProjectNames.titleProblem('  '), isNotNull);
      expect(ProjectNames.titleProblem('Fine'), isNull);
      expect(
        () => TemplateRenderer.render(
          files,
          names: ProjectNames('x', title: 'Tab\there'),
        ),
        throwsArgumentError,
      );
    });

    test('the names come from the package name', () {
      final names = ProjectNames('space_game_2');
      expect(names.title, 'Space Game 2');
      expect(names.app, 'SpaceGame2App');
    });
  });

  group('dependencyLines', () {
    test('a hosted package is a constraint', () {
      expect(
        TemplateRenderer.dependencyLines(
          const SetPackage('just_game_engine', '^2.0.0'),
        ),
        ['  just_game_engine: ^2.0.0'],
      );
    });

    test(
      'a git package names the folder it is in, when it is not the root',
      () {
        const nested = SetPackage(
          'just_thing',
          '^0.1.0',
          source: PackageSource.git,
          git: 'https://example.com/thing',
          ref: 'v0.1.0',
          path: 'packages/just_thing',
        );
        expect(TemplateRenderer.dependencyLines(nested), [
          '  just_thing:',
          '    git:',
          "      url: 'https://example.com/thing'",
          '      ref: v0.1.0',
          '      path: packages/just_thing',
        ]);
        // Linked to a checkout instead: the constraint, for the override.
        expect(TemplateRenderer.dependencyLines(nested, hosted: true), [
          '  just_thing: ^0.1.0',
        ]);
      },
    );
  });

  test('the tool set holds the tools alone, and names a plugin for each '
      'kind', () {
    const set = ToolSet.current;
    expect(set.kinds.keys.first, 'game');
    for (final plugin in set.kinds.values) {
      expect(set[plugin]?.dev, isTrue, reason: plugin);
    }
    expect(set.packages.map((p) => p.name), [
      'just_core_cli',
      'just_game_engine_cli',
    ], reason: "each plugin keeps its own packages' versions");
    expect(
      set.packages.every((p) => p.dev && p.source == PackageSource.hosted),
      isTrue,
    );
    expect(ToolSet.named(set.id), same(set));
    expect(ToolSet.named('1999.01'), isNull);
  });

  group('GitIgnores', () {
    test('adds what is missing, under its comment, in the file\'s endings', () {
      const text = 'build/\r\n';
      final out = GitIgnores.withLinks(text);
      expect(
        out,
        'build/\r\n\r\n'
        '# Links to local checkouts (`just dev link`): machine-local.\r\n'
        'pubspec_overrides.yaml\r\n',
      );
      expect(GitIgnores.withLinks(out), out, reason: 'nothing left to add');
      expect(GitIgnores.missing(out, ['a/', 'pubspec_overrides.yaml']), ['a/']);
    });

    test('a file without a final newline gets one first; an empty file no '
        'blank line', () {
      expect(GitIgnores.withEntries('a', ['b']), 'a\n\nb\n');
      expect(
        GitIgnores.withEntries('', ['b'], comment: 'Two\nlines'),
        '# Two\n# lines\nb\n',
      );
    });

    test('a CRLF template stays CRLF, a list placeholder included', () {
      final out = TemplateRenderer.render(
        {'pubspec.yaml': 'name: {{name}}\r\ndeps:\r\n{{deps}}\r\nend: 1\r\n'},
        names: ProjectNames('x'),
        lines: {
          'deps': ['  a: ^1.0.0', '  b: ^2.0.0'],
        },
      );
      expect(
        out['pubspec.yaml'],
        'name: x\r\ndeps:\r\n  a: ^1.0.0\r\n  b: ^2.0.0\r\nend: 1\r\n',
      );
      final none = TemplateRenderer.render(
        {'p': 'deps:\r\n{{deps}}\r\nend: 1\r\n'},
        names: ProjectNames('x'),
        lines: {'deps': const []},
      );
      expect(none['p'], 'deps:\r\nend: 1\r\n', reason: 'no stray blank line');
    });

    test('dependency lines quote what YAML would misread', () {
      const odd = SetPackage(
        'just_thing',
        '>=1.0.0 <2.0.0',
        source: PackageSource.git,
        git: 'https://example.com/thing',
        ref: '1.0',
      );
      expect(TemplateRenderer.dependencyLines(odd, hosted: true), [
        "  just_thing: '>=1.0.0 <2.0.0'",
      ]);
      expect(
        TemplateRenderer.dependencyLines(odd),
        contains("      ref: '1.0'"),
      );
      expect(PubspecEditor.scalar('^1.2.3'), '^1.2.3');
    });

    test('a block is named after a tool', () {
      expect(const ManagedBlock('my_tool').isValid, isTrue);
      expect(const ManagedBlock('my tool').isValid, isFalse);
      expect(
        () =>
            PubspecEditor.parse('name: x\n', marker: const ManagedBlock('a b')),
        throwsArgumentError,
      );
    });

    test('a new project ignores its links and the default trash', () {
      final out = GitIgnores.withDefaults('build/\n');
      expect(
        GitIgnores.missing(out, [...GitIgnores.links, '.just_trash/']),
        isEmpty,
      );
      expect(GitIgnores.withDefaults(out), out);
    });
  });
}

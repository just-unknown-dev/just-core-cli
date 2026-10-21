// The primary library's toolkit, on every platform: run on the VM, and in a
// browser with `dart test -p chrome` (JavaScript) and
// `dart test -p chrome -c dart2wasm` (WebAssembly).

import 'dart:convert';
import 'dart:typed_data';

import 'package:just_core_cli/just_core_cli.dart';
import 'package:test/test.dart';

void main() {
  test('a ZIP written in memory reads back, byte for byte', () {
    final big = Uint8List.fromList([
      for (var i = 0; i < 70000; i++) (i * 31) & 0xFF,
    ]);
    final zip =
        (ZipWriter()
              ..add('pubspec.yaml', utf8.encode('name: x\n'))
              ..add('bin/run.sh', utf8.encode('#!/bin/sh\n'), executable: true)
              ..add('assets/big.bin', big))
            .close();
    final archive = ZipArchive.read(zip);
    expect(archive.files.map((e) => e.path), [
      'assets/big.bin',
      'bin/run.sh',
      'pubspec.yaml',
    ]);
    expect(archive.contentOf(archive.entry('assets/big.bin')!), big);
    expect(archive.entry('bin/run.sh')!.isExecutable, isTrue);
    expect(
      ZipWriter().close(),
      ZipWriter().close(),
      reason: 'the same files give the same bytes',
    );
    expect(
      () => SafePaths.check('../escape'),
      throwsA(isA<UnsafePathException>()),
    );
  });

  test('SHA-256 matches the NIST vectors, past 2^32 bits of length too', () {
    expect(
      Sha256.hexOf(utf8.encode('abc')),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(
      Sha256.hexOf(const []),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
    final million = Uint8List(1000000)..fillRange(0, 1000000, 0x61);
    expect(
      Sha256.hexOf(million),
      'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
    );
  });

  test('versions and constraints read as pub reads them', () {
    final v = Version.parse('1.2.3-dev.1+build');
    expect(v < Version.parse('1.2.3'), isTrue);
    expect(
      VersionConstraint.parse('^1.2.0').allows(Version.parse('1.9.0')),
      isTrue,
    );
    expect(
      VersionConstraint.parse('^0.1.0').allows(Version.parse('0.2.0')),
      isFalse,
    );
    expect(PackageNames.idProblem('my_tool'), isNull);
    expect(PackageNames.idProblem('My Tool'), isNotNull);
    // Ids and categories are folder names: never one Windows can't make.
    for (final device in ['con', 'nul', 'aux', 'prn', 'com1', 'lpt9']) {
      expect(PackageNames.idProblem(device), contains('device'));
      expect(PackageNames.isCategory(device), isFalse);
    }
    expect(PackageNames.isId('console'), isTrue);
    expect(PackageNames.isCategory('com-tools'), isTrue);
  });

  test('a pubspec edit keeps every other byte', () {
    const block = ManagedBlock('my_tool', hint: 'my_tool add');
    const text = 'name: x # mine\r\ndependencies:\r\n  a: ^1.0.0\r\n';
    final editor = PubspecEditor.parse(text, marker: block)
      ..setManaged('dependencies', {'b': const HostedDependency('^2.0.0')});
    expect(editor.text, startsWith('name: x # mine\r\n'));
    expect(
      editor.text,
      contains('# >>> my_tool managed (my_tool add) >>>\r\n'),
    );
    expect(editor.managed('dependencies').keys, ['b']);
    expect(
      PubspecConstraints.of(
        PubspecConstraints.set(text, 'dependencies', 'a', '^1.5.0'),
        'dependencies',
        'a',
      ),
      '^1.5.0',
    );
  });

  test('a template is filled for a project', () {
    final files = TemplateRenderer.render({
      'README.md': '# {{title}}\n',
      'lib/main.dart': "const t = '{{title.dart}}';",
    }, names: ProjectNames('space_rocks', title: "Bob's Rocks"));
    expect(files['README.md'], "# Bob's Rocks\n");
    expect(files['lib/main.dart'], r"const t = 'Bob\'s Rocks';");
    expect(GitIgnores.withDefaults(''), contains('${ProjectPaths.trashRoot}/'));
    expect(ToolSet.named(ToolSet.current.id), same(ToolSet.current));
  });

  test("just.json and a plugin's manifest are read from text", () {
    final file = JustProjectFile.parse(
      '{"title": "Rocks", "set": "2026.10", "mine": [1]}',
    );
    expect(file.title, 'Rocks');
    expect(file.extra, {
      'mine': [1],
    });
    expect(JustProjectFile.parse(file.toText()).extra, file.extra);

    final manifest = PluginManifest.parse(
      jsonEncode({
        'commands': [
          {'name': 'hello', 'summary': 'Say hello.'},
        ],
        'shortcuts': {'hi': 'hello world'},
        'hooks': {'check': 'hello check'},
      }),
    );
    expect(manifest.commands, {'hello': 'Say hello.'});
    expect(manifest.hooks['check'], 'hello check');
    expect(
      () => PluginManifest.parse('{"schema": 99}'),
      throwsA(isA<JsonFormatException>()),
    );
  });

  test('the rest of the toolkit', () {
    expect(const Finding(Severity.warning, 'Look.', fix: 'Do.').toJson(), {
      'severity': 'warning',
      'message': 'Look.',
      'fix': 'Do.',
    });
    expect(ExitCodes.usage, 2);
    expect(const CommandFailure('No.').exitCode, ExitCodes.failure);
    final token = CancelToken();
    var called = false;
    token.onCancel(() => called = true);
    token.cancel();
    expect((token.isCancelled, called), (true, true));
    expect(
      GitHubRepo.tryParse('https://github.com/just-unknown-dev/just-core-cli'),
      isNotNull,
    );
    expect(justCoreCliVersion, isNotEmpty);
  });
}

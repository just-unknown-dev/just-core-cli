// macOS and Linux: files keep their permissions and stay symbolic links
// through every write `just` makes, and staged files can be executable.
@TestOn('linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_core_cli/project.dart';
import 'package:test/test.dart';

String _mode(String path) =>
    (FileStat.statSync(path).mode & 0x1FF).toRadixString(8);

void _chmod(String mode, String path) {
  final r = Process.runSync('chmod', [mode, path]);
  if (r.exitCode != 0) throw StateError('chmod: ${r.stderr}');
}

void main() {
  late Directory tmp;
  late JustProject project;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('just_posix_');
    File('${tmp.path}/pubspec.yaml').writeAsStringSync('name: x\n');
    File('${tmp.path}/tool/run.sh')
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\necho hi\n');
    _chmod('755', '${tmp.path}/tool/run.sh');
    project = JustProject(tmp.path);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('an atomic write keeps the mode', () {
    writeTextAtomic(project.file('tool/run.sh'), '#!/bin/sh\necho new\n');
    expect(_mode('${tmp.path}/tool/run.sh'), '755');
    expect(File('${tmp.path}/tool/run.sh').readAsStringSync(), contains('new'));
  });

  test('an atomic write goes through a symbolic link', () {
    File('${tmp.path}/real.yaml').writeAsStringSync('a: 1\n');
    _chmod('600', '${tmp.path}/real.yaml');
    Link('${tmp.path}/pubspec_overrides.yaml').createSync('real.yaml');
    writeTextAtomic(project.file('pubspec_overrides.yaml'), 'a: 2\n');
    expect(
      FileSystemEntity.isLinkSync('${tmp.path}/pubspec_overrides.yaml'),
      isTrue,
    );
    expect(File('${tmp.path}/real.yaml').readAsStringSync(), 'a: 2\n');
    expect(_mode('${tmp.path}/real.yaml'), '600');
  });

  test('a rollback puts the mode back with the bytes', () {
    final t = ProjectTransaction.begin(project, trash: 'test')
      ..write('tool/run.sh', '#!/bin/sh\necho changed\n');
    _chmod('644', '${tmp.path}/tool/run.sh');
    t.rollBack();
    expect(_mode('${tmp.path}/tool/run.sh'), '755');
    expect(
      File('${tmp.path}/tool/run.sh').readAsStringSync(),
      contains('echo hi'),
    );
  });

  group('a change and symbolic links', () {
    late Directory outside;
    setUp(() {
      outside = Directory.systemTemp.createTempSync('just_outside_');
      File('${outside.path}/victim.txt').writeAsStringSync('precious\n');
    });
    tearDown(() => outside.deleteSync(recursive: true));

    bool isLink(String rel) => FileSystemEntity.isLinkSync('${tmp.path}/$rel');

    test('never writes through a link that leads out of the project', () {
      Link('${tmp.path}/just.json').createSync('${outside.path}/victim.txt');
      Link('${tmp.path}/new.json').createSync('${outside.path}/new/made.json');
      Link('${tmp.path}/shared').createSync(outside.path);
      final t = ProjectTransaction.begin(project, trash: 'test');
      final refused = throwsA(
        isA<FileSystemException>().having(
          (e) => e.message,
          'message',
          contains('outside the project'),
        ),
      );
      expect(() => t.write('just.json', '{}\n'), refused);
      expect(() => t.write('new.json', '{}\n'), refused, reason: 'dangling');
      expect(() => t.write('shared/x.json', '{}\n'), refused);
      expect(() => t.backUp(['just.json']), refused);
      expect(() => t.delete('shared/victim.txt'), refused);
      t.rollBack();
      expect(
        File('${outside.path}/victim.txt').readAsStringSync(),
        'precious\n',
      );
      expect(outside.listSync().map((e) => e.uri.pathSegments.last), [
        'victim.txt',
      ], reason: 'nothing made there, no temporary file either');
      expect(isLink('just.json') && isLink('new.json'), isTrue);
    });

    test('staging never goes through a link, even one inside the project', () {
      File('${tmp.path}/lib/main.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('// main');
      final staging = Directory(
        '${tmp.path}/${ProjectTransaction.staging}',
      ).parent..createSync(recursive: true);
      Link('${staging.path}/staging').createSync('${tmp.path}/lib');
      final t = ProjectTransaction.begin(project, trash: 'test');
      expect(
        () => t.stage('main.dart', {'x': Uint8List(1)}),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        () => t.moveIn('main.dart', 'x'),
        throwsA(isA<FileSystemException>()),
      );
      t.rollBack();
      expect(File('${tmp.path}/lib/main.dart').readAsStringSync(), '// main');
    });

    test('a link inside the project is written through and kept', () {
      File('${tmp.path}/real.yaml').writeAsStringSync('a: 1\n');
      Link('${tmp.path}/pubspec_overrides.yaml').createSync('real.yaml');
      final t = ProjectTransaction.begin(project, trash: 'test')
        ..write('pubspec_overrides.yaml', 'a: 2\n');
      expect(File('${tmp.path}/real.yaml').readAsStringSync(), 'a: 2\n');
      t.rollBack();
      expect(File('${tmp.path}/real.yaml').readAsStringSync(), 'a: 1\n');
      expect(isLink('pubspec_overrides.yaml'), isTrue);
    });

    test('a link to nothing is still one after a rollback', () {
      Link('${tmp.path}/just.json').createSync('config/just.json');
      final t = ProjectTransaction.begin(project, trash: 'test')
        ..write('just.json', '{}\n');
      expect(File('${tmp.path}/config/just.json').readAsStringSync(), '{}\n');
      t.rollBack();
      expect(Link('${tmp.path}/just.json').targetSync(), 'config/just.json');
      expect(File('${tmp.path}/config/just.json').existsSync(), isFalse);
    });

    test('a deleted link is the link alone, made again by a rollback or a '
        'recovery', () {
      File('${tmp.path}/real.yaml').writeAsStringSync('a: 1\n');
      Link('${tmp.path}/l.yaml').createSync('real.yaml');
      final t = ProjectTransaction.begin(project, trash: 'test')
        ..delete('l.yaml');
      expect(
        FileSystemEntity.typeSync('${tmp.path}/l.yaml', followLinks: false),
        FileSystemEntityType.notFound,
      );
      expect(File('${tmp.path}/real.yaml').existsSync(), isTrue);
      t.rollBack();
      expect(Link('${tmp.path}/l.yaml').targetSync(), 'real.yaml');

      // After a crash, from the journal.
      ProjectTransaction.begin(project, trash: 'test').delete('l.yaml');
      expect(isLink('l.yaml'), isFalse);
      expect(ProjectTransaction.recover(project), isTrue);
      expect(Link('${tmp.path}/l.yaml').targetSync(), 'real.yaml');
      expect(File('${tmp.path}/real.yaml').readAsStringSync(), 'a: 1\n');
    });
  });

  test('staged files the archive marks executable are executable', () {
    final t = ProjectTransaction.begin(project, trash: 'test')
      ..stage(
        'item',
        {
          'bin/tool.sh': Uint8List.fromList(utf8.encode('#!/bin/sh\n')),
          'README.md': Uint8List.fromList(utf8.encode('# x\n')),
        },
        executable: {'bin/tool.sh'},
      )
      ..moveIn('item', 'packages/item');
    t.commit();
    expect(
      FileStat.statSync('${tmp.path}/packages/item/bin/tool.sh').mode & 0x40,
      isNonZero,
    );
    expect(
      FileStat.statSync('${tmp.path}/packages/item/README.md').mode & 0x49,
      isZero,
    );
  });
}

// ProjectLock and ProjectTransaction: one change at a time, and every
// change undone byte for byte on failure or after a crash.

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_core_cli/project.dart';
import 'package:just_core_cli/src/project/windows_processes.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late JustProject project;

  setUp(() {
    root = Directory.systemTemp.createTempSync('just_txn_');
    project = JustProject(root.path);
    project.file('pubspec.yaml').writeAsStringSync('name: game\r\n');
    project.file('assets/scenes/scenes.json').createSync(recursive: true);
    project.file('assets/scenes/scenes.json').writeAsStringSync('{"a":1}');
    project.file('packages/kits/old/lib/old.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync('// old');
  });

  tearDown(() => root.deleteSync(recursive: true));

  Map<String, String> snapshot() => {
    for (final f in root.listSync(recursive: true).whereType<File>())
      if (!f.path.replaceAll(r'\', '/').contains('/.dart_tool/'))
        project.relativeOf(f.path)!: base64.encode(f.readAsBytesSync()),
  };

  group('ProjectLock', () {
    test('only one holder at a time', () {
      final first = ProjectLock.acquire(project);
      expect(ProjectLock.tryAcquire(project), isNull);
      expect(
        () => ProjectLock.acquire(project),
        throwsA(isA<ProjectBusyException>()),
      );
      first.release();
      ProjectLock.acquire(project).release();
    });

    test('a lock left by a crash long ago is taken over', () {
      final file = project.file(ProjectLock.path)
        ..createSync(recursive: true)
        ..writeAsStringSync('999 old');
      file.setLastModifiedSync(
        DateTime.now().subtract(const Duration(minutes: 11)),
      );
      final lock = ProjectLock.tryAcquire(project);
      expect(lock, isNotNull);
      // Moved aside under the taker's own name, then removed.
      expect(
        file.parent.listSync().map((e) => e.uri.pathSegments.last).toList(),
        ['lock'],
      );
      expect(file.readAsStringSync(), contains('"token"'));
      lock!.release();
    });

    /// This process's lock, as written while it is held.
    Map<String, Object?> ownLock() {
      final lock = ProjectLock.acquire(project);
      final json =
          jsonDecode(project.file(ProjectLock.path).readAsStringSync())
              as Map<String, Object?>;
      lock.release();
      return json;
    }

    /// Whether a fresh lock [json] is taken over at once.
    bool takenOver(Map<String, Object?> json) {
      final file = project.file(ProjectLock.path)
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(json));
      final lock = ProjectLock.tryAcquire(project);
      lock?.release();
      if (file.existsSync()) file.deleteSync();
      return lock != null;
    }

    test("a crashed process's lock on this machine is taken over at once", () {
      final here = ownLock();
      // A pid no process has: the process that held it is gone.
      final crashed = {...here, 'pid': 0x7FFFFFF0, 'token': 'gone'};
      expect(
        takenOver(crashed),
        isTrue,
        reason: 'fresh, but its holder is not running',
      );

      // This process's own lock, or another machine's: still busy, and the
      // message says where the lock is and when it goes stale.
      final mine = ProjectLock.acquire(project);
      expect(
        () => ProjectLock.acquire(project),
        throwsA(
          isA<ProjectBusyException>().having(
            (e) => e.message,
            'message',
            allOf(contains('process $pid'), contains('just_core_cli/lock')),
          ),
        ),
      );
      mine.release();
      expect(takenOver({...crashed, 'host': 'another-machine'}), isFalse);
    });

    test('a lock from another system or process space waits until stale', () {
      final crashed = {...ownLock(), 'pid': 0x7FFFFFF0, 'token': 'gone'};
      // WSL beside Windows, or an older `just` that didn't say.
      expect(takenOver({...crashed, 'os': 'elsewhere'}), isFalse);
      expect(takenOver({...crashed}..remove('os')), isFalse);
      if (Platform.isLinux) {
        // A Flatpak sandbox, or the machine since restarted.
        expect(takenOver({...crashed, 'pidNamespace': 'pid:[1]'}), isFalse);
        expect(takenOver({...crashed, 'bootId': 'another-boot'}), isFalse);
        expect(takenOver({...crashed}..remove('bootId')), isFalse);
      }
    });

    test('names its holder and where it runs', () {
      final json = ownLock();
      expect(json['pid'], pid);
      expect(json['token'], isA<String>());
      expect(json['host'], Platform.localHostname);
      expect(json['os'], Platform.operatingSystem);
      expect(project.file(ProjectLock.path).existsSync(), isFalse);
    });

    test('on Linux it names its pid namespace and boot', () {
      final json = ownLock();
      expect(json['pidNamespace'], startsWith('pid:['));
      expect(json['bootId'], isNotEmpty);
    }, testOn: 'linux');

    test('a lock from before a restart says so, and waits', () {
      final crashed = {
        ...ownLock(),
        'pid': 0x7FFFFFF0,
        'token': 'gone',
        'bootId': 'another-boot',
      };
      project.file(ProjectLock.path)
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(crashed));
      expect(
        () => ProjectLock.acquire(project),
        throwsA(
          isA<ProjectBusyException>().having(
            (e) => e.message,
            'message',
            allOf(contains('has restarted since'), contains('min after')),
          ),
        ),
      );
    }, testOn: 'linux');

    test('Windows tells a running process from a gone one at once', () {
      final watch = Stopwatch()..start();
      expect(windowsProcessRuns(pid), isTrue);
      expect(windowsProcessRuns(0x7FFFFFF0), isFalse);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    }, testOn: 'windows');

    test('a holder that was taken over does not release the new one', () {
      final first = ProjectLock.acquire(project);
      // The first holder went quiet for longer than [ProjectLock.stale].
      project
          .file(ProjectLock.path)
          .setLastModifiedSync(
            DateTime.now().subtract(const Duration(minutes: 11)),
          );
      final second = ProjectLock.tryAcquire(project);
      expect(second, isNotNull);
      first.release();
      expect(project.file(ProjectLock.path).existsSync(), isTrue);
      expect(ProjectLock.tryAcquire(project), isNull);
      second!.release();
      expect(project.file(ProjectLock.path).existsSync(), isFalse);
    });

    test('a lock that cannot be made is an error, not "busy"', () {
      // Something that isn't a file is where the lock goes.
      project.dir(ProjectLock.path).createSync(recursive: true);
      expect(
        () => ProjectLock.tryAcquire(project),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('ProjectTransaction', () {
    test('a rollback puts every file back byte for byte', () {
      final before = snapshot();
      final txn = ProjectTransaction.begin(project, trash: 'test')
        ..backUp(['pubspec.yaml', 'pubspec_overrides.yaml'])
        ..write('pubspec.yaml', 'name: changed\n')
        ..write('pubspec_overrides.yaml', 'dependency_overrides:\n')
        ..write('assets/scenes/new.scene.json', '{}')
        ..delete('assets/scenes/scenes.json');
      expect(project.file('pubspec_overrides.yaml').existsSync(), isTrue);
      txn.rollBack();
      expect(snapshot(), before);
      expect(project.dir(ProjectTransaction.journals).existsSync(), isFalse);
    });

    test('folders moved aside and in are undone too', () {
      final before = snapshot();
      final txn = ProjectTransaction.begin(project, trash: 'test')
        ..stage('new', {'lib/new.dart': Uint8List.fromList(utf8.encode('//'))})
        ..moveAside('old', 'packages/kits/old')
        ..moveIn('new', 'packages/kits/old');
      expect(
        project.file('packages/kits/old/lib/new.dart').existsSync(),
        isTrue,
      );
      txn.rollBack();
      expect(snapshot(), before);
    });

    test('a commit sends replaced folders to the trash', () {
      final txn = ProjectTransaction.begin(project, trash: 'tool')
        ..moveAside('old', 'packages/kits/old');
      txn.commit();
      expect(project.dir('packages/kits/old').existsSync(), isFalse);
      final trashed = project.file(
        '.just_trash/tool/${txn.stamp}/packages/kits/old/lib/old.dart',
      );
      expect(trashed.readAsStringSync(), '// old');
    });

    test("a tool's own trash root is kept in the journal", () {
      final txn = ProjectTransaction.begin(
        project,
        trash: 'tool',
        trashRoot: '.my_trash',
      )..moveAside('old', 'packages/kits/old');
      final journal = File('${txn.dir.path}/journal.json');
      final json = jsonDecode(journal.readAsStringSync()) as Map;
      expect(json['trashRoot'], '.my_trash');
      journal.writeAsStringSync(jsonEncode({...json, 'state': 'committed'}));
      // A crash before the trash: recover finishes it, in the same root.
      expect(ProjectTransaction.recover(project), isTrue);
      expect(project.dir('.my_trash/tool/${txn.stamp}').existsSync(), isTrue);
      expect(project.dir('.just_trash').existsSync(), isFalse);
    });

    test('recover undoes changes newest first, the tenth of a millisecond '
        'after the ninth', () {
      final now = DateTime.utc(2026, 10, 13, 12);
      // Eleven changes in one millisecond: <stamp>, <stamp>-1 … <stamp>-10.
      // The tenth makes x.txt, the eleventh changes it; none committed.
      for (var i = 0; i <= 10; i++) {
        final t = ProjectTransaction.begin(project, now: now, trash: 'test');
        if (i == 9) t.write('x.txt', 'made by the tenth');
        if (i == 10) t.write('x.txt', 'changed by the eleventh');
      }
      expect(ProjectTransaction.recover(project), isTrue);
      expect(
        project.file('x.txt').existsSync(),
        isFalse,
        reason: 'the eleventh undone first, then the tenth',
      );
    });

    test('recover undoes a change a crash left half done', () {
      final before = snapshot();
      ProjectTransaction.begin(project, trash: 'test')
        ..write('pubspec.yaml', 'name: half\n')
        ..write('lib/new.dart', '// new');
      // The process "dies" here: no commit, no rollback.
      expect(ProjectTransaction.recover(project), isTrue);
      expect(snapshot(), before);
      expect(ProjectTransaction.recover(project), isFalse);
    });

    test('recover finishes a change that had committed', () {
      final txn = ProjectTransaction.begin(project, trash: 'test')
        ..moveAside('old', 'packages/kits/old');
      // Committed in the journal, but the process died before the trash.
      final journal = File('${txn.dir.path}/journal.json');
      final json = jsonDecode(journal.readAsStringSync()) as Map;
      journal.writeAsStringSync(jsonEncode({...json, 'state': 'committed'}));
      expect(ProjectTransaction.recover(project), isTrue);
      expect(project.dir('packages/kits/old').existsSync(), isFalse);
      expect(project.dir('.just_trash/test').existsSync(), isTrue);
    });

    test("recover reads a tool's older journals, and files their trash where "
        'it is told', () {
      final legacy = '.dart_tool/old_tool/txn';
      final txn = ProjectTransaction.begin(project, trash: 'test')
        ..moveAside('old', 'packages/kits/old');
      final journal = File('${txn.dir.path}/journal.json');
      final json = (jsonDecode(journal.readAsStringSync()) as Map)
        ..remove('trash')
        ..remove('trashRoot')
        ..['state'] = 'committed';
      // Where the tool kept it, and without the fields it didn't write.
      final moved = project.dir('$legacy/${txn.stamp}')
        ..createSync(recursive: true);
      for (final f in txn.dir.listSync(recursive: true).whereType<File>()) {
        final rel = f.path.substring(txn.dir.path.length + 1);
        File('${moved.path}/$rel')
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(f.readAsBytesSync());
      }
      File('${moved.path}/journal.json').writeAsStringSync(jsonEncode(json));
      txn.dir.deleteSync(recursive: true);
      // The aside folder in the moved journal still names the old place.
      expect(
        ProjectTransaction.recover(
          project,
          alsoIn: [legacy],
          trash: 'old_tool',
          trashRoot: '.old_trash',
        ),
        isTrue,
      );
      expect(project.dir('.old_trash/old_tool').existsSync(), isTrue);
    });

    test('a rollback after commit does nothing', () {
      final txn = ProjectTransaction.begin(project, trash: 'test')
        ..write('pubspec.yaml', 'name: new\n')
        ..stage('new', {'lib/new.dart': Uint8List.fromList(utf8.encode('//'))})
        ..moveAside('old', 'packages/kits/old')
        ..moveIn('new', 'packages/kits/old');
      txn
        ..commit()
        ..commit()
        ..rollBack();
      expect(project.readText('pubspec.yaml'), 'name: new\n');
      expect(
        project.file('packages/kits/old/lib/new.dart').existsSync(),
        isTrue,
      );
      expect(() => txn.write('a.txt', ''), throwsStateError);
    });

    test(
      'a commit whose tidying fails still commits, and keeps the new folder',
      () {
        final txn = ProjectTransaction.begin(project, trash: 'test')
          ..write('pubspec.yaml', 'name: new\n')
          ..stage('new', {
            'lib/new.dart': Uint8List.fromList(utf8.encode('// new')),
          })
          ..moveAside('old', 'packages/kits/old')
          ..moveIn('new', 'packages/kits/old');
        // An indexer has a backup copy open, so its folder can't go.
        final copy = Directory(
          '${txn.dir.path}/backup',
        ).listSync().whereType<File>().single;
        final held = copy.openSync();
        try {
          txn.commit(); // Doesn't throw.
          txn.rollBack(); // What callers do on an error: nothing now.
        } finally {
          held.closeSync();
        }
        expect(project.readText('pubspec.yaml'), 'name: new\n');
        expect(project.readText('packages/kits/old/lib/new.dart'), '// new');
        expect(ProjectTransaction.recover(project), isFalse);
        expect(project.dir(ProjectTransaction.journals).existsSync(), isFalse);
      },
      skip: Platform.isWindows ? false : 'open files block deletes on Windows',
    );

    test('a rollback cut short is finished, not undone twice', () {
      final before = snapshot();
      final txn = ProjectTransaction.begin(project, trash: 'test')
        ..write('pubspec.yaml', 'name: new\n')
        ..stage('new', {'lib/new.dart': Uint8List.fromList(utf8.encode('//'))})
        ..moveAside('old', 'packages/kits/old')
        ..moveIn('new', 'packages/kits/old');
      // A rollback got this far before the process died: the new folder
      // gone and the old one back, the files not yet restored.
      project.dir('packages/kits/old').deleteSync(recursive: true);
      Directory(
        '${txn.dir.path}/aside/old',
      ).renameSync(project.path('packages/kits/old'));
      for (var i = 0; i < 2; i++) {
        ProjectTransaction.recover(project);
        expect(snapshot(), before);
      }
    });

    test('a rollback cut short leaves the files it put back alone', () {
      final txn = ProjectTransaction.begin(project, trash: 'test')
        ..write('pubspec.yaml', 'name: new\n')
        ..write('assets/scenes/scenes.json', '{"a":2}');
      // scenes.json can't be put back: a file is where its folder goes.
      project.dir('assets/scenes').deleteSync(recursive: true);
      project.file('assets/scenes').writeAsStringSync('in the way');
      expect(txn.rollBack, throwsA(isA<FileSystemException>()));
      expect(project.readText('pubspec.yaml'), 'name: game\r\n');
      // Edited since; then the way is cleared, and the next tool recovers.
      project.file('pubspec.yaml').writeAsStringSync('name: edited\n');
      project.file('assets/scenes').deleteSync();
      expect(ProjectTransaction.recover(project), isTrue);
      expect(project.readText('assets/scenes/scenes.json'), '{"a":1}');
      expect(project.readText('pubspec.yaml'), 'name: edited\n');
      expect(ProjectTransaction.recover(project), isFalse);
    });

    test('a backup gone missing is an error, and the journal stays', () {
      final txn = ProjectTransaction.begin(project, trash: 'test')
        ..write('pubspec.yaml', 'name: new\n');
      Directory('${txn.dir.path}/backup').deleteSync(recursive: true);
      final missing = throwsA(
        isA<FileSystemException>().having(
          (e) => e.message,
          'message',
          contains('pubspec.yaml'),
        ),
      );
      expect(txn.rollBack, missing);
      expect(File('${txn.dir.path}/journal.json').existsSync(), isTrue);
      // Not passed off as rolled back by the next tool either.
      expect(() => ProjectTransaction.recover(project), missing);
      expect(File('${txn.dir.path}/journal.json').existsSync(), isTrue);
    });

    test(
      'a rollback whose journal could not be removed is not undone again',
      () {
        project.file('a.txt').writeAsStringSync('v1');
        final txn = ProjectTransaction.begin(project, trash: 'test')
          ..write('a.txt', 'v2');
        // An indexer has the journal open as the rollback ends.
        final held = File('${txn.dir.path}/journal.json').openSync();
        try {
          txn.rollBack();
        } finally {
          held.closeSync();
        }
        expect(project.readText('a.txt'), 'v1');
        expect(File('${txn.dir.path}/journal.json').existsSync(), isTrue);
        // Work goes on; the next change's recover must not undo it.
        project.file('a.txt').writeAsStringSync('v3');
        expect(ProjectTransaction.recover(project), isFalse);
        expect(project.readText('a.txt'), 'v3');
        expect(project.dir(ProjectTransaction.journals).existsSync(), isFalse);
      },
      skip: Platform.isWindows ? false : 'open files block deletes on Windows',
    );

    test('a journal marked rolled back is only tidied away', () {
      final txn = ProjectTransaction.begin(project, trash: 'test')
        ..write('pubspec.yaml', 'name: new\n')
        ..stage('new', {'lib/new.dart': Uint8List.fromList(utf8.encode('//'))})
        ..moveIn('new', 'packages/kits/fresh');
      // As a rollback leaves it when its journal can't be removed.
      File('${txn.dir.path}/rolled-back').writeAsStringSync('');
      expect(ProjectTransaction.recover(project), isFalse);
      expect(project.readText('pubspec.yaml'), 'name: new\n');
      expect(project.dir('packages/kits/fresh').existsSync(), isTrue);
      expect(project.dir(ProjectTransaction.journals).existsSync(), isFalse);
    });

    test('a file deleted and then written under another spelling is put '
        'back', () {
      project.file('a.json').writeAsStringSync('original');
      final before = snapshot();
      ProjectTransaction.begin(project, trash: 'test')
        ..delete('a.json')
        ..write('A.json', 'new')
        ..rollBack();
      expect(snapshot(), before);
    });

    test('in a folder that tells case apart, two spellings are two files', () {
      // Windows can make one folder case-sensitive (as WSL does); the
      // journal must then not take Level for level.
      final dir = Directory('${root.path}/cs')..createSync();
      final made = Process.runSync('fsutil.exe', [
        'file',
        'setCaseSensitiveInfo',
        dir.path,
        'enable',
      ]);
      if (made.exitCode != 0) {
        markTestSkipped('fsutil could not make a case-sensitive folder');
        return;
      }
      final cs = JustProject(dir.path);
      cs.file('assets/scenes/Level.scene.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"name": "Level"}');
      final txn = ProjectTransaction.begin(cs, trash: 'test')
        ..write('assets/scenes/level.scene.json', '{"name": "level"}')
        ..delete('assets/scenes/Level.scene.json');
      txn.rollBack();
      final names = [
        for (final f in cs.dir('assets/scenes').listSync())
          f.uri.pathSegments.where((s) => s.isNotEmpty).last,
      ];
      expect(names, ['Level.scene.json']);
      expect(
        cs.readText('assets/scenes/Level.scene.json'),
        '{"name": "Level"}',
      );
    }, skip: Platform.isWindows ? false : 'a case-sensitive folder on Windows');

    test('a project moved after a crash gets its folders back', () {
      ProjectTransaction.begin(
        project,
        trash: 'test',
      ).moveAside('old', 'packages/kits/old');
      final moved = Directory('${root.path}_moved');
      root.renameSync(moved.path);
      root = moved;
      final there = JustProject(moved.path);
      expect(ProjectTransaction.recover(there), isTrue);
      expect(there.readText('packages/kits/old/lib/old.dart'), '// old');
    });

    test('files whose backups could share a name are each put back', () {
      project.file('x/y.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('x/y');
      project.file('x__y.json').writeAsStringSync('x__y');
      final before = snapshot();
      ProjectTransaction.begin(project, trash: 'test')
        ..write('x/y.json', 'changed')
        ..write('x__y.json', 'changed')
        ..write(r'x\y.json', 'changed again')
        ..rollBack();
      expect(snapshot(), before);
    });

    test('a staging or aside name is a plain folder name, or nothing '
        'happens', () {
      project.file('lib/main.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('// main');
      final before = snapshot();
      final t = ProjectTransaction.begin(project, trash: 'test');
      for (final id in ['../../../lib', '..', '.', '', 'a/b', r'a\b', 'C:x']) {
        expect(
          () => t.stage(id, {'q.txt': Uint8List(1)}),
          throwsArgumentError,
          reason: id,
        );
        expect(() => t.moveIn(id, 'lib2'), throwsArgumentError, reason: id);
        expect(
          () => t.moveAside(id, 'packages/kits/old'),
          throwsArgumentError,
          reason: id,
        );
      }
      // Moving in what was never staged, or reusing an aside name.
      expect(() => t.moveIn('nothing', 'lib2'), throwsStateError);
      t.moveAside('old', 'packages/kits/old');
      project.dir('packages/kits/old').createSync();
      expect(() => t.moveAside('old', 'packages/kits/old'), throwsStateError);
      project.dir('packages/kits/old').deleteSync();
      t.rollBack();
      expect(snapshot(), before);
    });

    test('a file written under another spelling keeps its own name', () {
      final t = ProjectTransaction.begin(project, trash: 'test')
        ..write('PUBSPEC.YAML', 'name: other\n')
        ..write('ASSETS/Scenes/SCENES.json', '{}');
      List<String> names(String dir) => [
        for (final e in Directory(dir).listSync())
          e.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
      ];
      expect(names(root.path), contains('pubspec.yaml'));
      expect(names(root.path), isNot(contains('PUBSPEC.YAML')));
      expect(names('${root.path}/assets/scenes'), ['scenes.json']);
      t.rollBack();
      expect(names(root.path), contains('pubspec.yaml'));
      expect(project.readText('pubspec.yaml'), 'name: game\r\n');
      expect(project.readText('assets/scenes/scenes.json'), '{"a":1}');
    }, testOn: 'windows');

    test('an unreadable journal names the folder its backups are in', () {
      final txn = ProjectTransaction.begin(project, trash: 'test')
        ..write('pubspec.yaml', 'name: new\n');
      File('${txn.dir.path}/journal.json').writeAsStringSync('{"state": ');
      expect(
        () => ProjectTransaction.recover(project),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('/backup'),
          ),
        ),
      );
    });
  });
}

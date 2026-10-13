// The ZIP reader against archives from real tools, the writer's
// reproducibility, and every kind of archive the store must refuse.
@TestOn('vm')
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_core_cli/project.dart';
import 'package:just_core_cli/fetch.dart';
import 'package:test/test.dart';

import 'support/raw_zip.dart';

Uint8List fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

final Matcher throwsZip = throwsA(isA<ZipFormatException>());
final Matcher throwsUnsafe = throwsA(isA<UnsafePathException>());

void main() {
  group('archives from other tools', () {
    // All four hold the same small package, made in the scratchpad with
    // Python's zipfile (deflated and stored entries, a folder entry and a
    // comment; and a streamed copy with data descriptors), PowerShell's
    // Compress-Archive and `git archive`.
    const names = {
      'pubspec.yaml',
      'sprites/hero/hero.json',
      'sprites/hero/hero.png',
      'audio/jump.wav',
    };

    Map<String, Uint8List> read(String file) {
      final zip = ZipArchive.read(fixture(file));
      return zip.extractAll();
    }

    for (final file in [
      'python_mixed.zip',
      'python_streamed.zip',
      'powershell.zip',
      'git_archive.zip',
    ]) {
      test(file, () {
        final files = read(file);
        expect(files.keys.toSet(), names);
        expect(
          utf8.decode(files['pubspec.yaml']!).replaceAll('\r\n', '\n'),
          'name: just_art_demo\nversion: 1.0.0\n',
        );
        expect(files['sprites/hero/hero.png']!.length, 3000);
        expect(files['audio/jump.wav'], everyElement(0));
        expect(files['audio/jump.wav']!.length, 1000);
        // `git archive` on Windows applies core.autocrlf, so text may come
        // back with CRLF endings.
        expect(
          utf8
              .decode(files['sprites/hero/hero.json']!)
              .replaceAll('\r\n', '\n'),
          startsWith('{"frames": {}, "meta": {"image": "hero.png"}}\n'),
        );
      });
    }

    test('every tool unpacks to the same bytes', () {
      final reference = read('python_mixed.zip');
      for (final file in [
        'python_streamed.zip',
        'powershell.zip',
        'git_archive.zip',
      ]) {
        final files = read(file);
        for (final name in ['sprites/hero/hero.png', 'audio/jump.wav']) {
          expect(files[name], reference[name], reason: '$file: $name');
        }
      }
    });

    test('folder entries are listed but hold nothing', () {
      final zip = ZipArchive.read(fixture('python_mixed.zip'));
      final folder = zip.entry('empty/')!;
      expect(folder.isDirectory, isTrue);
      expect(zip.contentOf(folder), isEmpty);
      expect(zip.files.map((e) => e.path), isNot(contains('empty/')));
    });

    test('stored and deflated entries both read', () {
      final zip = ZipArchive.read(fixture('python_mixed.zip'));
      expect(zip.entry('audio/jump.wav')!.method, 0);
      expect(zip.entry('sprites/hero/hero.json')!.method, 8);
    });
  });

  group('ZipWriter', () {
    Uint8List sample({bool reversed = false}) {
      final files = {
        'pubspec.yaml': utf8.encode('name: x\n'),
        'assets/a.txt': utf8.encode('hello ' * 50),
        'assets/noise.bin': List.generate(500, (i) => (i * 7919 + 13) & 0xFF),
      };
      final zip = ZipWriter();
      final keys = files.keys.toList();
      for (final k in reversed ? keys.reversed : keys) {
        zip.add(k, files[k]!);
      }
      return zip.close();
    }

    test('round trip', () {
      final zip = ZipArchive.read(sample());
      expect(zip.files.map((e) => e.path).toList(), [
        'assets/a.txt',
        'assets/noise.bin',
        'pubspec.yaml',
      ]);
      expect(
        utf8.decode(zip.contentOf(zip.entry('pubspec.yaml')!)),
        'name: x\n',
      );
      expect(zip.entry('assets/a.txt')!.method, 8, reason: 'text packs');
    });

    test('the same files give the same bytes, in any order', () {
      expect(sample(), sample(reversed: true));
      expect(Sha256.hexOf(sample()), Sha256.hexOf(sample(reversed: true)));
    });

    test('incompressible data is stored', () {
      final zip = ZipWriter()
        ..add('n.bin', List.generate(64, (i) => (i * 151 + 7) & 0xFF));
      expect(ZipArchive.read(zip.close()).entry('n.bin')!.method, 0);
    });

    test('records no time, and 0644 or 0755 as the only permissions', () {
      final entry = ZipArchive.read(sample()).entry('pubspec.yaml')!;
      expect(entry.modified, DateTime.utc(1980, 1, 1));
      expect(entry.unixMode, 0x81A4);
      expect(entry.isExecutable, isFalse);
    });

    test('executable files keep their x bits, reproducibly', () {
      Uint8List pack() =>
          (ZipWriter()
                ..add(
                  'tool/build.sh',
                  utf8.encode('#!/bin/sh\n'),
                  executable: true,
                )
                ..add('README.md', utf8.encode('hi')))
              .close();
      final zip = ZipArchive.read(pack());
      expect(zip.entry('tool/build.sh')!.unixMode, 0x81ED);
      expect(zip.entry('tool/build.sh')!.isExecutable, isTrue);
      expect(zip.entry('README.md')!.isExecutable, isFalse);
      expect(pack(), pack());
    });

    test('refuses unsafe paths, folders and case clashes', () {
      expect(() => ZipWriter().add('../x', [1]), throwsUnsafe);
      expect(() => ZipWriter().add('dir/', []), throwsArgumentError);
      final zip = ZipWriter()..add('Read.me', [1]);
      expect(() => zip.add('read.ME', [2]), throwsArgumentError);
    });

    test('refuses a path used as a file and as a folder', () {
      // The reader refuses these archives, so the writer must not make them.
      expect(
        () => ZipWriter()
          ..add('a', [1])
          ..add('a/b', [2]),
        throwsArgumentError,
      );
      expect(
        () => ZipWriter()
          ..add('Assets/x.png', [1])
          ..add('assets', [2]),
        throwsArgumentError,
      );
      expect(
        () => ZipWriter()
          ..add('sprites/hero', [1])
          ..add('Sprites/Hero/run.png', [2]),
        throwsArgumentError,
      );
      // Siblings and deeper files are fine.
      final ok = ZipWriter()
        ..add('a/b', [1])
        ..add('a/c/d', [2])
        ..add('ab', [3]);
      expect(ZipArchive.read(ok.close()).files, hasLength(3));
    });

    test('refuses a file of 4 GB or more', () {
      expect(() => ZipWriter().add('huge.bin', _Huge(0xFFFFFFFF)), throwsZip);
    });

    test('python reads what it writes', () async {
      final python = await _which('python');
      if (python == null) return;
      final dir = Directory.systemTemp.createTempSync('zipw');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/w.zip')..writeAsBytesSync(sample());
      final result = await Process.run(python, [
        '-c',
        'import zipfile,sys;z=zipfile.ZipFile(sys.argv[1]);'
            'print(z.testzip());'
            'print(z.read("pubspec.yaml").decode())',
        file.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect((result.stdout as String).split(RegExp(r'\r?\n')).take(2), [
        'None',
        'name: x',
      ]);
    });
  });

  group('refused paths', () {
    for (final name in [
      '../evil.txt',
      'a/../../evil.txt',
      '/etc/evil',
      'C:/evil.txt',
      r'..\evil.txt',
      'CON.txt',
      'sprites/aux',
      'trailing. ',
      'trailing.',
      'tab\there',
      'a//b.txt',
      './a.txt',
      'what?.txt',
    ]) {
      test(name.replaceAll('\t', r'\t'), () {
        expect(
          () => ZipArchive.read(
            rawZip([
              RawEntry(name, [1]),
            ]),
          ),
          throwsUnsafe,
        );
      });
    }

    // Control and invisible characters that could make a printed name pass
    // for another, or drive a terminal (0x9B is an 8-bit CSI).
    for (final unit in [
      0x80, 0x9B, 0x9F, 0x200B, 0x200E, 0x200F, 0x2028, 0x2029, //
      0x202A, 0x202E, 0x2066, 0x2069, 0xFEFF,
    ]) {
      test('U+${unit.toRadixString(16).toUpperCase()}', () {
        final name = 'invoice${String.fromCharCode(unit)}gnp.exe';
        expect(
          () => ZipArchive.read(
            rawZip([
              RawEntry(name, [1]),
            ]),
          ),
          throwsUnsafe,
        );
        expect(() => ZipWriter().add(name, [1]), throwsUnsafe);
        expect(
          () => SafePaths.check(name),
          throwsA(
            isA<UnsafePathException>().having(
              (e) => '$e'.contains(String.fromCharCode(unit)),
              'prints the raw character',
              isFalse,
            ),
          ),
        );
      });
    }

    test('ordinary accented and non-Latin names are fine', () {
      final names = [
        'caf${String.fromCharCode(0xE9)}.txt',
        '${String.fromCharCodes([0x30B2, 0x30FC, 0x30E0])}.json',
      ];
      for (final name in names) {
        expect(SafePaths.isSafe(name), isTrue, reason: name);
      }
    });

    test('a path over the length limit', () {
      expect(
        () => ZipArchive.read(
          rawZip([
            RawEntry('a' * 181, [1]),
          ]),
        ),
        throwsUnsafe,
      );
    });

    test(r'"\" between folders is read as "/"', () {
      final zip = ZipArchive.read(
        rawZip([
          RawEntry(r'sprites\hero.png', [1]),
        ]),
      );
      expect(zip.files.single.path, 'sprites/hero.png');
    });
  });

  group('refused archives', () {
    test('encrypted entries', () {
      expect(
        () => ZipArchive.read(
          rawZip([
            RawEntry('a', [1], flags: 0x0801),
          ]),
        ),
        throwsZip,
      );
    });

    test('unsupported compression', () {
      expect(
        () => ZipArchive.read(
          rawZip([
            RawEntry('a', [1], method: 12),
          ]),
        ),
        throwsZip,
      );
    });

    test('symbolic links', () {
      expect(
        () => ZipArchive.read(
          rawZip([
            RawEntry(
              'link',
              utf8.encode('/etc/passwd'),
              method: 0,
              madeBy: 0x0314,
              externalAttributes: unixAttributes(0xA1FF),
            ),
          ]),
        ),
        throwsZip,
      );
    });

    test('device files', () {
      expect(
        () => ZipArchive.read(
          rawZip([
            RawEntry(
              'dev',
              [],
              method: 0,
              madeBy: 0x0314,
              externalAttributes: unixAttributes(0x21A4),
            ),
          ]),
        ),
        throwsZip,
      );
    });

    test('ordinary Unix permissions are fine', () {
      final zip = ZipArchive.read(
        rawZip([
          RawEntry(
            'run.sh',
            [1],
            madeBy: 0x0314,
            externalAttributes: unixAttributes(0x81ED),
          ),
        ]),
      );
      expect(zip.files.single.unixMode, 0x81ED);
    });

    test('names that clash on Windows and macOS', () {
      expect(
        () => ZipArchive.read(
          rawZip([
            RawEntry('Hero.png', [1]),
            RawEntry('hero.PNG', [2]),
          ]),
        ),
        throwsZip,
      );
      expect(
        () => ZipArchive.read(
          rawZip([
            RawEntry('a', [1]),
            RawEntry('a', [2]),
          ]),
        ),
        throwsZip,
      );
    });

    test('names that are one file once macOS normalises them', () {
      // "café" composed (U+00E9) and decomposed (e + U+0301): APFS and HFS+
      // treat them as one name. Accents are folded on purpose, so plain
      // "cafe" counts as the same name too.
      final composed = 'caf${String.fromCharCode(0xE9)}.txt';
      final decomposed = 'cafe${String.fromCharCode(0x301)}.txt';
      for (final (a, b) in [
        (composed, decomposed),
        (composed, 'CAFE.txt'),
        ('${String.fromCharCode(0xC9)}t${String.fromCharCode(0xE9)}/a', 'ete'),
      ]) {
        expect(
          () => ZipArchive.read(
            rawZip([
              RawEntry(a, [1]),
              RawEntry(b, [2]),
            ]),
          ),
          throwsZip,
          reason: '$a / $b',
        );
        expect(
          () => ZipWriter()
            ..add(a, [1])
            ..add(b, [2]),
          throwsArgumentError,
          reason: '$a / $b',
        );
      }
      expect(SafePaths.caseKey(composed), SafePaths.caseKey(decomposed));
    });

    test('a central directory holding more records than it counts', () {
      // Python's zipfile walks the whole directory and would see hidden.txt;
      // this reader must not unpack an archive the two see differently.
      final zip = rawZip([
        RawEntry('visible.txt', utf8.encode('hello')),
        RawEntry('hidden.txt', utf8.encode('surprise')),
      ], count: 1);
      expect(() => ZipArchive.read(zip), throwsZip);
    });

    test('a file that other entries use as a folder', () {
      expect(
        () => ZipArchive.read(
          rawZip([
            RawEntry('a', [1]),
            RawEntry('a/b', [2]),
          ]),
        ),
        throwsZip,
      );
    });

    test('a folder entry with data', () {
      expect(
        () => ZipArchive.read(
          rawZip([
            RawEntry('dir/', [1], method: 0),
          ]),
        ),
        throwsZip,
      );
    });

    test('a local header naming another file', () {
      expect(
        () => ZipArchive.read(
          rawZip([
            RawEntry('a.txt', [1], localName: 'b.txt'),
          ]),
        ),
        throwsZip,
      );
    });

    test('entries whose data overlaps', () {
      // b.txt's whole local record, hidden inside a.txt's stored data, with
      // the central directory pointing at it: the overlapping-file trick
      // behind non-recursive zip bombs.
      final inner = rawZip([
        RawEntry('b.txt', utf8.encode('x' * 40), method: 0),
      ]);
      final record = inner.sublist(0, 30 + 5 + 40);
      final zip = rawZip([
        RawEntry('a.txt', record, method: 0),
        RawEntry('b.txt', utf8.encode('x' * 40), method: 0, offset: 30 + 5),
      ]);
      expect(() => ZipArchive.read(zip), throwsZip);
    });

    test('a decompression bomb', () {
      final bomb = rawZip([RawEntry('zeros.bin', Uint8List(4 * 1024 * 1024))]);
      expect(() => ZipArchive.read(bomb), throwsZip);
      // Small, repetitive files are fine.
      expect(
        ZipArchive.read(
          rawZip([RawEntry('z.json', Uint8List(100000))]),
        ).files.single.size,
        100000,
      );
    });

    test('limits on entries, file size and total size', () {
      final three = rawZip([
        RawEntry('a', [1, 2, 3]),
        RawEntry('b', [1, 2, 3]),
        RawEntry('c', [1, 2, 3]),
      ]);
      expect(
        () => ZipArchive.read(three, limits: const ZipLimits(maxEntries: 2)),
        throwsZip,
      );
      expect(
        () => ZipArchive.read(three, limits: const ZipLimits(maxEntryBytes: 2)),
        throwsZip,
      );
      expect(
        () => ZipArchive.read(three, limits: const ZipLimits(maxTotalBytes: 8)),
        throwsZip,
      );
      expect(ZipArchive.read(three).totalSize, 9);
    });

    test('ZIP64 and split archives', () {
      expect(
        () => ZipArchive.read(
          rawZip([
            RawEntry('a', [1]),
          ], count: 0xFFFF),
        ),
        throwsZip,
      );
      expect(
        () => ZipArchive.read(
          rawZip([
            RawEntry('a', [1]),
          ], zip64Locator: true),
        ),
        throwsZip,
      );
      expect(
        () => ZipArchive.read(
          rawZip([
            RawEntry('a', [1]),
          ], disk: 1),
        ),
        throwsZip,
      );
      expect(
        () => ZipArchive.read(
          rawZip([
            RawEntry('a', [1], startDisk: 1),
          ]),
        ),
        throwsZip,
      );
    });

    test('not a ZIP, cut short, or with trailing bytes', () {
      expect(() => ZipArchive.read(Uint8List(10)), throwsZip);
      expect(
        () => ZipArchive.read(Uint8List.fromList(utf8.encode('x' * 200))),
        throwsZip,
      );
      final good = rawZip([RawEntry('a.txt', utf8.encode('hello'))]);
      expect(
        () => ZipArchive.read(Uint8List.sublistView(good, 0, good.length - 5)),
        throwsZip,
      );
      expect(
        () => ZipArchive.read(Uint8List.fromList([...good, 1, 2, 3])),
        throwsZip,
      );
      expect(
        () => ZipArchive.read(
          rawZip([
            RawEntry('a', [1]),
          ], cdOffset: 9999),
        ),
        throwsZip,
      );
    });

    test('an archive comment is fine', () {
      final zip = rawZip([
        RawEntry('a', [1]),
      ], comment: 'hi there');
      expect(ZipArchive.read(zip).files.single.path, 'a');
    });
  });

  group('damaged data', () {
    test('a wrong CRC-32', () {
      final zip = ZipArchive.read(
        rawZip([RawEntry('a.txt', utf8.encode('hello'), crc: 1234)]),
      );
      expect(() => zip.contentOf(zip.files.single), throwsZip);
    });

    test('a size that is too small or too large', () {
      final small = ZipArchive.read(
        rawZip([RawEntry('a.txt', utf8.encode('hello world'), size: 5)]),
      );
      expect(() => small.contentOf(small.files.single), throwsZip);
      final large = ZipArchive.read(
        rawZip([RawEntry('a.txt', utf8.encode('hello world'), size: 50)]),
      );
      expect(() => large.contentOf(large.files.single), throwsZip);
      final stored = ZipArchive.read(
        rawZip([RawEntry('a.txt', utf8.encode('hello'), method: 0, size: 6)]),
      );
      expect(() => stored.contentOf(stored.files.single), throwsZip);
    });

    test('corrupt DEFLATE data', () {
      final bytes = rawZip([RawEntry('a.txt', utf8.encode('hello ' * 100))]);
      // Flip bits in the compressed body (after the 30 + 5 byte header).
      for (var i = 36; i < 44; i++) {
        bytes[i] ^= 0xFF;
      }
      final zip = ZipArchive.read(bytes);
      expect(() => zip.contentOf(zip.files.single), throwsZip);
    });
  });
}

/// A list that only claims to be [length] long, to test size limits
/// without allocating them.
class _Huge extends ListBase<int> {
  _Huge(this.length);

  @override
  int length;

  @override
  int operator [](int index) => 0;

  @override
  void operator []=(int index, int value) {}
}

Future<String?> _which(String tool) async {
  try {
    final r = await Process.run(tool, ['--version']);
    return r.exitCode == 0 ? tool : null;
  } on ProcessException {
    return null;
  }
}

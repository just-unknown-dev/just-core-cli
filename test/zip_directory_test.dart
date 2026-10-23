// ZipDirectory: an archive's directory read from its end alone (as a store
// backend reads one on a server, with HTTP ranges), checked by the same
// rules as ZipArchive.read.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_core_cli/fetch.dart';
import 'package:test/test.dart';

import 'support/raw_zip.dart';

Uint8List fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

/// Reads [bytes] in ranges, as a server would, keeping each request.
final class Ranges {
  Ranges(this.bytes);

  final Uint8List bytes;
  final List<(int, int)> requests = [];

  Future<Uint8List> read(int start, int end) async {
    requests.add((start, end));
    return Uint8List.sublistView(bytes, start, end);
  }
}

List<Object?> summary(Iterable<ZipEntry> entries) => [
  for (final e in entries)
    (
      e.path,
      e.isDirectory,
      e.size,
      e.compressedSize,
      e.crc32,
      e.method,
      e.unixMode,
      e.modified,
    ),
];

/// Every entry as ZipDirectory sees it through [Ranges], and every file's
/// bytes, which must be what ZipArchive reads.
Future<void> expectSameAsArchive(Uint8List bytes) async {
  final zip = ZipArchive.read(bytes);
  final ranges = Ranges(bytes);
  final dir = await ZipDirectory.fetch(ranges.read, bytes.length);
  expect(summary(dir.entries), summary(zip.entries));
  expect(dir.totalSize, zip.totalSize);
  for (final f in zip.files) {
    expect(
      await dir.readContent(dir.entry(f.path)!, ranges.read),
      zip.contentOf(f),
      reason: f.path,
    );
  }
}

/// Refused by both readers, with the same kind of error.
void expectBothRefuse(Uint8List bytes, TypeMatcher<Object> error) {
  expect(() => ZipArchive.read(bytes), throwsA(error));
  expect(
    () => ZipDirectory.fromTail(bytes, totalLength: bytes.length),
    throwsA(error),
  );
}

void main() {
  final zipError = isA<ZipFormatException>();

  group('reads what ZipArchive reads', () {
    for (final file in [
      'python_mixed.zip',
      'python_streamed.zip',
      'powershell.zip',
      'git_archive.zip',
    ]) {
      test(file, () => expectSameAsArchive(fixture(file)));
    }

    test('an archive ZipWriter made', () async {
      final writer = ZipWriter()
        ..add('pubspec.yaml', utf8.encode('name: x\n'))
        ..add('just_store.json', utf8.encode('{"id": "x"}'))
        ..add('tool/run.sh', utf8.encode('echo hi\n'), executable: true)
        ..add('assets/noise.bin', [
          for (var i = 0; i < 5000; i++) (i * 7919 + 13) & 0xFF,
        ]);
      await expectSameAsArchive(writer.close());
    });

    test('an archive with a comment', () async {
      await expectSameAsArchive(
        rawZip([
          RawEntry('a.txt', utf8.encode('hello ' * 30)),
        ], comment: 'made by a test'),
      );
    });
  });

  group('fetching', () {
    test('a small archive takes one request: all of it', () async {
      final bytes = fixture('python_mixed.zip');
      final ranges = Ranges(bytes);
      await ZipDirectory.fetch(ranges.read, bytes.length);
      expect(ranges.requests, [(0, bytes.length)]);
    });

    Uint8List manyFiles() {
      final writer = ZipWriter();
      for (var i = 0; i < 1500; i++) {
        writer.add(
          'assets/a_rather_long_folder_name/file_number_$i.txt',
          utf8.encode('$i'),
        );
      }
      return writer.close();
    }

    test('a directory that starts before the end takes a second', () async {
      final bytes = manyFiles();
      expect(bytes.length, greaterThan(ZipDirectory.tailBytes * 2));
      final ranges = Ranges(bytes);
      final dir = await ZipDirectory.fetch(ranges.read, bytes.length);
      expect(dir.files.length, 1500);
      expect(ranges.requests, hasLength(2));
      expect(ranges.requests.first.$2, bytes.length);
      expect(ranges.requests.last.$2, ranges.requests.first.$1);
      // Far less than the whole archive.
      final read = ranges.requests.fold(0, (n, r) => n + r.$2 - r.$1);
      expect(read, lessThan(bytes.length));
      final file = dir.entry(
        'assets/a_rather_long_folder_name/file_number_7.txt',
      )!;
      expect(utf8.decode(await dir.readContent(file, ranges.read)), '7');
    });

    test('a directory larger than allowed is refused', () {
      final bytes = manyFiles();
      expect(
        ZipDirectory.fetch(
          Ranges(bytes).read,
          bytes.length,
          maxDirectoryBytes: 1024,
        ),
        throwsA(zipError),
      );
    });

    test('a read that gives the wrong number of bytes is refused', () {
      final bytes = fixture('python_mixed.zip');
      expect(
        ZipDirectory.fetch(
          (s, e) async => Uint8List.sublistView(bytes, s, e - 1),
          bytes.length,
        ),
        throwsA(zipError),
      );
    });

    test('too short a tail says which bytes it needs', () {
      final bytes = manyFiles();
      final tail = Uint8List.sublistView(bytes, bytes.length - 100);
      expect(
        () => ZipDirectory.fromTail(tail, totalLength: bytes.length),
        throwsA(
          isA<ZipNeedsBytes>().having(
            (e) => e.start,
            'start',
            lessThan(bytes.length - 100),
          ),
        ),
      );
    });
  });

  group('refuses, as ZipArchive does', () {
    test('a path that climbs out', () {
      expectBothRefuse(
        rawZip([
          RawEntry('../evil.txt', [1]),
        ]),
        isA<UnsafePathException>(),
      );
    });

    test('encryption, symbolic links and unknown compression', () {
      expectBothRefuse(
        rawZip([
          RawEntry('a', [1], flags: 0x0801),
        ]),
        zipError,
      );
      expectBothRefuse(
        rawZip([
          RawEntry(
            'link',
            utf8.encode('/etc/passwd'),
            madeBy: 3 << 8,
            externalAttributes: unixAttributes(0xA1FF),
          ),
        ]),
        zipError,
      );
      expectBothRefuse(
        rawZip([
          RawEntry('a', [1], method: 12),
        ]),
        zipError,
      );
    });

    test('more records than the end record counts', () {
      expectBothRefuse(
        rawZip([
          RawEntry('visible.txt', utf8.encode('hello')),
          RawEntry('hidden.txt', utf8.encode('surprise')),
        ], count: 1),
        zipError,
      );
    });

    test('ZIP64, split archives, names that clash', () {
      expectBothRefuse(
        rawZip([
          RawEntry('a', [1]),
        ], zip64Locator: true),
        zipError,
      );
      expectBothRefuse(
        rawZip([
          RawEntry('a', [1]),
        ], disk: 1),
        zipError,
      );
      expectBothRefuse(
        rawZip([
          RawEntry('Read.me', [1]),
          RawEntry('read.ME', [2]),
        ]),
        zipError,
      );
    });

    test('overlapping data, by the least room each entry takes', () {
      final inner = rawZip([
        RawEntry('b.txt', utf8.encode('x' * 40), method: 0),
      ]);
      final record = inner.sublist(0, 30 + 5 + 40);
      expectBothRefuse(
        rawZip([
          RawEntry('a.txt', record, method: 0),
          RawEntry('b.txt', utf8.encode('x' * 40), method: 0, offset: 30 + 5),
        ]),
        zipError,
      );
    });

    test('a bomb and the size limits', () {
      expectBothRefuse(
        rawZip([RawEntry('zeros.bin', Uint8List(4 * 1024 * 1024))]),
        zipError,
      );
    });
  });

  group('unpacking one file', () {
    test('a local header naming another file is refused', () async {
      final bytes = rawZip([
        RawEntry('a.txt', [1], localName: 'b.txt'),
      ]);
      final ranges = Ranges(bytes);
      // The directory alone can't tell…
      final dir = await ZipDirectory.fetch(ranges.read, bytes.length);
      // …but the file's own header can.
      expect(
        dir.readContent(dir.entry('a.txt')!, ranges.read),
        throwsA(zipError),
      );
    });

    test('a damaged CRC-32 is refused', () async {
      final bytes = rawZip([
        RawEntry('a.txt', utf8.encode('hello'), crc: 1234),
      ]);
      final ranges = Ranges(bytes);
      final dir = await ZipDirectory.fetch(ranges.read, bytes.length);
      expect(
        dir.readContent(dir.entry('a.txt')!, ranges.read),
        throwsA(zipError),
      );
    });

    test('bytes that end too soon say which are needed', () async {
      final bytes = rawZip([
        RawEntry('a.txt', utf8.encode('hello ' * 100)),
      ]);
      final dir = await ZipDirectory.fetch(Ranges(bytes).read, bytes.length);
      final entry = dir.entry('a.txt')!;
      final span = dir.spanOf(entry);
      final header = Uint8List.sublistView(bytes, span.start, span.start + 40);
      expect(
        () => dir.contentFrom(entry, header, start: span.start),
        throwsA(
          isA<ZipNeedsBytes>().having(
            (e) => e.end,
            'end',
            30 + 5 + entry.compressedSize,
          ),
        ),
      );
      final whole = Uint8List.sublistView(bytes, span.start, span.end);
      expect(
        utf8.decode(dir.contentFrom(entry, whole, start: span.start)),
        'hello ' * 100,
      );
    });

    test('folders unpack to nothing', () async {
      final bytes = fixture('python_mixed.zip');
      final ranges = Ranges(bytes);
      final dir = await ZipDirectory.fetch(ranges.read, bytes.length);
      final folder = dir.entries.firstWhere((e) => e.isDirectory);
      expect(await dir.readContent(folder, ranges.read), isEmpty);
    });
  });
}

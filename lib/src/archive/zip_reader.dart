/// Reading ZIP archives (PKWARE APPNOTE 6.3) from untrusted sources.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:just_deflate/just_deflate.dart';

import 'safe_paths.dart';

/// A ZIP archive that is damaged, uses something this reader refuses, or
/// breaks one of its [ZipLimits].
final class ZipFormatException implements Exception {
  /// [message] about the archive, or about the entry at [path].
  const ZipFormatException(this.message, {this.path});

  /// What is wrong, in a sentence.
  final String message;

  /// The entry it concerns, if one.
  final String? path;

  @override
  String toString() => path == null
      ? 'ZipFormatException: $message'
      : 'ZipFormatException: "$path": $message';
}

/// How much an archive may hold before [ZipArchive.read] refuses it.
///
/// The defaults suit packages of assets: generous for art and sound, far below
/// what a decompression bomb would expand to.
final class ZipLimits {
  /// The default limits.
  const ZipLimits({
    this.maxEntries = 20000,
    this.maxEntryBytes = 64 * 1024 * 1024,
    this.maxTotalBytes = 512 * 1024 * 1024,
    this.maxRatio = 200,
    this.ratioCheckAbove = 1024 * 1024,
  });

  /// Files and folders together.
  final int maxEntries;

  /// The largest one file may unpack to, in bytes.
  final int maxEntryBytes;

  /// The most all files together may unpack to, in bytes.
  final int maxTotalBytes;

  /// How many times larger than its packed size a file may unpack to.
  final int maxRatio;

  /// Files that unpack to at most this many bytes skip the [maxRatio]
  /// check: small, repetitive JSON legitimately packs very well.
  final int ratioCheckAbove;
}

/// One file or folder in a [ZipArchive].
final class ZipEntry {
  ZipEntry._(
    this._dataOffset, {
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.compressedSize,
    required this.crc32,
    required this.method,
    required this.modified,
    required this.unixMode,
  });

  /// The entry's path inside the archive, checked by [SafePaths]. Folders
  /// end in `/`.
  final String path;

  /// Whether this is a folder rather than a file.
  final bool isDirectory;

  /// The unpacked size in bytes.
  final int size;

  /// The packed size in bytes.
  final int compressedSize;

  /// The CRC-32 the archive records for the unpacked bytes.
  final int crc32;

  /// 0 for stored, 8 for DEFLATE.
  final int method;

  /// The modification time recorded, read as UTC (ZIP stores no zone).
  final DateTime modified;

  /// The Unix file type and permission bits (`st_mode`, such as `0100755`),
  /// when the archive was made on Unix or by `ZipWriter`.
  final int? unixMode;

  /// Whether this is a file whose [unixMode] lets anyone execute it, so an
  /// extractor on Linux or macOS should mark it executable too.
  bool get isExecutable =>
      !isDirectory && unixMode != null && unixMode! & 0x49 != 0; // 0o111

  final int _dataOffset;

  @override
  String toString() => 'ZipEntry($path, $size bytes)';
}

/// A ZIP archive read fully into memory and checked before any file in it
/// is unpacked.
///
/// [read] refuses archives a tool should never unpack:
/// - encrypted entries, compression other than stored or DEFLATE, ZIP64,
///   and archives split across disks;
/// - symbolic links and other special files;
/// - paths [SafePaths] rejects (after reading `\` as `/`, as old Windows
///   tools wrote it), and two entries a case-insensitive or normalising file
///   system could see as one ([SafePaths.caseKey]);
/// - a central directory holding records its end record doesn't count;
/// - entries whose data overlaps (a known decompression-bomb trick), or
///   that break the [ZipLimits].
///
/// [contentOf] unpacks one file and checks its size and CRC-32.
final class ZipArchive {
  ZipArchive._(this._bytes, this.entries);

  /// Parses and checks [bytes]. Throws [ZipFormatException] or
  /// [UnsafePathException].
  factory ZipArchive.read(
    Uint8List bytes, {
    ZipLimits limits = const ZipLimits(),
  }) {
    final reader = _Reader(bytes);
    final end = _findEnd(reader);
    final disk = reader.u16(end + 4);
    final cdDisk = reader.u16(end + 6);
    final onDisk = reader.u16(end + 8);
    final count = reader.u16(end + 10);
    final cdSize = reader.u32(end + 12);
    final cdOffset = reader.u32(end + 16);
    if (count == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF) {
      throw const ZipFormatException('ZIP64 archives are not supported.');
    }
    if (end >= 20 && reader.u32(end - 20) == _zip64Locator) {
      throw const ZipFormatException('ZIP64 archives are not supported.');
    }
    if (disk != 0 || cdDisk != 0 || onDisk != count) {
      throw const ZipFormatException(
        'Archives split across several files are not supported.',
      );
    }
    if (count > limits.maxEntries) {
      throw ZipFormatException(
        'It holds $count entries; at most ${limits.maxEntries} are allowed.',
      );
    }
    if (cdOffset + cdSize > end) {
      throw const ZipFormatException('The central directory is damaged.');
    }

    final entries = <ZipEntry>[];
    final seen = <String, String>{};
    final folders = <String>{};
    final spans = <(int, int, String)>[];
    var total = 0;
    var at = cdOffset;
    for (var i = 0; i < count; i++) {
      if (at + 46 > cdOffset + cdSize || reader.u32(at) != _central) {
        throw const ZipFormatException('The central directory is damaged.');
      }
      final madeBy = reader.u16(at + 4);
      final flags = reader.u16(at + 8);
      final method = reader.u16(at + 10);
      final time = reader.u16(at + 12);
      final date = reader.u16(at + 14);
      final crc = reader.u32(at + 16);
      final packed = reader.u32(at + 20);
      final size = reader.u32(at + 24);
      final nameLength = reader.u16(at + 28);
      final extraLength = reader.u16(at + 30);
      final commentLength = reader.u16(at + 32);
      final startDisk = reader.u16(at + 34);
      final external = reader.u32(at + 38);
      final localOffset = reader.u32(at + 42);
      final nameBytes = reader.slice(at + 46, nameLength);
      at += 46 + nameLength + extraLength + commentLength;
      if (at > cdOffset + cdSize) {
        throw const ZipFormatException('The central directory is damaged.');
      }

      // Older Windows tools wrote "\" between folders; read it as "/" so the
      // checks below see (and refuse) a "..\" climb like any other.
      final path = _decodeName(nameBytes).replaceAll(r'\', '/');
      SafePaths.check(path);
      if (flags & 0x0041 != 0 || method == 99) {
        throw ZipFormatException(
          'Encrypted entries are not supported.',
          path: path,
        );
      }
      if (method != 0 && method != 8) {
        throw ZipFormatException(
          'Compression method $method is not supported '
          '(only stored and DEFLATE).',
          path: path,
        );
      }
      if (startDisk != 0) {
        throw ZipFormatException(
          'The entry starts on another disk.',
          path: path,
        );
      }
      if (size == 0xFFFFFFFF || packed == 0xFFFFFFFF) {
        throw ZipFormatException(
          'ZIP64 entries are not supported.',
          path: path,
        );
      }

      final host = madeBy >> 8;
      final mode = host == 3 ? (external >>> 16) & 0xFFFF : null;
      final isDirectory = path.endsWith('/');
      if (mode != null && mode != 0) {
        final type = mode & 0xF000;
        if (type == 0xA000) {
          throw ZipFormatException(
            'Symbolic links are not allowed.',
            path: path,
          );
        }
        if (type != 0 && type != 0x8000 && type != 0x4000) {
          throw ZipFormatException(
            'Special files are not allowed.',
            path: path,
          );
        }
      }
      if (isDirectory && size != 0) {
        throw ZipFormatException('A folder entry holds data.', path: path);
      }

      final key = SafePaths.caseKey(
        isDirectory ? path.substring(0, path.length - 1) : path,
      );
      final clash = seen[key];
      if (clash != null) {
        throw ZipFormatException(
          'It and "$clash" could be the same file on Windows or macOS.',
          path: path,
        );
      }
      seen[key] = path;
      final parts = key.split('/');
      for (var p = 1; p < parts.length; p++) {
        folders.add(parts.take(p).join('/'));
      }

      if (size > limits.maxEntryBytes) {
        throw ZipFormatException(
          'It unpacks to $size bytes; at most ${limits.maxEntryBytes} '
          'are allowed for one file.',
          path: path,
        );
      }
      total += size;
      if (total > limits.maxTotalBytes) {
        throw ZipFormatException(
          'It unpacks to more than ${limits.maxTotalBytes} bytes.',
        );
      }
      if (size > limits.ratioCheckAbove &&
          size > (packed == 0 ? 1 : packed) * limits.maxRatio) {
        throw ZipFormatException(
          'It unpacks to more than ${limits.maxRatio} times its packed '
          'size.',
          path: path,
        );
      }

      // The local header must agree with the central directory.
      if (localOffset + 30 > cdOffset || reader.u32(localOffset) != _local) {
        throw ZipFormatException(
          'Its local header is missing or damaged.',
          path: path,
        );
      }
      final localFlags = reader.u16(localOffset + 6);
      final localMethod = reader.u16(localOffset + 8);
      final localName = reader.u16(localOffset + 26);
      final localExtra = reader.u16(localOffset + 28);
      if (localMethod != method || (localFlags & 0x0041) != 0) {
        throw ZipFormatException(
          'Its local header disagrees with the central directory.',
          path: path,
        );
      }
      final localNameBytes = reader.slice(localOffset + 30, localName);
      if (!_sameBytes(localNameBytes, nameBytes)) {
        throw ZipFormatException(
          'Its local header names a different file.',
          path: path,
        );
      }
      final dataOffset = localOffset + 30 + localName + localExtra;
      final dataEnd = dataOffset + packed;
      if (dataEnd > cdOffset) {
        throw ZipFormatException('Its data runs past the end.', path: path);
      }
      spans.add((localOffset, dataEnd, path));

      entries.add(
        ZipEntry._(
          dataOffset,
          path: path,
          isDirectory: isDirectory,
          size: size,
          compressedSize: packed,
          crc32: crc,
          method: method,
          modified: _dosTime(date, time),
          unixMode: mode,
        ),
      );
    }
    // Every record must be one the end record counted: a reader that walks
    // the whole directory instead would see files this one never checked.
    if (at != cdOffset + cdSize) {
      throw ZipFormatException(
        'The central directory holds more than the $count entries its end '
        'record lists.',
      );
    }

    for (final entry in entries) {
      if (entry.isDirectory) continue;
      final key = SafePaths.caseKey(entry.path);
      if (folders.contains(key)) {
        throw ZipFormatException(
          'It is a file, but other entries use it as a folder.',
          path: entry.path,
        );
      }
    }

    spans.sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 1; i < spans.length; i++) {
      if (spans[i].$1 < spans[i - 1].$2) {
        throw ZipFormatException(
          'Its data overlaps "${spans[i - 1].$3}".',
          path: spans[i].$3,
        );
      }
    }

    return ZipArchive._(bytes, List.unmodifiable(entries));
  }

  final Uint8List _bytes;

  /// Every entry, files and folders, in the archive's order.
  final List<ZipEntry> entries;

  /// The file entries only.
  Iterable<ZipEntry> get files => entries.where((e) => !e.isDirectory);

  /// The total unpacked size of every file, in bytes.
  int get totalSize => files.fold(0, (sum, e) => sum + e.size);

  /// The entry at [path], or null.
  ZipEntry? entry(String path) {
    for (final e in entries) {
      if (e.path == path) return e;
    }
    return null;
  }

  /// The unpacked bytes of [entry], checked against its size and CRC-32.
  ///
  /// Throws [ZipFormatException] when they don't match.
  Uint8List contentOf(ZipEntry entry) {
    if (entry.isDirectory) return Uint8List(0);
    final packed = Uint8List.sublistView(
      _bytes,
      entry._dataOffset,
      entry._dataOffset + entry.compressedSize,
    );
    final Uint8List data;
    if (entry.method == 0) {
      if (entry.compressedSize != entry.size) {
        throw ZipFormatException('Its stored size is wrong.', path: entry.path);
      }
      data = Uint8List.fromList(packed);
    } else {
      try {
        data = const DeflateCodec().decode(packed, maxOutputSize: entry.size);
      } on FormatException catch (e) {
        throw ZipFormatException(
          'Its data is damaged: ${e.message}',
          path: entry.path,
        );
      }
    }
    if (data.length != entry.size) {
      throw ZipFormatException(
        'It unpacked to ${data.length} bytes, not ${entry.size}.',
        path: entry.path,
      );
    }
    if (crc32(data) != entry.crc32) {
      throw ZipFormatException(
        'Its CRC-32 does not match: the data is damaged.',
        path: entry.path,
      );
    }
    return data;
  }

  /// Every file unpacked, by path. Folders are left out.
  Map<String, Uint8List> extractAll() => {
    for (final e in files) e.path: contentOf(e),
  };
}

const int _local = 0x04034b50;
const int _central = 0x02014b50;
const int _end = 0x06054b50;
const int _zip64Locator = 0x07064b50;

int _findEnd(_Reader reader) {
  final length = reader.length;
  if (length < 22) {
    throw const ZipFormatException('It is not a ZIP archive.');
  }
  final stop = length - 22 - 0xFFFF;
  for (var at = length - 22; at >= 0 && at >= stop; at--) {
    if (reader.u32(at) != _end) continue;
    final comment = reader.u16(at + 20);
    if (at + 22 + comment == length) return at;
  }
  throw const ZipFormatException('It is not a ZIP archive.');
}

String _decodeName(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw ZipFormatException(
      'A file name is not valid UTF-8 '
      '(${bytes.map((b) => b.toRadixString(16)).join(' ')}).',
    );
  }
}

DateTime _dosTime(int date, int time) {
  final year = 1980 + ((date >> 9) & 0x7F);
  final month = ((date >> 5) & 0xF).clamp(1, 12);
  final day = (date & 0x1F).clamp(1, 31);
  return DateTime.utc(
    year,
    month,
    day,
    (time >> 11) & 0x1F,
    (time >> 5) & 0x3F,
    (time & 0x1F) * 2,
  );
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

final class _Reader {
  _Reader(this.bytes) : length = bytes.length;

  final Uint8List bytes;
  final int length;

  void _need(int at, int count) {
    if (at < 0 || at + count > length) {
      throw const ZipFormatException('The archive is cut short.');
    }
  }

  int u16(int at) {
    _need(at, 2);
    return bytes[at] | (bytes[at + 1] << 8);
  }

  int u32(int at) {
    _need(at, 4);
    return (bytes[at] |
            (bytes[at + 1] << 8) |
            (bytes[at + 2] << 16) |
            (bytes[at + 3] << 24)) >>>
        0;
  }

  Uint8List slice(int at, int count) {
    _need(at, count);
    return Uint8List.sublistView(bytes, at, at + count);
  }
}

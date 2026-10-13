/// Writing ZIP archives that are byte-for-byte reproducible.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:just_deflate/just_deflate.dart';

import 'safe_paths.dart';
import 'zip_reader.dart' show ZipFormatException;

/// Builds a ZIP archive whose bytes depend only on its files' paths and
/// contents.
///
/// Entries are sorted by path, every timestamp is 1980-01-01 00:00, names
/// are flagged UTF-8, every file is recorded as Unix mode `0100644` (or
/// `0100755` when added as executable), and each file is stored or
/// DEFLATE-compressed, whichever is smaller. So packing the same folder
/// twice — on any platform — gives the same SHA-256, which is what lets a
/// catalog pin it.
///
/// It refuses what `ZipArchive.read` would refuse: unsafe paths, two
/// paths one file system could see as one ([SafePaths.caseKey]), and a
/// path used both as a file and as a folder.
///
/// ```dart
/// final zip = ZipWriter()
///   ..add('pubspec.yaml', pubspec)
///   ..add('tool/build.sh', script, executable: true)
///   ..add('assets/knight.png', png);
/// final bytes = zip.close();
/// ```
final class ZipWriter {
  /// A writer that compresses at [level] (0-9).
  ZipWriter({this.level = 6});

  /// The DEFLATE level files are compressed at.
  final int level;

  final Map<String, (List<int>, bool)> _files = {};
  // Case keys of the files added, and of the folders they imply (each with
  // one file inside it, for messages).
  final Map<String, String> _keys = {};
  final Map<String, String> _folders = {};
  bool _closed = false;

  /// Adds a file at [path] (checked by [SafePaths]) holding [bytes];
  /// [executable] records it as runnable on Linux and macOS.
  ///
  /// Throws [ArgumentError] if a path that a case-insensitive file system
  /// would see as the same file was added before, or if this file and
  /// another would need one path to be both a file and a folder. Throws
  /// [ZipFormatException] for a file of 4 GB or more, which needs ZIP64.
  void add(String path, List<int> bytes, {bool executable = false}) {
    if (_closed) throw StateError('The archive is closed.');
    SafePaths.check(path);
    if (path.endsWith('/')) {
      throw ArgumentError.value(path, 'path', 'Folders are implied by files.');
    }
    if (bytes.length >= 0xFFFFFFFF) {
      throw ZipFormatException('Files of 4 GB or more need ZIP64.', path: path);
    }
    final key = SafePaths.caseKey(path);
    final clash = _keys[key];
    if (clash != null) {
      throw ArgumentError.value(path, 'path', 'Already added as "$clash".');
    }
    final inside = _folders[key];
    if (inside != null) {
      throw ArgumentError.value(
        path,
        'path',
        'It is already a folder, holding "$inside".',
      );
    }
    final parts = key.split('/');
    final folders = [
      for (var p = 1; p < parts.length; p++) parts.take(p).join('/'),
    ];
    for (final folder in folders) {
      final file = _keys[folder];
      if (file != null) {
        throw ArgumentError.value(
          path,
          'path',
          '"$file" was added as a file, so it can\'t be a folder.',
        );
      }
    }
    _keys[key] = path;
    for (final folder in folders) {
      _folders.putIfAbsent(folder, () => path);
    }
    _files[path] = (bytes, executable);
  }

  /// The archive's bytes. The writer takes no more files.
  Uint8List close() {
    if (_closed) throw StateError('The archive is closed.');
    _closed = true;
    if (_files.length > 0xFFFF) {
      throw const ZipFormatException('More than 65535 files need ZIP64.');
    }
    final paths = _files.keys.toList()..sort();
    final out = BytesBuilder(copy: false);
    final central = BytesBuilder(copy: false);
    final deflate = DeflateCodec(level: level);
    var offset = 0;
    for (final path in paths) {
      final (data, executable) = _files[path]!;
      final mode = executable ? _executableMode : _fileMode;
      final name = utf8.encode(path);
      final crc = crc32(data);
      final compressed = deflate.encode(data);
      final useDeflate = compressed.length < data.length;
      final body = useDeflate ? compressed : Uint8List.fromList(data);
      final method = useDeflate ? 8 : 0;
      final needs = useDeflate ? 20 : 10;
      if (offset > 0xFFFFFFFF - 30 - name.length - body.length) {
        throw const ZipFormatException('Archives over 4 GB need ZIP64.');
      }

      final local = _Writer()
        ..u32(0x04034b50)
        ..u16(needs)
        ..u16(_utf8Flag)
        ..u16(method)
        ..u16(_time)
        ..u16(_date)
        ..u32(crc)
        ..u32(body.length)
        ..u32(data.length)
        ..u16(name.length)
        ..u16(0)
        ..bytes(name);
      out
        ..add(local.take())
        ..add(body);

      central.add(
        (_Writer()
              ..u32(0x02014b50)
              ..u16(_madeByUnix) // so readers take the mode below
              ..u16(needs)
              ..u16(_utf8Flag)
              ..u16(method)
              ..u16(_time)
              ..u16(_date)
              ..u32(crc)
              ..u32(body.length)
              ..u32(data.length)
              ..u16(name.length)
              ..u16(0) // extra
              ..u16(0) // comment
              ..u16(0) // disk
              ..u16(0) // internal attributes
              ..u32(mode << 16) // external attributes: the Unix mode
              ..u32(offset)
              ..bytes(name))
            .take(),
      );
      offset += 30 + name.length + body.length;
    }
    final directory = central.takeBytes();
    out
      ..add(directory)
      ..add(
        (_Writer()
              ..u32(0x06054b50)
              ..u16(0)
              ..u16(0)
              ..u16(paths.length)
              ..u16(paths.length)
              ..u32(directory.length)
              ..u32(offset)
              ..u16(0))
            .take(),
      );
    return out.takeBytes();
  }
}

const int _utf8Flag = 0x0800;
const int _madeByUnix = (3 << 8) | 20; // Unix host, spec 2.0
const int _fileMode = 0x81A4; // 0100644: a regular file, rw-r--r--
const int _executableMode = 0x81ED; // 0100755: a regular file, rwxr-xr-x
const int _time = 0; // 00:00:00
const int _date = (0 << 9) | (1 << 5) | 1; // 1980-01-01

final class _Writer {
  final BytesBuilder _out = BytesBuilder();

  void u16(int v) => _out.add([v & 0xFF, (v >>> 8) & 0xFF]);

  void u32(int v) => _out.add([
    v & 0xFF,
    (v >>> 8) & 0xFF,
    (v >>> 16) & 0xFF,
    (v >>> 24) & 0xFF,
  ]);

  void bytes(List<int> b) => _out.add(b);

  Uint8List take() => _out.takeBytes();
}

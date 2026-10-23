/// Downloads pinned by size and SHA-256, cached per user.
library;

import 'dart:io';
import 'dart:typed_data';

import '../crypto/sha256.dart';
import '../project/just_project.dart';

/// A download whose bytes are not what was pinned.
final class DownloadException implements Exception {
  /// [message] about the download.
  const DownloadException(this.message);

  /// What is wrong, in a sentence.
  final String message;

  @override
  String toString() => message;
}

/// Files named by the SHA-256 of their bytes, in one folder: archives,
/// catalog pieces. Every read checks the bytes again, so a damaged or
/// replaced copy is never used — it is deleted, and reads as missing.
final class HashedFiles {
  /// The files in [dir], each named `<sha256>.<ext>`.
  HashedFiles(String dir, {this.ext = 'bin'})
    : dir = dir.replaceAll(r'\', '/') {
    if (!RegExp(r'^[a-z0-9]{1,8}$').hasMatch(ext)) {
      throw ArgumentError.value(ext, 'ext', 'Not a file extension.');
    }
  }

  /// The folder.
  final String dir;

  /// Every file's extension.
  final String ext;

  /// Where the file whose SHA-256 is [sha256] lives.
  ///
  /// Throws [ArgumentError] unless [sha256] is 64 lowercase hex digits.
  File fileFor(String sha256) {
    if (!isSha256Hex(sha256)) {
      throw ArgumentError.value(
        sha256,
        'sha256',
        'Not a SHA-256 written as 64 lowercase hex digits.',
      );
    }
    return File('$dir/$sha256.$ext');
  }

  /// The bytes whose SHA-256 is [sha256], checked again; null when missing,
  /// damaged (a damaged copy is deleted), or busy in another process.
  ///
  /// Throws [ArgumentError] unless [sha256] is 64 lowercase hex digits.
  Uint8List? read(String sha256) {
    final file = fileFor(sha256);
    try {
      if (!file.existsSync()) return null;
      final bytes = file.readAsBytesSync();
      if (Sha256.hexOf(bytes) == sha256) return bytes;
      file.deleteSync();
    } on FileSystemException {
      // Another process is replacing it, or it can't be read: a miss.
    }
    return null;
  }

  /// Keeps [bytes], whose SHA-256 the caller has checked is [sha256].
  ///
  /// Another process writing the same file at the same moment is not an
  /// error. Throws [ArgumentError] unless [sha256] is 64 lowercase hex
  /// digits.
  void write(String sha256, List<int> bytes) {
    final file = fileFor(sha256);
    try {
      writeBytesAtomic(file, bytes);
    } on FileSystemException {
      if (_holds(file, bytes.length, sha256)) return;
      rethrow;
    }
  }

  /// Deletes every file of this kind not named in [keep]. A file another
  /// process holds stays; files of other names are never touched.
  void retainOnly(Set<String> keep) {
    final folder = Directory(dir);
    if (!folder.existsSync()) return;
    final name = RegExp('^([0-9a-f]{64})\\.${RegExp.escape(ext)}\$');
    for (final f in folder.listSync()) {
      if (f is! File) continue;
      final m = name.firstMatch(f.uri.pathSegments.last);
      if (m == null || keep.contains(m[1])) continue;
      try {
        f.deleteSync();
      } on FileSystemException {
        // In use elsewhere: it goes next time.
      }
    }
  }

  /// Whether [file] is there with [size] bytes whose SHA-256 is [sha256].
  static bool _holds(File file, int size, String sha256) {
    try {
      return file.existsSync() &&
          file.lengthSync() == size &&
          Sha256.hexOf(file.readAsBytesSync()) == sha256;
    } on FileSystemException {
      return false;
    }
  }
}

/// The per-user cache shared by every project on this machine: archives
/// stored under their SHA-256, so a version downloaded once installs
/// anywhere without the network, and thumbnails.
final class DownloadCache {
  /// A cache in [dir].
  DownloadCache(String dir)
    : dir = dir.replaceAll(r'\', '/'),
      archives = HashedFiles('${dir.replaceAll(r'\', '/')}/archives', ext: 'zip');

  /// The cache folder.
  final String dir;

  /// The archives, under their SHA-256.
  final HashedFiles archives;

  /// The cached archive whose SHA-256 is [sha256], checked again; null
  /// when missing, damaged (a damaged copy is deleted), or busy in another
  /// process.
  ///
  /// Throws [ArgumentError] unless [sha256] is 64 lowercase hex digits.
  Uint8List? archive(String sha256) => archives.read(sha256);

  /// Keeps [bytes], whose SHA-256 the caller has checked is [sha256], as
  /// that archive.
  ///
  /// Another process putting the same archive at the same moment is not an
  /// error. Throws [ArgumentError] unless [sha256] is 64 lowercase hex
  /// digits.
  void putArchive(String sha256, List<int> bytes) =>
      archives.write(sha256, bytes);

  /// Where the picture at [uri] is cached.
  File thumbnailFile(Uri uri) {
    final name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? 'img' : name.substring(dot + 1).toLowerCase();
    final safeExt = RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext) ? ext : 'img';
    return File(
      '$dir/thumbnails/${Sha256.hexOf('$uri'.codeUnits).substring(0, 32)}.$safeExt',
    );
  }

  /// The cache's size on disk, in bytes.
  int get sizeInBytes {
    final root = Directory(dir);
    if (!root.existsSync()) return 0;
    var total = 0;
    for (final f in root.listSync(recursive: true)) {
      if (f is File) total += f.lengthSync();
    }
    return total;
  }

  /// Deletes everything cached.
  void clear() {
    final root = Directory(dir);
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

/// Checks that [bytes], downloaded as [what], are the [size] bytes whose
/// SHA-256 is [sha256]. Throws [DownloadException] when they are not:
/// changed after they were pinned, or broken on the way.
void checkPinned(
  Uint8List bytes, {
  required int size,
  required String sha256,
  required String what,
}) {
  if (bytes.length != size) {
    throw DownloadException(
      '$what downloaded as ${bytes.length} bytes, but the catalog says '
      '$size. The download was refused.',
    );
  }
  if (Sha256.hexOf(bytes) != sha256) {
    throw DownloadException(
      '$what does not match its catalog fingerprint (SHA-256). It may have '
      'been changed after it was published, so it was refused.',
    );
  }
}

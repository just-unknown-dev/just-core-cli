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

/// The per-user cache shared by every project on this machine: archives
/// stored under their SHA-256, so a version downloaded once installs
/// anywhere without the network, and thumbnails.
final class DownloadCache {
  /// A cache in [dir].
  DownloadCache(String dir) : dir = dir.replaceAll(r'\', '/');

  /// The cache folder.
  final String dir;

  File _archiveFile(String sha256) {
    if (!isSha256Hex(sha256)) {
      throw ArgumentError.value(
        sha256,
        'sha256',
        'Not a SHA-256 written as 64 lowercase hex digits.',
      );
    }
    return File('$dir/archives/$sha256.zip');
  }

  /// The cached archive whose SHA-256 is [sha256], checked again; null
  /// when missing, damaged (a damaged copy is deleted), or busy in another
  /// process.
  ///
  /// Throws [ArgumentError] unless [sha256] is 64 lowercase hex digits.
  Uint8List? archive(String sha256) {
    final file = _archiveFile(sha256);
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

  /// Keeps [bytes], whose SHA-256 the caller has checked is [sha256], as
  /// that archive.
  ///
  /// Another process putting the same archive at the same moment is not an
  /// error. Throws [ArgumentError] unless [sha256] is 64 lowercase hex
  /// digits.
  void putArchive(String sha256, List<int> bytes) {
    final file = _archiveFile(sha256);
    try {
      writeBytesAtomic(file, bytes);
    } on FileSystemException {
      if (_holds(file, bytes.length, sha256)) return;
      rethrow;
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

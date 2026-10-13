/// A project on disk, and how files in it are written.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../crypto/sha256.dart';
import '../json/json.dart';
import 'project_file.dart';
import 'project_paths.dart';

/// A Dart or Flutter project: the folder holding its `pubspec.yaml`.
///
/// Paths are relative to [root] and use `/` between parts, as lockfiles and
/// pubspecs write them.
base class JustProject {
  /// The project whose `pubspec.yaml` is in [root].
  JustProject(String root) : root = _resolveDots(Directory(root).absolute.path);

  /// The project folder, absolute, with `/` between parts and no `.` or
  /// `..` parts.
  final String root;

  /// The project's pubspec ([ProjectPaths.pubspec]).
  static const String pubspec = ProjectPaths.pubspec;

  /// The overrides file pub reads instead of the pubspec's overrides
  /// ([ProjectPaths.overrides]).
  static const String overrides = ProjectPaths.overrides;

  /// The project's `just.json` ([ProjectPaths.projectFile]): its title, tool
  /// set and entry points.
  static const String projectFile = ProjectPaths.projectFile;

  /// The tools' scratch folder ([ProjectPaths.workDir]): transaction
  /// journals, staging, the lock.
  static const String workDir = ProjectPaths.workDir;

  /// The folder installed packages go into ([ProjectPaths.packagesDir]).
  static const String packagesDir = ProjectPaths.packagesDir;

  /// The project holding [start] — the nearest folder at or above it with a
  /// `pubspec.yaml` — or null when there is none.
  static JustProject? find(String start) {
    var dir = Directory(start).absolute;
    while (true) {
      if (File('${dir.path}/$pubspec').existsSync()) {
        return JustProject(dir.path);
      }
      final parent = dir.parent;
      if (parent.path == dir.path) return null;
      dir = parent;
    }
  }

  /// The absolute path of [relative].
  String path(String relative) =>
      relative.isEmpty ? root : '$root/${normalPath(relative)}';

  /// [relative] as a file.
  File file(String relative) => File(path(relative));

  /// [relative] as a folder.
  Directory dir(String relative) => Directory(path(relative));

  /// [absolute] relative to [root], or null when it is outside it.
  String? relativeOf(String absolute) {
    final a = _resolveDots(absolute);
    if (samePath(a, root)) return '';
    final prefix = root.endsWith('/') ? root : '$root/';
    final head = a.length >= prefix.length
        ? a.substring(0, prefix.length)
        : null;
    if (head == null || !samePath(head, prefix)) return null;
    return a.substring(prefix.length);
  }

  /// The path from [root] to [absolute]: relative — with `..` when it is
  /// outside the project — whenever both are on the same drive (or share),
  /// so a project and what it points at can move together; else
  /// [absolute].
  String pathTo(String absolute) {
    final target = _resolveDots(absolute);
    final fromHead = _head(root);
    final toHead = _head(target);
    if (!samePath(fromHead, toHead)) return target;
    List<String> parts(String p, String head) =>
        p.substring(head.length).split('/').where((s) => s.isNotEmpty).toList();
    final from = parts(root, fromHead);
    final to = parts(target, toHead);
    var i = 0;
    while (i < from.length && i < to.length && samePath(from[i], to[i])) {
      i++;
    }
    final rel = [
      ...List.filled(from.length - i, '..'),
      ...to.skip(i),
    ].join('/');
    return rel.isEmpty ? '.' : rel;
  }

  /// The text of [relative], or null when it doesn't exist.
  String? readText(String relative) {
    final f = file(relative);
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  /// Whether this folder holds a pubspec.
  bool get exists => file(pubspec).existsSync();

  /// The project's `just.json`, or the defaults when it has none. Throws
  /// [JsonFormatException] (naming the file) when it exists but is not
  /// valid.
  JustProjectFile readProjectFile() {
    final text = readText(projectFile);
    if (text == null) return const JustProjectFile();
    try {
      return JustProjectFile.parse(text);
    } on JsonFormatException catch (e) {
      throw e.inFile(projectFile);
    }
  }

  /// Saves [file] as the project's `just.json`.
  void writeProjectFile(JustProjectFile file) =>
      writeTextAtomic(this.file(projectFile), file.toText());
}

/// Writes [text] to [file] so that it is never seen half-written: into a
/// temporary `.saving` file beside it — named for this write alone, so two
/// writers never share one — then renamed over it. The temporary file is
/// removed when anything fails.
///
/// A [file] that is a symbolic link is written through: its target gets
/// the new text, and the link stays a link — wherever it leads, outside a
/// project too: this writes the file it is given. A `ProjectTransaction`'s
/// writes follow a link only while it stays inside the project. On macOS
/// and Linux the file keeps its permissions (an executable script stays
/// executable).
void writeTextAtomic(File file, String text) =>
    writeBytesAtomic(file, utf8.encode(text));

/// [writeTextAtomic] for bytes.
void writeBytesAtomic(File file, List<int> bytes) =>
    _replaceAtomic(file, (temp) => temp.writeAsBytesSync(bytes, flush: true));

/// Replaces [file] with a copy of [from], as [writeBytesAtomic] writes:
/// never seen half-written, through a symbolic link, and with [from]'s
/// permissions on macOS and Linux.
void copyAtomic(File from, File file) =>
    _replaceAtomic(file, (temp) => from.copySync(temp.path), seed: false);

/// Fills a temporary file beside [file]'s target with [fill], then renames
/// it over the target. With [seed], the temporary file starts as a copy of
/// the target when it exists, so a POSIX file keeps its mode: `File.copy`
/// keeps it, and writing into an existing file does not change it.
void _replaceAtomic(
  File file,
  void Function(File temp) fill, {
  bool seed = true,
}) {
  final target = _throughLinks(file);
  target.parent.createSync(recursive: true);
  final unique = _random.nextInt(1 << 32).toRadixString(36);
  final temp = File('${target.path}.$pid-${_writes++}-$unique.saving');
  try {
    if (seed && !Platform.isWindows && target.existsSync()) {
      try {
        target.copySync(temp.path);
      } on FileSystemException {
        // Gone in between (another tool replaced or removed it): written
        // as a new file. Any other failure is the write's own.
        if (target.existsSync()) rethrow;
      }
    }
    fill(temp);
    retryOnLock(() => temp.renameSync(target.path));
  } on Object {
    try {
      if (temp.existsSync()) temp.deleteSync();
    } on FileSystemException {
      // Nothing more to do; the original error says what went wrong.
    }
    rethrow;
  }
}

/// [file], or — when it is a symbolic link — the file it points at, at the
/// end of any chain of links (a dangling link: where it points).
File _throughLinks(File file) {
  var path = file.path;
  for (var hops = 0; hops < 32; hops++) {
    if (!FileSystemEntity.isLinkSync(path)) return File(path);
    final to = Link(path).targetSync();
    path = File(to).isAbsolute ? to : '${File(path).parent.path}/$to';
  }
  throw FileSystemException('Too many symbolic links', file.path);
}

final Random _random = Random();
int _writes = 0;

/// Runs [action], retrying a few times with growing pauses when Windows
/// says a file is in use (an antivirus scan, an indexer, the analyzer).
T retryOnLock<T>(T Function() action, {int attempts = 6}) {
  for (var i = 1; ; i++) {
    try {
      return action();
    } on FileSystemException catch (e) {
      final code = e.osError?.errorCode;
      final locked = Platform.isWindows && (code == 5 || code == 32);
      if (!locked || i >= attempts) rethrow;
      sleep(Duration(milliseconds: 50 * i * i));
    }
  }
}

/// Hashes files so a tool can tell a local edit from what it installed.
abstract final class FileHashes {
  /// Extensions hashed as text: line endings are ignored, so a checkout
  /// that turned LF into CRLF (git's core.autocrlf) is not an edit.
  static const Set<String> textExtensions = {
    'json', 'yaml', 'yml', 'dart', 'md', 'txt', 'tmx', 'tsx', 'tmj', 'tsj', //
    'tx', 'xml', 'csv', 'svg', 'glsl', 'frag', 'vert', 'yarn', 'html', 'css',
    'js', 'atlas', 'fnt', 'gitignore', 'pubignore', 'gitattributes',
  };

  /// Whether [path] is hashed as text.
  static bool isText(String path) {
    final name = path.split('/').last.toLowerCase();
    if (name == 'license' || name == 'licence' || name == 'changelog') {
      return true;
    }
    final dot = name.lastIndexOf('.');
    return dot >= 0 && textExtensions.contains(name.substring(dot + 1));
  }

  /// The hash of [bytes], the content of [path]: SHA-256, with CRLF read as
  /// LF for text files.
  static String of(String path, List<int> bytes) {
    if (!isText(path)) return Sha256.hexOf(bytes);
    final out = <int>[];
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] == 0x0D && i + 1 < bytes.length && bytes[i + 1] == 0x0A) {
        continue;
      }
      out.add(bytes[i]);
    }
    return Sha256.hexOf(out);
  }

  /// Every file under [dir], by path relative to it, with its hash. Tool
  /// folders (`.dart_tool`, `build`, `.git`…) are skipped.
  static Map<String, String> ofFolder(Directory dir) {
    final out = <String, String>{};
    if (!dir.existsSync()) return out;
    final base = normalPath(dir.absolute.path);
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = normalPath(entity.absolute.path).substring(base.length + 1);
      if (isToolPath(rel)) continue;
      out[rel] = of(rel, entity.readAsBytesSync());
    }
    return Map.fromEntries(
      out.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
  }

  /// Whether [relative] is inside a folder tools make — `.dart_tool`,
  /// `.git` or `.idea` at any depth, `build` at the top — or is a pub
  /// lockfile or Flutter's plugin list.
  static bool isToolPath(String relative) {
    final parts = relative.split('/');
    // A package's own build output is `build/` at its root; a `build`
    // folder deeper down is the package's content.
    return parts.first == 'build' ||
        parts.any((p) => const {'.dart_tool', '.git', '.idea'}.contains(p)) ||
        relative == 'pubspec.lock' ||
        relative == '.flutter-plugins' ||
        relative == '.flutter-plugins-dependencies';
  }
}

/// [path] with `/` between parts and no trailing `/` (a drive root such as
/// `C:/` keeps its own).
String normalPath(String path) {
  var p = path.replaceAll(r'\', '/');
  while (p.length > 1 && p.endsWith('/') && !p.endsWith(':/')) {
    p = p.substring(0, p.length - 1);
  }
  return p;
}

/// Whether [a] and [b] name the same path on this system: ignoring case on
/// Windows and macOS.
bool samePath(String a, String b) => Platform.isWindows || Platform.isMacOS
    ? a.toLowerCase() == b.toLowerCase()
    : a == b;

/// The part of [path] (with `/`) no `..` climbs above: a drive (`C:/`), a
/// network share (`//server/share/`) or `/`; empty for a relative path.
String _head(String path) {
  final unc = RegExp(r'^//[^/]+/[^/]+(/|$)').firstMatch(path);
  if (unc != null) {
    final m = unc[0]!;
    return m.endsWith('/') ? m : '$m/';
  }
  final drive = RegExp(r'^[A-Za-z]:(/|$)').firstMatch(path);
  if (drive != null) return '${path.substring(0, 2)}/';
  return path.startsWith('/') ? '/' : '';
}

/// [path] with `/` between parts and its `.` and `..` parts resolved:
/// `C:/app/./lib/../assets` is `C:/app/assets`. A drive, a network share
/// or `/` keeps its own form, and `..` never climbs above it.
String _resolveDots(String path) {
  final p = path.replaceAll(r'\', '/');
  final head = _head(p);
  final out = <String>[];
  for (final part in p.substring(head.length).split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (out.isNotEmpty && out.last != '..') {
        out.removeLast();
      } else if (head.isEmpty) {
        out.add('..');
      }
      continue;
    }
    out.add(part);
  }
  final rest = out.join('/');
  if (head.isEmpty) return rest.isEmpty ? '.' : rest;
  // A share is written without its last `/` unless it is the whole path.
  if (head.startsWith('//')) {
    return rest.isEmpty ? head.substring(0, head.length - 1) : '$head$rest';
  }
  return '$head$rest';
}

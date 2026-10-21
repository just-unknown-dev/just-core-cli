/// Changing a project all or nothing: a journal written ahead of each step,
/// backups, rollback, and recovery after a crash.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../archive/zip_reader.dart';
import '../json/json.dart';
import 'just_project.dart';
import 'project_paths.dart';
import 'windows_processes.dart';

/// Another tool is changing the project right now.
final class ProjectBusyException implements Exception {
  /// The project is held by another tool, as [message] says.
  const ProjectBusyException(this.message);

  /// What to tell the user.
  final String message;

  @override
  String toString() => message;
}

/// One change at a time per project: an install, an edit, an upgrade.
///
/// The lock is a file in [JustProject.workDir], made exclusively, naming
/// its holder: the process id, where it runs (the machine, the system and,
/// on Linux, the pid namespace and boot) and a random token. While it is
/// held it is touched every [heartbeat]; one left untouched for [stale]
/// belongs to a holder that died, and is taken over — at once when its
/// holder ran here and is no longer running. Only its holder's [release]
/// removes it.
final class ProjectLock {
  ProjectLock._(this._file, this._token) {
    _beat = Timer.periodic(heartbeat, (_) => _touch());
  }

  final File _file;
  final String _token;
  Timer? _beat;

  /// Where the lock lives in a project.
  static const String path = '${JustProject.workDir}/lock';

  /// How often a held lock is touched.
  static const Duration heartbeat = Duration(seconds: 30);

  /// How long a lock may go untouched before it counts as left by a crash.
  static const Duration stale = Duration(minutes: 10);

  /// Takes the lock on [project]. Throws [ProjectBusyException] when
  /// another change holds it, naming the holder, the lock file and when it
  /// goes stale.
  static ProjectLock acquire(JustProject project) =>
      tryAcquire(project) ?? (throw ProjectBusyException(_busy(project)));

  static String _busy(JustProject project) {
    final file = project.file(path);
    final held = _Holder.read(file);
    var who = '';
    var left = '';
    if (held != null) {
      final json = held.json;
      final holder = json['pid'];
      final host = json['host'];
      if (holder is int) {
        who =
            ' (process $holder${host is String && host.isNotEmpty ? ' on $host' : ''})';
      }
      final rest = stale - DateTime.now().difference(held.touched);
      final minutes = rest.isNegative ? 0 : (rest.inSeconds / 60).ceil();
      if (_restartedSince(json)) {
        // Left by a crash before a restart: nothing holds it, but a pid
        // from another boot says nothing, so it waits like any other.
        return 'A change in this project$who was cut short: this machine '
            'has restarted since. Its lock, ${normalPath(file.path)}, is '
            'taken over $minutes min after its last heartbeat — or delete '
            'it to go on now.';
      }
      left =
          ' If nothing is running, it is taken over $minutes min after '
          'its last heartbeat — or delete it to go on now';
    }
    return 'Another change is running in this project$who. Wait for it to '
        'finish. Its lock is ${normalPath(file.path)}.$left.';
  }

  /// Whether lock [json] was written on this machine and system before it
  /// last restarted: the same host and system, another boot.
  static bool _restartedSince(Map<String, Object?> json) {
    final boot = _here['bootId'];
    final theirs = json['bootId'];
    return boot != null &&
        theirs is String &&
        theirs.isNotEmpty &&
        theirs != boot &&
        json['host'] == _here['host'] &&
        json['os'] == _here['os'];
  }

  /// Takes the lock on [project], or returns null when another change holds
  /// it. Throws a [FileSystemException] when the lock can't be made at all
  /// (a read-only folder, a path too long).
  static ProjectLock? tryAcquire(JustProject project) {
    final file = project.file(path);
    file.parent.createSync(recursive: true);
    final token = _newToken();
    for (var attempt = 1; ; attempt++) {
      try {
        file.createSync(exclusive: true);
      } on FileSystemException catch (e) {
        final held = _Holder.read(file);
        if (held == null) {
          // Released in between — or the file can't be made at all.
          if (attempt < 3) continue;
          throw FileSystemException(
            'Could not make the project lock',
            file.path,
            e.osError,
          );
        }
        if (DateTime.now().difference(held.touched) <= stale &&
            !_crashedHere(held)) {
          return null;
        }
        // Left by a crash: out of the way with it, then try again.
        if (attempt >= 3) return null;
        _takeOver(file, held, token);
        continue;
      }
      try {
        file.writeAsStringSync(
          jsonEncode({
            'pid': pid,
            ..._here,
            'token': token,
            'since': DateTime.now().toUtc().toIso8601String(),
          }),
          flush: true,
        );
      } on FileSystemException {
        try {
          file.deleteSync();
        } on FileSystemException {
          // It goes stale on its own.
        }
        rethrow;
      }
      return ProjectLock._(file, token);
    }
  }

  /// Moves the stale lock [held] out of [file]'s way, under a name of this
  /// taker's own ([token]). A rename is atomic, so of several tools taking
  /// it over at once only one moves it. What was moved is then checked: a
  /// lock that isn't [held] — one another tool made after taking it over
  /// first — is put back.
  static void _takeOver(File file, _Holder held, String token) {
    final moved = File('${file.path}.$token.stale');
    try {
      file.renameSync(moved.path);
    } on FileSystemException {
      return; // Gone already: another tool took it over first.
    }
    if (_Holder.read(moved) != held) {
      try {
        // Its name and time unchanged, so its holder goes on as before.
        // (Should yet another lock be there by now, that one stays.)
        if (!file.existsSync()) {
          moved.renameSync(file.path);
          return;
        }
      } on FileSystemException {
        // Put back it can't be: removed below, as a lost race.
      }
    }
    try {
      moved.deleteSync();
    } on FileSystemException {
      // A leftover beside the lock, harmless.
    }
  }

  /// Lets the next change in: removes the lock, if it is still this one.
  void release() {
    _beat?.cancel();
    _beat = null;
    try {
      if (_tokenOf(_file.readAsStringSync()) != _token) return;
      retryOnLock(_file.deleteSync);
    } on FileSystemException {
      // Already gone, or can't be removed: it goes stale on its own.
    }
  }

  void _touch() {
    try {
      if (_tokenOf(_file.readAsStringSync()) != _token) {
        // Taken over: this one is no longer held.
        _beat?.cancel();
        _beat = null;
        return;
      }
      _file.setLastModifiedSync(DateTime.now());
    } on FileSystemException {
      // Busy for a moment: touched at the next beat.
    }
  }

  static String? _tokenOf(String text) {
    try {
      final json = jsonDecode(text);
      return json is Map && json['token'] is String
          ? json['token'] as String
          : null;
    } on FormatException {
      return null;
    }
  }

  /// Whether [held] names a process in this process space — not this one
  /// — that is no longer running: a crash, its lock free to take over at
  /// once.
  ///
  /// A machine's name is not enough: WSL beside Windows, or a Flatpak
  /// sandbox beside its Linux host, shares the name but not the process
  /// ids. So the lock must name the same machine, the same system and, on
  /// Linux, the same pid namespace and boot ([_here]); a lock that doesn't
  /// (one from elsewhere, or from an older `just`) waits for [stale].
  static bool _crashedHere(_Holder held) {
    final json = held.json;
    final holder = json['pid'];
    if (holder is! int || holder == pid) return false;
    for (final key in _identity) {
      final mine = _here[key];
      if (mine == null || mine.isEmpty || json[key] != mine) return false;
    }
    return !_running(holder);
  }

  /// The keys of [_here] that must all match.
  static List<String> get _identity => [
    'host',
    'os',
    if (Platform.isLinux || Platform.isAndroid) ...['pidNamespace', 'bootId'],
  ];

  /// Where this process runs, as a lock records it: the machine's name,
  /// the system and — on Linux, where a sandbox or WSL can share the name
  /// — the pid namespace (`/proc/self/ns/pid`) and the boot
  /// (`/proc/sys/kernel/random/boot_id`). A value that can't be read is
  /// left out, and then no lock is taken over early.
  static final Map<String, String> _here = () {
    final here = {'host': _host(), 'os': Platform.operatingSystem};
    if (Platform.isLinux || Platform.isAndroid) {
      try {
        here['pidNamespace'] = Link('/proc/self/ns/pid').targetSync();
      } on Object {
        // Left out: see above.
      }
      try {
        here['bootId'] = File(
          '/proc/sys/kernel/random/boot_id',
        ).readAsStringSync().trim();
      } on Object {
        // Left out: see above.
      }
    }
    return here;
  }();

  /// Whether process [id] runs here. True when it can't be told. Never
  /// waits on another program for long: Linux reads `/proc`, macOS asks
  /// `kill -0`, and Windows asks the system for its process list directly
  /// ([windowsProcessRuns]).
  static bool _running(int id) {
    try {
      if (Platform.isLinux || Platform.isAndroid) {
        return Directory('/proc/$id').existsSync();
      }
      if (Platform.isMacOS) {
        final r = Process.runSync('kill', ['-0', '$id']);
        return r.exitCode == 0 || '${r.stderr}'.contains('not permitted');
      }
      if (Platform.isWindows) return windowsProcessRuns(id) ?? true;
    } on Object {
      return true;
    }
    return true;
  }

  static String _newToken() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  static String _host() {
    try {
      return Platform.localHostname;
    } on Object {
      return '';
    }
  }
}

/// A lock file as found: its text and when it was last touched.
final class _Holder {
  const _Holder(this.text, this.touched);

  /// [file]'s holder, or null when there is no lock file.
  static _Holder? read(File file) {
    try {
      if (!file.existsSync()) return null;
      return _Holder(file.readAsStringSync(), file.lastModifiedSync());
    } on FileSystemException {
      return null;
    }
  }

  final String text;
  final DateTime touched;

  /// [text] as the JSON a lock holds; empty when it isn't.
  Map<String, Object?> get json {
    try {
      final v = jsonDecode(text);
      return v is Map<String, Object?> ? v : const {};
    } on FormatException {
      return const {};
    }
  }

  @override
  bool operator ==(Object other) =>
      other is _Holder && other.text == text && other.touched == touched;

  @override
  int get hashCode => Object.hash(text, touched);
}

/// One change to a project, journalled so it can be undone.
///
/// Every step is recorded before it is taken: the files backed up (and
/// whether they existed), the folders moved aside, the folders moved in. A
/// failure calls [rollBack], which puts every file and folder back byte for
/// byte; a crash leaves the journal behind, and [recover] rolls it back (or
/// finishes a change that had committed) the next time a tool starts.
/// Both can be cut short and run again: each step is only taken while it is
/// still needed.
///
/// Take a [ProjectLock] first: two transactions at once would undo each
/// other's work.
///
/// ```dart
/// final lock = ProjectLock.acquire(project);
/// try {
///   ProjectTransaction.recover(project);
///   final txn = ProjectTransaction.begin(project, trash: 'my_tool');
///   try {
///     txn.write('config/settings.json', text);
///     txn.commit();
///   } catch (_) {
///     txn.rollBack(); // nothing, once commit() got through
///     rethrow;
///   }
/// } finally {
///   lock.release();
/// }
/// ```
final class ProjectTransaction {
  ProjectTransaction._(
    this.project,
    this.dir,
    this.trash, [
    this.trashRoot = defaultTrashRoot,
  ]);

  /// The project being changed.
  final JustProject project;

  /// Where the journal, backups and moved-aside folders are kept.
  final Directory dir;

  /// The folder under [trashRoot] that replaced and removed folders go to
  /// when the change commits: restorable, by hand or by the tool that made
  /// the change.
  final String trash;

  /// The project folder that holds every tool's trash: [defaultTrashRoot],
  /// unless the change's tool keeps its own (an app that restores from a
  /// folder of its own, say).
  final String trashRoot;

  /// Where replaced and removed folders go unless a change says otherwise:
  /// `.just_trash/<trash>/<stamp>/` in the project.
  static const String defaultTrashRoot = ProjectPaths.trashRoot;

  /// Each backed-up file → its copy's name in `backup/`, or null when it
  /// didn't exist (a rollback deletes it).
  final Map<String, String?> _backups = {};

  /// Each backed-up symbolic link → where it led: a rollback makes it
  /// again (its [_backups] entry is null).
  final Map<String, String> _links = {};

  /// Each folder moved aside → where it waits: relative to [dir] (absolute
  /// in journals from before that).
  final Map<String, String> _aside = {};
  final List<String> _movedIn = [];

  /// The backed-up files a rollback has put back (or deleted) so far, as
  /// [_restoredLog] lists them: a rollback run again leaves them be.
  final Set<String> _restored = {};
  String _state = _started;

  static const String _started = 'started';
  static const String _committed = 'committed';
  static const String _rollingBack = 'rollingBack';
  static const String _rolledBack = 'rolledBack';

  /// The file in [dir] saying a rollback finished: written before anything
  /// is removed, so a journal that outlives it is only tidied, never
  /// replayed over what changed since.
  static const String _rolledBackMarker = 'rolled-back';

  /// The file in [dir] naming, one JSON string a line, each file a rollback
  /// has put back.
  static const String _restoredLog = 'restored';

  /// Where every journal lives in a project.
  static const String journals = '${JustProject.workDir}/txn';

  /// Where staged folders wait before [moveIn].
  static const String staging = '${JustProject.workDir}/staging';

  /// Starts a change to [project], stamped [now], whose replaced folders go
  /// to `<trashRoot>/<trash>/<stamp>/` when it commits. Both are kept in
  /// the journal, so [recover] finishes a change the same way.
  static ProjectTransaction begin(
    JustProject project, {
    DateTime? now,
    required String trash,
    String trashRoot = defaultTrashRoot,
  }) {
    final stamp = timeStamp((now ?? DateTime.now()).toUtc());
    var dir = project.dir('$journals/$stamp');
    for (var n = 1; dir.existsSync(); n++) {
      dir = project.dir('$journals/$stamp-$n');
    }
    dir.createSync(recursive: true);
    return ProjectTransaction._(project, dir, trash, trashRoot).._save();
  }

  /// The stamp this change files its trash under.
  String get stamp =>
      dir.path.replaceAll(r'\', '/').split('/').where((s) => s.isNotEmpty).last;

  Directory get _staging => project.dir(staging);

  File get _journal => File('${dir.path}/journal.json');

  void _save() => writeTextAtomic(
    _journal,
    canonicalJson({
      'state': _state,
      'trash': trash,
      'trashRoot': trashRoot,
      'backups': {for (final e in _backups.entries) e.key: e.value != null},
      'backupFiles': {
        for (final e in _backups.entries)
          if (e.value != null) e.key: e.value,
      },
      'links': _links,
      'aside': _aside,
      'movedIn': _movedIn,
    }),
  );

  void _checkOpen() {
    if (_state == _started) return;
    throw StateError(switch (_state) {
      _committed => 'This change has committed; begin another.',
      _ => 'This change was rolled back; begin another.',
    });
  }

  /// [rel] as the journal keys it: `/` between parts, no leading `./`.
  ///
  /// Another spelling already backed up (`Assets/a.json` for
  /// `assets/a.json`) is kept only when both are there and are one file —
  /// a disk that ignores case. Where case tells files apart (Linux, a
  /// case-sensitive folder on Windows or volume on macOS) they are two
  /// files, each backed up.
  String _key(String rel) {
    var r = normalPath(rel);
    while (r.startsWith('./')) {
      r = r.substring(2);
    }
    if (_backups.containsKey(r)) return r;
    final lower = r.toLowerCase();
    for (final k in _backups.keys) {
      if (k.toLowerCase() != lower) continue;
      try {
        if (FileSystemEntity.identicalSync(project.path(k), project.path(r))) {
          return k;
        }
      } on FileSystemException {
        // One of them isn't there: two paths, not one file.
      }
    }
    return r;
  }

  /// Where the folder moved aside from [path] waits, if one was.
  Directory? _asideOf(String path) {
    final wanted = project.path(path);
    for (final e in _aside.entries) {
      if (samePath(project.path(e.key), wanted)) return _asideDir(e.value);
    }
    return null;
  }

  Directory _asideDir(String where) => File(where).isAbsolute
      ? Directory(where)
      : Directory('${dir.path}/$where');

  /// The project's folder with its symbolic links resolved: what is in it
  /// is what a change may touch.
  late final JustProject _real = () {
    try {
      return JustProject(Directory(project.root).resolveSymbolicLinksSync());
    } on FileSystemException {
      return project;
    }
  }();

  /// [rel] as a key of the project once the symbolic links of the folders
  /// on its way are followed (its last part is kept, a link or not).
  /// Throws a [FileSystemException] when that is outside the project: a
  /// change never touches a file there.
  String _inside(String rel) => _keyOf(project.path(rel), rel);

  /// [absolute] (reached from [rel]) as [_inside] gives it.
  String _keyOf(String absolute, String rel) {
    final real = _realFolders(absolute);
    final inside = _real.relativeOf(real);
    if (inside == null || inside.isEmpty) {
      throw FileSystemException(
        'Not changed: $rel leads outside the project (to $real) through a '
        'symbolic link. Replace the link with the file itself, or point it '
        'at a file inside the project',
        project.path(rel),
      );
    }
    return _key(inside);
  }

  /// Where writing [rel] lands, as [_inside] gives it: [rel], or — when it
  /// is a symbolic link — the file at the end of its links, which must be
  /// in the project too.
  String _landing(String rel) {
    var key = _inside(rel);
    for (var hops = 0; hops < 32; hops++) {
      final path = project.path(key);
      if (!FileSystemEntity.isLinkSync(path)) return key;
      final to = Link(path).targetSync();
      key = _keyOf(
        File(to).isAbsolute ? to : '${File(path).parent.path}/$to',
        rel,
      );
    }
    throw FileSystemException('Too many symbolic links', project.path(rel));
  }

  /// Throws a [FormatException] when this journal, read back by [recover],
  /// names what a replay must never touch: a file or folder outside the
  /// project (or the project folder itself), a backup copy outside
  /// `backup/`, or a folder waiting aside outside this change's folder. A
  /// journal is a file in the project: whatever can write one must not be
  /// able to make the next [recover] delete or overwrite something else.
  void _checkReplayable() {
    for (final rel in [
      ..._backups.keys,
      ..._links.keys,
      ..._aside.keys,
      ..._movedIn,
    ]) {
      try {
        _inside(rel);
      } on FileSystemException {
        throw FormatException('it names $rel, which is not in the project');
      }
    }
    for (final name in _backups.values) {
      if (name != null &&
          (name.isEmpty ||
              name == '.' ||
              name == '..' ||
              name.contains('/') ||
              name.contains(r'\'))) {
        throw FormatException('it names the backup copy "$name"');
      }
    }
    for (final where in _aside.values) {
      final ok = File(where).isAbsolute
          ? (project.relativeOf(where)?.isNotEmpty ?? false)
          : !where.contains(r'\') &&
                !where.startsWith('/') &&
                where
                    .split('/')
                    .every((s) => s.isNotEmpty && s != '.' && s != '..');
      if (!ok) throw FormatException('it keeps a folder aside at $where');
    }
  }

  /// Backs up [files] (paths in the project; missing ones are noted as
  /// missing, so a rollback deletes what the change created). A symbolic
  /// link is backed up as a link, and the file it leads to too — what a
  /// write through it changes. Throws a [FileSystemException], backing up
  /// nothing more, for a path that leads outside the project.
  void backUp(List<String> files) {
    _checkOpen();
    try {
      for (final rel in files) {
        final key = _inside(rel);
        if (FileSystemEntity.isLinkSync(project.path(key))) {
          _backUpLink(key);
          _backUpFile(_landing(rel));
        } else {
          _backUpFile(key);
        }
      }
    } finally {
      _save();
    }
  }

  /// Backs up the file at [key] unless it is already; whether the journal
  /// needs saving.
  bool _backUpFile(String key) {
    if (_backups.containsKey(key)) return false;
    final path = project.path(key);
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.file) {
      // Numbered, so no two files' copies can share a name.
      final name = '${_backups.length}-${key.split('/').last}';
      final copy = File('${dir.path}/backup/$name');
      copy.parent.createSync(recursive: true);
      File(path).copySync(copy.path);
      _backups[key] = name;
    } else {
      _backups[key] = null;
    }
    return true;
  }

  /// Backs up the symbolic link at [key] — where it leads — unless it is
  /// already; whether the journal needs saving.
  bool _backUpLink(String key) {
    if (_backups.containsKey(key)) return false;
    _links[key] = Link(project.path(key)).targetSync();
    _backups[key] = null;
    return true;
  }

  /// Writes [files] (relative path → bytes) into a staging folder [id],
  /// beside the project, ready for [moveIn]. On macOS and Linux the paths
  /// in [executable] are made executable (`chmod +x`), as an archive's
  /// entries say ([ZipEntry.isExecutable]); Windows has no such bit.
  ///
  /// [id] must be a plain folder name (no `/`, `\`, `:`, `.` or `..`), and
  /// each path a plain relative one (`lib/a.dart`: no `..`, no leading
  /// `/`): an [ArgumentError] otherwise, before anything is touched.
  void stage(
    String id,
    Map<String, Uint8List> files, {
    Set<String> executable = const {},
  }) {
    _checkOpen();
    final into = _own(staging, id);
    for (final p in files.keys) {
      final parts = p.split('/');
      if (p.startsWith('/') ||
          p.contains(r'\') ||
          parts.any((s) => s.isEmpty || s == '.' || s == '..')) {
        throw ArgumentError.value(p, 'files', 'Not a plain relative path');
      }
    }
    switch (FileSystemEntity.typeSync(into.path, followLinks: false)) {
      case FileSystemEntityType.link:
        Link(into.path).deleteSync();
      case FileSystemEntityType.notFound:
        break;
      default:
        into.deleteSync(recursive: true);
    }
    for (final e in files.entries) {
      File('${into.path}/${e.key}')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(e.value);
    }
    final exec = [
      for (final p in executable)
        if (files.containsKey(p)) '${into.path}/$p',
    ];
    if (exec.isEmpty || Platform.isWindows) return;
    final result = Process.runSync('chmod', ['+x', ...exec]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Could not make ${exec.length} staged file(s) executable: '
        '${'${result.stderr}'.trim()}',
        into.path,
      );
    }
  }

  /// Moves the folder at [path] out of the way, keeping it as [id] until
  /// the change commits or rolls back. [id] is a plain folder name, as for
  /// [stage], used once in a change.
  void moveAside(String id, String path) {
    _checkOpen();
    final aside = _own('${project.relativeOf(dir.path)!}/aside', id);
    final where = 'aside/$id';
    if (_aside.containsValue(where) ||
        FileSystemEntity.typeSync(aside.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw StateError('Something was moved aside as $id already.');
    }
    _inside(path);
    aside.parent.createSync(recursive: true);
    _aside[path] = where;
    _save();
    retryOnLock(() => project.dir(path).renameSync(aside.path));
  }

  /// Moves the folder staged as [id] to [path], which must not exist.
  void moveIn(String id, String path) {
    _checkOpen();
    final staged = _own(staging, id);
    if (FileSystemEntity.typeSync(staged.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('Nothing is staged as $id.');
    }
    _inside(path);
    final target = project.dir(path);
    target.parent.createSync(recursive: true);
    if (target.existsSync()) {
      throw StateError('$path already exists.');
    }
    _movedIn.add(path);
    _save();
    retryOnLock(() => staged.renameSync(target.path));
  }

  /// The folder [id] in [folder] — the staging folder, or this change's
  /// aside folder, relative to the project — once [id] is checked to be a
  /// plain folder name and no folder on the way to be a symbolic link: it
  /// can only be [folder]'s own child. Throws an [ArgumentError] for any
  /// other name, and a [FileSystemException] for a link.
  Directory _own(String folder, String id) {
    if (id.isEmpty ||
        id == '.' ||
        id == '..' ||
        id.contains(RegExp(r'[/\\:\x00]'))) {
      throw ArgumentError.value(id, 'id', 'Not a plain folder name');
    }
    var path = project.root;
    for (final part in normalPath(folder).split('/')) {
      path = '$path/$part';
      if (FileSystemEntity.isLinkSync(path)) {
        throw FileSystemException(
          'Not changed: $folder must be a folder of the change itself, but '
          'a symbolic link is on its way',
          path,
        );
      }
    }
    return Directory('$path/$id');
  }

  /// Writes [text] to [rel], backing it up first.
  void write(String rel, String text) => writeBytes(rel, utf8.encode(text));

  /// Writes [bytes] to [rel], backing it up first.
  ///
  /// A symbolic link is written through — its target gets the bytes, and
  /// the link stays — only while it leads to a file in the project;
  /// otherwise (or when a folder on the way leads out of it) this throws a
  /// [FileSystemException] and writes nothing.
  void writeBytes(String rel, List<int> bytes) {
    _checkOpen();
    final key = _landing(rel);
    if (_backUpFile(key)) _save();
    writeBytesAtomic(project.file(key), bytes);
  }

  /// [write], unless [rel] already holds exactly [text].
  void writeIfChanged(String rel, String text) {
    _checkOpen();
    final f = project.file(rel);
    if (f.existsSync() && _same(f.readAsBytesSync(), utf8.encode(text))) {
      return;
    }
    write(rel, text);
  }

  /// Deletes the file [rel], backing it up first. Nothing when it is
  /// already gone. A symbolic link is deleted itself, not what it leads
  /// to, and a rollback makes it again.
  void delete(String rel) {
    _checkOpen();
    final key = _inside(rel);
    final path = project.path(key);
    switch (FileSystemEntity.typeSync(path, followLinks: false)) {
      case FileSystemEntityType.link:
        if (_backUpLink(key)) _save();
        retryOnLock(Link(path).deleteSync);
      case FileSystemEntityType.file:
        if (_backUpFile(key)) _save();
        retryOnLock(File(path).deleteSync);
      default:
      // Gone already, or a folder: not this method's to delete.
    }
  }

  /// Makes the change final: folders moved aside go to the trash, and the
  /// journal is removed.
  ///
  /// Once the journal says the change committed, this never throws: what
  /// can't be tidied now is tidied by the next [recover]. A [rollBack]
  /// after it does nothing.
  void commit() {
    if (_state == _committed) return;
    _checkOpen();
    _state = _committed;
    try {
      _save();
    } on Object {
      _state = _started; // Not committed: a rollback still undoes it all.
      rethrow;
    }
    _finish();
  }

  /// Sends the folders moved aside to the trash and removes the journal.
  /// Never throws.
  void _finish() {
    for (final e in _aside.entries) {
      final aside = _asideDir(e.value);
      try {
        if (!aside.existsSync()) continue;
        final trashed = project.dir('$trashRoot/$trash/$stamp/${e.key}');
        trashed.parent.createSync(recursive: true);
        retryOnLock(() => aside.renameSync(trashed.path));
      } on FileSystemException {
        // Left in the transaction folder; removed with it.
      }
    }
    _cleanUp();
  }

  /// Puts every file and folder back as it was, and removes the journal.
  ///
  /// Nothing once the change has committed. Safe to run again after it was
  /// cut short: a folder moved in is only removed while the one it replaced
  /// still waits aside, and a file already put back ([_restoredLog]) is
  /// left as it is now. When a step fails — a file in use, a backup that is
  /// missing — the others are still taken; the first failure is rethrown
  /// and the journal kept, so [recover] finishes the job (or, for a missing
  /// backup, says where the others are).
  void rollBack() {
    if (_state == _committed || _state == _rolledBack) return;
    _state = _rollingBack;
    try {
      _save();
    } on Object {
      // The journal still says started: rolled back all the same.
    }
    Object? failure;
    StackTrace? trace;
    void step(void Function() action) {
      try {
        action();
      } on Object catch (e, s) {
        failure ??= e;
        trace ??= s;
      }
    }

    for (final path in _movedIn.reversed) {
      step(() {
        final d = project.dir(path);
        if (!d.existsSync()) return;
        // Once the folder it replaced is back, [path] holds the original.
        final aside = _asideOf(path);
        if (aside != null && !aside.existsSync()) return;
        retryOnLock(() => d.deleteSync(recursive: true));
      });
    }
    for (final e in _aside.entries) {
      step(() {
        final aside = _asideDir(e.value);
        if (!aside.existsSync()) return; // Never moved, or back already.
        final back = project.dir(e.key);
        if (back.existsSync()) {
          retryOnLock(() => back.deleteSync(recursive: true));
        }
        retryOnLock(() => aside.renameSync(back.path));
      });
    }
    // Newest first: of two spellings of one file, the one backed up first —
    // the file as it was — is put back last.
    for (final e in _backups.entries.toList().reversed) {
      if (_restored.contains(e.key)) continue;
      step(() {
        // Never put back through a folder that now leads out of the project.
        _inside(e.key);
        final path = project.path(e.key);
        final type = FileSystemEntity.typeSync(path, followLinks: false);
        final link = _links[e.key];
        final name = e.value;
        if (link != null) {
          // A symbolic link: made again, leading where it did.
          if (type != FileSystemEntityType.link ||
              Link(path).targetSync() != link) {
            _removeFile(path, type);
            Link(path).createSync(link, recursive: true);
          }
        } else if (name == null) {
          _removeFile(path, type);
        } else {
          final backup = File('${dir.path}/backup/$name');
          if (!backup.existsSync()) {
            throw FileSystemException(
              'The copy of ${e.key} made before the change is missing, so it '
              'was not put back. The rest of the change is in '
              '${normalPath(dir.path)}: put back what you need, then delete '
              'that folder',
              backup.path,
            );
          }
          // It was a file: a link made since goes, not what it leads to.
          if (type == FileSystemEntityType.link) {
            retryOnLock(Link(path).deleteSync);
          }
          // A copy, so the file gets its permissions back too.
          copyAtomic(backup, File(path));
        }
        _noteRestored(e.key);
      });
    }
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
    _state = _rolledBack;
    var marked = true;
    try {
      File('${dir.path}/$_rolledBackMarker').writeAsStringSync('', flush: true);
    } on FileSystemException {
      marked = false;
    }
    if (!_cleanUp() && !marked) {
      throw FileSystemException(
        'The change was undone, but its journal could be neither removed nor '
        'marked as undone. Delete ${normalPath(dir.path)} before the next '
        'change, or that change would undo it again',
        _journal.path,
      );
    }
  }

  /// Notes that the backup of [key] was put back. A note that can't be
  /// written only costs putting it back again, should the rollback be run
  /// again.
  void _noteRestored(String key) {
    _restored.add(key);
    try {
      File('${dir.path}/$_restoredLog').writeAsStringSync(
        '${jsonEncode(key)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } on FileSystemException {
      // See above.
    }
  }

  /// Removes the journal first — after that nothing is replayed — then the
  /// rest, and returns whether the journal is gone. Never throws: leftovers
  /// are cleared by the next [recover].
  bool _cleanUp() {
    try {
      if (_journal.existsSync()) retryOnLock(_journal.deleteSync);
    } on FileSystemException {
      // Kept: the next recover finishes or tidies this one.
      return false;
    }
    _deleteQuietly(_staging);
    _deleteQuietly(dir);
    try {
      final root = dir.parent;
      if (root.existsSync() && root.listSync().isEmpty) root.deleteSync();
    } on FileSystemException {
      // Another journal arrived, or it is busy: harmless.
    }
    return true;
  }

  static void _deleteQuietly(Directory d) {
    try {
      if (d.existsSync()) retryOnLock(() => d.deleteSync(recursive: true));
    } on FileSystemException {
      // Harmless leftovers; cleared next time.
    }
  }

  /// Finishes or undoes every change a crash left in [project]: one that
  /// had committed is completed, any other is rolled back. Returns whether
  /// there was one. Hold the [ProjectLock] while calling it. It can be run
  /// any number of times, and after being cut short. A change already
  /// rolled back whose journal could not be removed then is only tidied
  /// away: undoing it again would undo what changed since.
  ///
  /// [alsoIn] names older journal folders to look in too, relative to the
  /// project (a tool that kept its own journals before it built on this
  /// one). A journal that doesn't name its trash — an older one — files
  /// its folders under [trashRoot]/[trash].
  ///
  /// Throws a [FormatException] when a journal can't be read, naming its
  /// folder: its backups are there to put back by hand.
  static bool recover(
    JustProject project, {
    List<String> alsoIn = const [],
    String trash = 'just',
    String trashRoot = defaultTrashRoot,
  }) {
    var found = false;
    for (final rel in [journals, ...alsoIn]) {
      final root = project.dir(rel);
      if (!root.existsSync()) continue;
      // Newest first, so changes are undone in the reverse of their order.
      final dirs = root.listSync().whereType<Directory>().toList()
        ..sort((a, b) => _stampOrder(b.path, a.path));
      for (final d in dirs) {
        final journal = File('${d.path}/journal.json');
        if (!journal.existsSync()) {
          // A cleanup cut short, or a change that never got going.
          _deleteQuietly(d);
          continue;
        }
        if (File('${d.path}/$_rolledBackMarker').existsSync()) {
          ProjectTransaction._(project, d, 'just')._cleanUp();
          continue;
        }
        found = true;
        final t = _read(project, d, journal, trash, trashRoot);
        switch (t._state) {
          case _committed:
            t._finish();
          case _rolledBack:
            t._cleanUp();
          default:
            t.rollBack();
        }
      }
      try {
        if (root.existsSync() && root.listSync().isEmpty) root.deleteSync();
      } on FileSystemException {
        // Busy: harmless, cleared next time.
      }
    }
    return found;
  }

  static ProjectTransaction _read(
    JustProject project,
    Directory d,
    File journal,
    String trash,
    String trashRoot,
  ) {
    try {
      final json = jsonDecode(journal.readAsStringSync()) as Map;
      // Older journals don't say where their trash goes: the caller does.
      final t = ProjectTransaction._(
        project,
        d,
        json['trash'] as String? ?? trash,
        json['trashRoot'] as String? ?? trashRoot,
      ).._state = json['state'] as String;
      final files = (json['backupFiles'] as Map?) ?? const {};
      (json['backups'] as Map).forEach((k, v) {
        // Copies were once named after their path, `/` read as `__`.
        t._backups['$k'] = v as bool
            ? (files[k] as String? ?? '$k'.replaceAll('/', '__'))
            : null;
      });
      ((json['links'] as Map?) ?? const {}).forEach(
        (k, v) => t._links['$k'] = v as String,
      );
      (json['aside'] as Map).forEach((k, v) => t._aside['$k'] = '$v');
      t._movedIn.addAll([for (final p in json['movedIn'] as List) '$p']);
      t._checkReplayable();
      final log = File('${d.path}/$_restoredLog');
      if (log.existsSync()) {
        final text = utf8.decode(log.readAsBytesSync(), allowMalformed: true);
        for (final line in const LineSplitter().convert(text)) {
          try {
            final key = jsonDecode(line);
            if (key is String) t._restored.add(key);
          } on FormatException {
            // A line cut short by a crash: that file is put back again.
          }
        }
      }
      return t;
    } on FormatException catch (e) {
      throw _unreadable(d, e.message);
    } on TypeError catch (e) {
      throw _unreadable(d, '$e');
    }
  }

  static FormatException _unreadable(Directory d, String why) =>
      FormatException(
        'The journal of an unfinished change can\'t be read ($why). Its '
        'backups are in ${normalPath(d.path)}/backup: put back what you '
        'need, then delete that folder.',
      );
}

/// [path] with the symbolic links of the folders on it resolved, and its
/// last part kept as it is (a link stays the link): the deepest of its
/// folders that exists is resolved, and the parts below it — which don't
/// exist, so hold no link — are appended. A link to nothing on the way is
/// followed to where it leads.
String _realFolders(String path) {
  var p = normalPath(File(path).absolute.path);
  for (var hops = 0; hops < 32; hops++) {
    final name = p.substring(p.lastIndexOf('/') + 1);
    final missing = <String>[];
    var dir = File(p).parent;
    String? next;
    while (!dir.existsSync()) {
      if (FileSystemEntity.isLinkSync(dir.path)) {
        final to = Link(dir.path).targetSync();
        final at = File(to).isAbsolute ? to : '${dir.parent.path}/$to';
        next = [normalPath(at), ...missing, name].join('/');
        break;
      }
      final up = dir.parent;
      if (up.path == dir.path) break;
      missing.insert(0, normalPath(dir.path).split('/').last);
      dir = up;
    }
    if (next != null) {
      p = normalPath(File(next).absolute.path);
      continue;
    }
    var base = normalPath(dir.path);
    try {
      if (dir.existsSync()) base = normalPath(dir.resolveSymbolicLinksSync());
    } on FileSystemException {
      // Kept as written.
    }
    final rest = [
      ...missing,
      if (missing.isEmpty) _onDiskName(base, name) else name,
    ].join('/');
    return base.endsWith('/') ? '$base$rest' : '$base/$rest';
  }
  throw FileSystemException('Too many symbolic links', path);
}

/// [name] as it is spelled in the folder [dir], on a disk that ignores
/// case (Windows, macOS): `pubspec.yaml` for `PUBSPEC.YAML`, so a change
/// keeps the file's own name. [name] when it is there as written, isn't
/// there, or is another file (a folder that tells case apart).
String _onDiskName(String dir, String name) {
  if (!Platform.isWindows && !Platform.isMacOS) return name;
  final path = '$dir/$name';
  try {
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return name;
    }
    final lower = name.toLowerCase();
    String? other;
    for (final e in Directory(dir).listSync(followLinks: false)) {
      final n = normalPath(e.path).split('/').last;
      if (n == name) return name;
      if (other == null && n.toLowerCase() == lower) other = n;
    }
    if (other != null && FileSystemEntity.identicalSync(path, '$dir/$other')) {
      return other;
    }
  } on FileSystemException {
    // Kept as written.
  }
  return name;
}

/// Removes the file or symbolic link at [path] (of [type]); a folder, or
/// nothing, is left as it is.
void _removeFile(String path, FileSystemEntityType type) {
  if (type == FileSystemEntityType.link) {
    retryOnLock(Link(path).deleteSync);
  } else if (type == FileSystemEntityType.file) {
    retryOnLock(File(path).deleteSync);
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// [t] as a stamp for folder names: `20261009-142501-042`.
String timeStamp(DateTime t) =>
    '${t.year}${_two(t.month)}${_two(t.day)}-${_two(t.hour)}${_two(t.minute)}'
    '${_two(t.second)}-${t.millisecond.toString().padLeft(3, '0')}';

String _two(int n) => n.toString().padLeft(2, '0');

/// Orders two journal folders by their stamps: `<stamp>` before
/// `<stamp>-2` before `<stamp>-10` (the number a second change in the same
/// millisecond adds), and by the stamp itself first.
int _stampOrder(String a, String b) {
  (String, int) key(String path) {
    final name = path.replaceAll(r'\', '/').split('/').last;
    final parts = name.split('-');
    if (parts.length == 4) {
      return (parts.take(3).join('-'), int.tryParse(parts[3]) ?? 0);
    }
    return (name, 0);
  }

  final (sa, na) = key(a);
  final (sb, nb) = key(b);
  final c = sa.compareTo(sb);
  return c != 0 ? c : na.compareTo(nb);
}

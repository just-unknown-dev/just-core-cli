/// Plugins: packages that add commands to `just`.
library;

import 'dart:convert';
import 'dart:io';

import '../json/json.dart';
import '../project/just_project.dart';
import '../project/package_info.dart';
import '../project/user_paths.dart';
import 'plugin_manifest.dart';

export 'plugin_manifest.dart';

/// Where a plugin was found.
enum PluginScope {
  /// One of the project's packages, at the version the project resolved.
  project,

  /// A package activated with `dart pub global activate`.
  global,
}

/// Where pub got a plugin's package from, as the `pubspec.lock` that
/// resolved it says.
final class PluginSource {
  /// A package from [kind] (`path`, `git`, `hosted`, `sdk` or `unknown`),
  /// at [url] (git and hosted) or [path] (path, absolute).
  const PluginSource(this.kind, {this.url, this.path});

  /// A package whose source no lockfile names.
  static const PluginSource unknown = PluginSource('unknown');

  /// `path`, `git`, `hosted`, `sdk`, or `unknown`.
  final String kind;

  /// The repository (git) or the package server (hosted).
  final String? url;

  /// The package's folder, for a path source: absolute, `/` between parts.
  final String? path;

  /// Whether it comes from the ecosystem itself: a local checkout (a path
  /// dependency) or the ecosystem's own GitHub repositories
  /// ([PluginTrust.isEcosystemRepository]). pub.dev counts only for the
  /// names the ecosystem has published there ([PluginTrust.onPubDev]);
  /// see [PluginTrust.isOfficial].
  bool get isEcosystem =>
      kind == 'path' ||
      (kind == 'git' && url != null && PluginTrust.isEcosystemRepository(url!));

  /// Whether it comes from pub.dev itself ([PluginTrust.isPubDev]).
  bool get isPubDev =>
      kind == 'hosted' && url != null && PluginTrust.isPubDev(url!);

  /// Every package's source in the `pubspec.lock` at [lockPath], by name;
  /// empty when there is none. A relative path is read from the lockfile's
  /// folder.
  static Map<String, PluginSource> readLock(String lockPath) {
    final file = File(lockPath);
    if (!file.existsSync()) return const {};
    final String text;
    try {
      text = file.readAsStringSync();
    } on FileSystemException {
      return const {};
    }
    final base = normalPath(file.absolute.parent.path);
    final out = <String, PluginSource>{};
    String? name;
    String? kind, url, path;
    var relative = false;
    var inPackages = false;
    var inDescription = false;

    void flush() {
      if (name == null) return;
      var where = path;
      if (where != null && relative && !File(where).isAbsolute) {
        where = '$base/$where';
      }
      out[name!] = PluginSource(
        kind ?? 'unknown',
        url: url,
        path: where == null
            ? null
            : normalPath(
                Directory(where).absolute.uri.normalizePath().toFilePath(),
              ),
      );
      name = kind = url = path = null;
      relative = false;
    }

    final line = RegExp(r'^( *)([A-Za-z0-9_.-]+):\s*(.*)$');
    for (final raw in const LineSplitter().convert(text)) {
      if (raw.trim().isEmpty || raw.trimLeft().startsWith('#')) continue;
      final m = line.firstMatch(raw.trimRight());
      if (m == null) continue;
      final indent = m.group(1)!.length;
      final key = m.group(2)!;
      final value = _unquote(m.group(3)!);
      if (indent == 0) {
        flush();
        inPackages = key == 'packages';
        continue;
      }
      if (!inPackages) continue;
      if (indent == 2) {
        flush();
        name = key;
        inDescription = false;
      } else if (indent == 4) {
        inDescription = key == 'description' && value.isEmpty;
        if (key == 'source') kind = value;
      } else if (indent == 6 && inDescription) {
        switch (key) {
          case 'url':
            url = value;
          case 'path':
            path = value;
          case 'relative':
            relative = value == 'true';
        }
      }
    }
    flush();
    return out;
  }

  static String _unquote(String value) {
    final v = value.trim();
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      return v
          .substring(1, v.length - 1)
          .replaceAllMapped(RegExp(r'\\(.)'), (m) => m.group(1)!);
    }
    if (v.length >= 2 && v.startsWith("'") && v.endsWith("'")) {
      return v.substring(1, v.length - 1).replaceAll("''", "'");
    }
    return v;
  }
}

/// A package that adds commands to `just`.
final class Plugin {
  /// The plugin [package] in [root], adding what [manifest] says, from
  /// [source].
  const Plugin({
    required this.package,
    required this.root,
    required this.manifest,
    required this.scope,
    this.source = PluginSource.unknown,
  });

  /// The package's name.
  final String package;

  /// The package's folder.
  final String root;

  /// What it adds.
  final PluginManifest manifest;

  /// Where it was found.
  final PluginScope scope;

  /// Where pub got it from.
  final PluginSource source;

  /// The package's version, from its pubspec; null when it has none.
  String? get version {
    final f = File('$root/pubspec.yaml');
    if (!f.existsSync()) return null;
    return RegExp(
      r'^version:\s*([^\s#]+)',
      multiLine: true,
    ).firstMatch(f.readAsStringSync())?.group(1);
  }
}

/// Finds plugins: in the project's packages, and among the packages
/// activated globally.
abstract final class PluginFinder {
  /// The plugins among [project]'s resolved packages (none before
  /// `pub get`), each with its source from the `pubspec.lock` beside the
  /// resolution — the project's, or its pub workspace's. A package with a
  /// broken manifest is left out and named in [problems].
  static List<Plugin> inProject(JustProject project, {List<String>? problems}) {
    final config = PackageConfig.read(project.root);
    if (config == null) return const [];
    final lock = PluginSource.readLock('${config.root}/pubspec.lock');
    final resolvedIn = JustProject(config.root);
    PluginSource sourceOf(ResolvedPackage p) {
      // The project itself is a local folder, whatever the lock says.
      if (samePath(p.rootPath, project.root)) {
        return PluginSource('path', path: project.root);
      }
      final locked = lock[p.name];
      if (locked != null) return locked;
      // Not in the lock, yet inside the folder pub resolved in: the
      // workspace's root or one of its members, which no lock lists.
      return resolvedIn.relativeOf(p.rootPath) != null
          ? PluginSource('path', path: p.rootPath)
          : PluginSource.unknown;
    }

    return _from(
      [for (final p in config.packages.values) (p, sourceOf(p))],
      PluginScope.project,
      problems,
    );
  }

  /// The plugins activated with `dart pub global activate`, from pub's
  /// cache ([pubCache], or the default for this machine) — from pub.dev or
  /// git (`global_packages/<name>/.dart_tool/package_config.json`), or from
  /// a folder (`--source path`, whose `pubspec.lock` names the folder).
  static List<Plugin> global({
    String? pubCache,
    Map<String, String>? environment,
    List<String>? problems,
  }) {
    final cache = pubCache ?? pubCacheDir(environment: environment);
    if (cache == null) return const [];
    final root = Directory('$cache/global_packages');
    if (!root.existsSync()) return const [];
    final found = <(ResolvedPackage, PluginSource)>[];
    for (final d in root.listSync().whereType<Directory>()) {
      final name = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final lock = PluginSource.readLock('${d.path}/pubspec.lock');
      final source = lock[name] ?? PluginSource.unknown;
      var own = PackageConfig.read(d.path)?.packages[name];
      if (own == null && source.kind == 'path' && source.path != null) {
        own = ResolvedPackage(name, source.path!, '${source.path}/lib');
      }
      if (own != null) found.add((own, source));
    }
    return _from(found, PluginScope.global, problems);
  }

  static List<Plugin> _from(
    Iterable<(ResolvedPackage, PluginSource)> packages,
    PluginScope scope,
    List<String>? problems,
  ) {
    final out = <Plugin>[];
    for (final (p, source) in packages) {
      final file = File('${p.rootPath}/${PluginManifest.fileName}');
      if (!file.existsSync()) continue;
      try {
        out.add(
          Plugin(
            package: p.name,
            root: p.rootPath,
            manifest: PluginManifest.parse(file.readAsStringSync()),
            scope: scope,
            source: source,
          ),
        );
      } on JsonFormatException catch (e) {
        problems?.add('${p.name}: ${e.inFile(PluginManifest.fileName)}');
      } on FileSystemException catch (e) {
        // Not UTF-8, or unreadable: the plugin is left out, not the run.
        problems?.add(
          '${p.name}: ${PluginManifest.fileName} could not be read '
          '(${e.message}).',
        );
      }
    }
    out.sort((a, b) => a.package.compareTo(b.package));
    return out;
  }

  /// Pub's cache folder: `PUB_CACHE`, else `%LOCALAPPDATA%\Pub\Cache` on
  /// Windows and `~/.pub-cache` elsewhere.
  static String? pubCacheDir({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final set = env['PUB_CACHE'];
    if (set != null && set.isNotEmpty) return normalPath(set);
    if (Platform.isWindows) {
      final local = env['LOCALAPPDATA'];
      return local == null ? null : '${normalPath(local)}/Pub/Cache';
    }
    final home = env['HOME'];
    return home == null ? null : '$home/.pub-cache';
  }
}

/// Which plugins may run without asking.
///
/// A plugin is code from a package, run on the user's machine. The Just
/// ecosystem's own packages ([official]) run without asking when they
/// come from a local checkout or the ecosystem's GitHub repositories
/// ([PluginSource.isEcosystem]), or from pub.dev under a name in
/// [onPubDev]. Any other plugin asks once, and the answer is kept: in the
/// project's `just.json` (`plugins.allowed`), or for every project in the
/// user's [UserPluginAllowList]. That includes an official name from
/// pub.dev that isn't in [onPubDev] (until the ecosystem publishes it,
/// anyone could) and one from another package server or someone else's
/// repository. `--yes` never allows a plugin.
///
/// A name goes into [onPubDev] in the just_core_cli release that goes out
/// with that package's first publication, and the package is published
/// right after it: a plugin depends on just_core_cli, so it can't go
/// first.
abstract final class PluginTrust {
  /// The ecosystem's own packages. Exact names — another package called
  /// `just_something` is asked about like any other.
  static const Set<String> official = {
    'just_asset_store',
    'just_audio_engine',
    'just_box_2d',
    'just_core_cli',
    'just_colours',
    'just_dart',
    'just_debugger',
    'just_deflate',
    'just_editor_core',
    'just_game_engine',
    'just_game_engine_cli',
    'just_game_engine_editor',
    'just_game_engine_formats',
    'just_game_services',
    'just_gamepads',
    'just_graphics_engine',
    'just_input_editor',
    'just_inputs',
    'just_jolt',
    'just_material_editor',
    'just_physics_engine',
    'just_platformer_kit',
    'just_sprite_editor',
    'just_third_person_kit',
    'just_tiled',
    'just_ui_editor',
    'just_world_builder_kit',
    'just_zstd',
  };

  /// The GitHub account the ecosystem's repositories are in.
  static const String ecosystemOwner = 'just-unknown-dev';

  /// The [official] names the ecosystem publishes on pub.dev, from its own
  /// publisher: from there they are trusted too. Each is published right
  /// after the just_core_cli release that first lists it
  /// (just_game_engine_cli after 0.1.0, just_asset_store after 0.1.1); no
  /// other name belongs here, as any other could be anyone's on pub.dev.
  static const Set<String> onPubDev = {
    'just_asset_store',
    'just_game_engine_cli',
  };

  /// Whether [plugin] is one of the ecosystem's own: an [official] name
  /// from a local checkout or the ecosystem's repositories, or an
  /// [onPubDev] name from pub.dev.
  static bool isOfficial(Plugin plugin) =>
      official.contains(plugin.package) &&
      (plugin.source.isEcosystem ||
          (plugin.source.isPubDev && onPubDev.contains(plugin.package)));

  /// Whether [plugin] may run without asking, given the [allowed] list.
  static bool trusted(Plugin plugin, Iterable<String> allowed) =>
      isOfficial(plugin) || allowed.contains(plugin.package);

  /// Whether the package server [url] is pub.dev itself (`https://pub.dev`).
  static bool isPubDev(String url) {
    final uri = Uri.tryParse(url.trim());
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.toLowerCase() == 'pub.dev' &&
        !uri.hasPort &&
        uri.pathSegments.every((s) => s.isEmpty);
  }

  /// Whether the git [url] is one of [ecosystemOwner]'s repositories on
  /// github.com (`https://`, `ssh://` or `git@github.com:`).
  static bool isEcosystemRepository(String url) {
    final scp = RegExp(r'^[\w.-]+@github\.com:([^/]+)/').firstMatch(url);
    if (scp != null) return scp.group(1)!.toLowerCase() == ecosystemOwner;
    final uri = Uri.tryParse(url);
    if (uri == null || !const {'https', 'ssh'}.contains(uri.scheme)) {
      return false;
    }
    final host = uri.host.toLowerCase();
    if (host != 'github.com' && host != 'www.github.com') return false;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    return segments.length >= 2 &&
        segments.first.toLowerCase() == ecosystemOwner;
  }
}

/// The global plugins this user allowed: `plugins.json` in the tool's
/// settings folder ([UserPaths.configDir]), `{"allowed": ["my_tools"]}`.
abstract final class UserPluginAllowList {
  /// The file's path, or null when there is no settings folder.
  static String? path({Map<String, String>? environment}) {
    final dir = UserPaths.configDir(environment: environment);
    return dir == null ? null : '$dir/plugins.json';
  }

  /// The allowed packages; empty when there is no file or it is broken.
  static List<String> read({Map<String, String>? environment}) {
    final p = path(environment: environment);
    if (p == null || !File(p).existsSync()) return const [];
    try {
      final json = jsonDecode(File(p).readAsStringSync());
      final allowed = json is Map ? json['allowed'] : null;
      return allowed is List
          ? [
              for (final a in allowed)
                if (a is String) a,
            ]
          : const [];
    } on FormatException {
      return const [];
    } on FileSystemException {
      return const [];
    }
  }

  /// Adds [package] to the list. Throws [StateError] when there is no
  /// settings folder.
  static void add(String package, {Map<String, String>? environment}) {
    final p = path(environment: environment);
    if (p == null) {
      throw StateError('No settings folder: HOME or APPDATA is not set.');
    }
    final allowed = {...read(environment: environment), package}.toList()
      ..sort();
    writeTextAtomic(
      File(p),
      '${const JsonEncoder.withIndent('  ').convert({'allowed': allowed})}\n',
    );
  }
}

/// What pub resolved: `.dart_tool/package_config.json` and
/// `.dart_tool/package_graph.json`.
library;

import 'dart:convert';
import 'dart:io';

import '../json/semver.dart';

/// A package pub resolved, and where it is on disk.
final class ResolvedPackage {
  /// [name] at [rootPath].
  const ResolvedPackage(this.name, this.rootPath, this.libPath);

  /// The package's name.
  final String name;

  /// Its folder, absolute, with `/` between parts.
  final String rootPath;

  /// Its `lib/` folder, absolute.
  final String libPath;

  /// Whether it lives in pub's shared cache, where nothing may be edited.
  bool get isInPubCache => inPubCache();

  /// The version its pubspec declares, or null when it declares none (or
  /// it can't be read).
  Version? get version {
    try {
      final pubspec = File('$rootPath/pubspec.yaml');
      if (!pubspec.existsSync()) return null;
      final v = RegExp(
        r'^version:\s*([^\s#]+)',
        multiLine: true,
      ).firstMatch(pubspec.readAsStringSync())?.group(1);
      return v == null
          ? null
          : Version.tryParse(v.replaceAll('"', '').replaceAll("'", ''));
    } on FileSystemException {
      return null;
    }
  }

  /// Whether it lives in pub's shared cache: the default one, or the one
  /// `PUB_CACHE` names in [environment] (this process's by default).
  bool inPubCache({Map<String, String>? environment}) {
    final p = rootPath.toLowerCase();
    if (p.contains('/pub/cache/') || p.contains('/.pub-cache/')) return true;
    final set = (environment ?? Platform.environment)['PUB_CACHE']?.trim();
    if (set == null || set.isEmpty) return false;
    var cache = Directory(set).absolute.path.replaceAll(r'\', '/');
    while (cache.endsWith('/')) {
      cache = cache.substring(0, cache.length - 1);
    }
    final ignoreCase = Platform.isWindows || Platform.isMacOS;
    final root = ignoreCase ? p : rootPath;
    final prefix = ignoreCase ? '${cache.toLowerCase()}/' : '$cache/';
    return root.startsWith(prefix);
  }
}

/// `.dart_tool/package_config.json`: every package in the resolution and
/// its folder, plus the Flutter SDK that resolved it.
final class PackageConfig {
  const PackageConfig._(
    this.root,
    this.packages,
    this.flutterRoot,
    this.flutterVersion,
  );

  /// The project's config, or null when pub has not run. For a member of a
  /// pub workspace (`resolution: workspace`) it is the workspace's.
  static PackageConfig? read(String projectRoot) {
    final file = _resolvedFile(projectRoot, 'package_config.json');
    if (file == null) return null;
    final json = _readJson(file);
    if (json is! Map) return null;
    final base = file.parent.absolute.uri;
    final packages = <String, ResolvedPackage>{};
    for (final p in _list(json['packages'])) {
      if (p is! Map) continue;
      final name = p['name'];
      final rootUri = p['rootUri'];
      if (name is! String || rootUri is! String) continue;
      final root = base.resolve(rootUri.endsWith('/') ? rootUri : '$rootUri/');
      final packageUri = p['packageUri'];
      final lib = root.resolve(packageUri is String ? packageUri : 'lib/');
      packages[name] = ResolvedPackage(name, _path(root), _path(lib));
    }
    final flutterRoot = json['flutterRoot'];
    return PackageConfig._(
      _path(base.resolve('../')),
      packages,
      flutterRoot is String ? _path(Uri.parse(flutterRoot)) : null,
      json['flutterVersion'] is String
          ? json['flutterVersion'] as String
          : null,
    );
  }

  /// The folder pub resolved in, with `/` between parts: the project
  /// itself, or — for a member of a pub workspace — the workspace's root.
  /// Its `pubspec.lock` is the one that goes with these packages.
  final String root;

  /// The resolved packages, by name.
  final Map<String, ResolvedPackage> packages;

  /// The Flutter SDK folder that ran pub, when it was Flutter's.
  final String? flutterRoot;

  /// That SDK's version.
  final String? flutterVersion;
}

/// One package in [PackageGraph].
final class GraphNode {
  /// [name] at [version], depending on [dependencies] and, for root
  /// packages, [devDependencies].
  const GraphNode(
    this.name,
    this.version,
    this.dependencies,
    this.devDependencies,
  );

  /// The package's name.
  final String name;

  /// Its resolved version, when it has a valid one.
  final Version? version;

  /// What it depends on.
  final List<String> dependencies;

  /// What it depends on for development (root packages only).
  final List<String> devDependencies;
}

/// `.dart_tool/package_graph.json`: who depends on whom, and at which
/// version — what a tool checks constraints against, since overrides
/// skip pub's own checks.
final class PackageGraph {
  const PackageGraph._(this.roots, this.nodes);

  /// The project's graph, or null when pub has not written one. For a
  /// member of a pub workspace it is the workspace's.
  static PackageGraph? read(String projectRoot) {
    final file = _resolvedFile(projectRoot, 'package_graph.json');
    if (file == null) return null;
    final json = _readJson(file);
    if (json is! Map) return null;
    final nodes = <String, GraphNode>{};
    for (final p in _list(json['packages'])) {
      if (p is! Map || p['name'] is! String) continue;
      final name = p['name'] as String;
      nodes[name] = GraphNode(
        name,
        Version.tryParse('${p['version'] ?? ''}'),
        [for (final d in _list(p['dependencies'])) '$d'],
        [for (final d in _list(p['devDependencies'])) '$d'],
      );
    }
    return PackageGraph._([for (final r in _list(json['roots'])) '$r'], nodes);
  }

  /// The project's own package (and workspace members).
  final List<String> roots;

  /// Every package, by name.
  final Map<String, GraphNode> nodes;

  /// [name]'s resolved version, or null.
  Version? versionOf(String name) => nodes[name]?.version;

  /// The packages that depend on [name] directly (dev dependencies of the
  /// roots included).
  Set<String> dependentsOf(String name) => {
    for (final n in nodes.values)
      if (n.dependencies.contains(name) || n.devDependencies.contains(name))
        n.name,
  };

  /// Whether a release build can reach [name]: it is a dependency (not
  /// only a dev dependency) of a root, directly or through others.
  bool shipsWithApp(String name) {
    final seen = <String>{};
    final queue = [for (final r in roots) ...?nodes[r]?.dependencies];
    while (queue.isNotEmpty) {
      final next = queue.removeLast();
      if (!seen.add(next)) continue;
      if (next == name) return true;
      queue.addAll(nodes[next]?.dependencies ?? const []);
    }
    return false;
  }
}

/// The file [name] pub wrote in `.dart_tool/` for [projectRoot]: its own,
/// or — for a member of a pub workspace — the workspace root's.
File? _resolvedFile(String projectRoot, String name) {
  final own = File('$projectRoot/.dart_tool/$name');
  if (own.existsSync()) return own;
  // pub leaves members a pointer to the workspace root, relative to
  // `.dart_tool/pub/`.
  final ref = File('$projectRoot/.dart_tool/pub/workspace_ref.json');
  final json = ref.existsSync() ? _readJson(ref) : null;
  final rel = json is Map ? json['workspaceRoot'] : null;
  if (rel is String && rel.isNotEmpty) {
    final root = File(rel).isAbsolute
        ? rel
        : '$projectRoot/.dart_tool/pub/${rel.replaceAll(r'\', '/')}';
    final file = File('$root/.dart_tool/$name');
    if (file.existsSync()) return file;
  }
  // A member pub hasn't written the pointer for: the nearest folder above.
  final pubspec = File('$projectRoot/pubspec.yaml');
  try {
    if (!pubspec.existsSync() ||
        !RegExp(
          r'^resolution\s*:\s*workspace\s*(#.*)?$',
          multiLine: true,
        ).hasMatch(pubspec.readAsStringSync())) {
      return null;
    }
  } on FileSystemException {
    return null;
  }
  var dir = Directory(projectRoot).absolute.parent;
  while (true) {
    final file = File('${dir.path}/.dart_tool/$name');
    if (file.existsSync()) return file;
    final up = dir.parent;
    if (up.path == dir.path) return null;
    dir = up;
  }
}

/// [value] if it is a list, else an empty one.
List<Object?> _list(Object? value) => value is List ? value : const [];

/// [file] as JSON, or null when it can't be read or isn't JSON.
Object? _readJson(File file) {
  try {
    return jsonDecode(file.readAsStringSync());
  } on FormatException {
    return null;
  } on FileSystemException {
    return null;
  }
}

String _path(Uri uri) {
  var p = uri.toFilePath(windows: Platform.isWindows).replaceAll(r'\', '/');
  while (p.length > 1 && p.endsWith('/') && !p.endsWith(':/')) {
    p = p.substring(0, p.length - 1);
  }
  return p;
}

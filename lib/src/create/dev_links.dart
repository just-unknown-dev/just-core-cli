/// Linking a project to local checkouts of the ecosystem's packages.
library;

import 'dart:io';

import '../project/just_project.dart';
import '../project/pubspec_editor.dart';

/// A local checkout of one of the ecosystem's packages.
final class Checkout {
  /// The package [name] in [path] (absolute, `/` between parts).
  const Checkout(this.name, this.path);

  /// The package's name.
  final String name;

  /// Its folder.
  final String path;
}

/// The same package checked out in more than one of the folders given to
/// [DevLinks.scanAll].
final class DevLinkClash implements Exception {
  /// [name], found at each of [paths].
  const DevLinkClash(this.name, this.paths);

  /// The package's name.
  final String name;

  /// Its checkouts.
  final List<String> paths;

  @override
  String toString() =>
      '$name is checked out in more than one folder (${paths.join(', ')}). '
      'Delete the copy you no longer use, or link only the folders you mean.';
}

/// Path overrides from a project to local checkouts, in `just dev link`'s
/// own block of `pubspec_overrides.yaml` — never `pubspec.yaml`, because the
/// paths are this machine's.
abstract final class DevLinks {
  /// The ecosystem packages in [dir]: each folder holding a pubspec whose
  /// name is the folder's and starts with `just_`. Old copies (`*_old`) are
  /// skipped.
  static List<Checkout> scan(Directory dir) {
    final out = <Checkout>[];
    if (!dir.existsSync()) return out;
    for (final d in dir.listSync().whereType<Directory>()) {
      final folder = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!folder.startsWith('just_') || folder.endsWith('_old')) continue;
      final pubspec = File('${d.path}/pubspec.yaml');
      if (!pubspec.existsSync()) continue;
      final name = RegExp(
        r'^name:\s*(\S+)',
        multiLine: true,
      ).firstMatch(pubspec.readAsStringSync())?.group(1);
      if (name == null || name != folder) continue;
      out.add(Checkout(name, normalPath(d.absolute.path)));
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  /// The ecosystem packages in each of [dirs] — say a workspace's
  /// `packages/` and `plugins/` — in name order. A package checked out in
  /// two of them throws [DevLinkClash]: which one to link is for the
  /// developer to say.
  static List<Checkout> scanAll(Iterable<Directory> dirs) {
    final byName = <String, Checkout>{};
    for (final dir in dirs) {
      for (final c in scan(dir)) {
        final seen = byName[c.name];
        if (seen != null && seen.path != c.path) {
          throw DevLinkClash(c.name, [seen.path, c.path]);
        }
        byName[c.name] = c;
      }
    }
    return byName.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  /// [path]'s path from [project]: relative when it can be, so a project
  /// and its packages can move together.
  static String pathFrom(JustProject project, String path) =>
      project.pathTo(path);

  /// The new text of [project]'s `pubspec_overrides.yaml` with exactly
  /// [checkouts] in the dev-link block (none removes it).
  static String overridesText(JustProject project, List<Checkout> checkouts) {
    final current = project.readText(JustProject.overrides) ?? '';
    final editor = PubspecEditor.parse(current, marker: ManagedBlock.devLinks)
      ..setManaged('dependency_overrides', {
        for (final c in checkouts)
          c.name: PathDependency(pathFrom(project, c.path)),
      });
    return editor.text;
  }

  /// The checkouts [project] links now, by name → path, from its block.
  static Map<String, String> linked(JustProject project) {
    final text = project.readText(JustProject.overrides);
    if (text == null) return const {};
    final editor = PubspecEditor.parse(text, marker: ManagedBlock.devLinks);
    return {
      for (final e in editor.managed('dependency_overrides').entries)
        if (e.value case PathDependency(:final path)) e.key: path,
    };
  }
}

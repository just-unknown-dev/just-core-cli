/// A project's own just_core_cli, and handing a run over to it.
library;

import 'dart:io';

import '../project/just_project.dart';
import '../project/package_info.dart';

/// The version of just_core_cli a project pins (as a dev dependency), so every
/// teammate runs the same `just` on it, whatever their global one is — the
/// way the Gradle wrapper works.
///
/// When a global `just` runs in a project that resolved another just_core_cli
/// version, it hands the run over: `dart run just_core_cli:just <arguments>` in
/// the project, with `JUST_CORE_CLI_DELEGATED=1` so the project's `just` doesn't
/// hand it over again.
abstract final class ProjectPin {
  /// The environment variable a handed-over run carries.
  static const String delegatedVariable = 'JUST_CORE_CLI_DELEGATED';

  /// The folder the user ran `just` in, passed to a run started in the
  /// project root, so relative paths still mean what they meant.
  static const String cwdVariable = 'JUST_CORE_CLI_CWD';

  /// The just_core_cli version [project] resolved, or null when it doesn't depend
  /// on just_core_cli or pub hasn't run.
  static String? resolvedVersion(JustProject project) {
    final own = PackageConfig.read(project.root)?.packages['just_core_cli'];
    if (own == null) return null;
    return pubspecVersion('${own.rootPath}/pubspec.yaml');
  }

  /// Whether [project]'s pubspec names just_core_cli as a dependency.
  static bool declares(JustProject project) {
    final text = project.readText(JustProject.pubspec);
    return text != null &&
        RegExp(r'^\s+just_core_cli\s*:', multiLine: true).hasMatch(text);
  }

  /// Whether pub has run in [project] (or, for a pub workspace member, in
  /// its workspace).
  static bool resolved(JustProject project) =>
      PackageConfig.read(project.root) != null;
}

/// The `version:` in the pubspec at [path], or null.
String? pubspecVersion(String path) {
  final f = File(path);
  if (!f.existsSync()) return null;
  return RegExp(
    r'^version:\s*([^\s#]+)',
    multiLine: true,
  ).firstMatch(f.readAsStringSync())?.group(1);
}

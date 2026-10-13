/// The names `just` gives a project's files and folders.
library;

/// Where things are in a project, relative to its root, with `/` between
/// parts — the names alone, so code on any platform (the web included) can
/// use them. `JustProject` (in `package:just_core_cli/project.dart`) finds
/// them on disk.
abstract final class ProjectPaths {
  /// The project's pubspec.
  static const String pubspec = 'pubspec.yaml';

  /// The overrides file pub reads instead of the pubspec's overrides.
  static const String overrides = 'pubspec_overrides.yaml';

  /// The project's `just.json`: its title, tool set and entry points.
  static const String projectFile = 'just.json';

  /// The tools' scratch folder: transaction journals, staging, the lock.
  static const String workDir = '.dart_tool/just_core_cli';

  /// The folder installed packages go into.
  static const String packagesDir = 'packages';

  /// Where a change's replaced and removed folders go unless its tool keeps
  /// a trash of its own: `.just_trash/<tool>/<stamp>/`.
  static const String trashRoot = '.just_trash';
}

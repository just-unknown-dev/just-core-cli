/// Which file pub reads its overrides from.
library;

import 'dart:io';

import 'just_project.dart';

/// Where a tool writes `dependency_overrides`.
///
/// While `pubspec_overrides.yaml` exists, pub ignores the
/// `dependency_overrides` in `pubspec.yaml` completely, so a tool must
/// write to the file pub actually reads ([active]). When that file is
/// ignored by git (as in the templates), a clone wouldn't have it, so the
/// same block is also written into `pubspec.yaml` ([mirror]): inert here,
/// effective everywhere else.
final class OverridesTarget {
  /// Overrides go to [active], and also to [mirror] when set.
  const OverridesTarget(this.active, {this.mirror});

  /// The file pub reads overrides from.
  final String active;

  /// The committed file that also gets them, when [active] isn't committed.
  final String? mirror;

  /// Both files, [active] first.
  List<String> get files => [active, ?mirror];

  /// Works out the target for [project].
  static Future<OverridesTarget> detect(JustProject project) async {
    if (!project.file(JustProject.overrides).existsSync()) {
      return const OverridesTarget(JustProject.pubspec);
    }
    final ignored = await isGitIgnored(project, JustProject.overrides);
    return OverridesTarget(
      JustProject.overrides,
      mirror: ignored ? JustProject.pubspec : null,
    );
  }

  /// Whether git ignores [relative] in [project]: asks git, and reads
  /// `.gitignore` when git isn't available.
  static Future<bool> isGitIgnored(JustProject project, String relative) async {
    try {
      final result = await Process.run('git', [
        'check-ignore',
        '-q',
        relative,
      ], workingDirectory: project.root);
      if (result.exitCode == 0) return true;
      if (result.exitCode == 1) return false;
    } on ProcessException {
      // No git: read the ignore file.
    }
    final ignore = project.file('.gitignore');
    if (!ignore.existsSync()) return false;
    for (final raw in ignore.readAsLinesSync()) {
      final line = raw.trim();
      if (line == relative || line == '/$relative' || line == '**/$relative') {
        return true;
      }
    }
    return false;
  }
}

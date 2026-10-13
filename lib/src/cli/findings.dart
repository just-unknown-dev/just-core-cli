/// What a check found: `just doctor`'s findings, and a plugin's own
/// `doctor` hook's. Printed with `Output.findings`.
library;

import '../json/json.dart';

/// How bad a finding is.
enum Severity {
  /// All is well.
  ok,

  /// Worth fixing; nothing is broken yet.
  warning,

  /// Broken, or will break: a build, a teammate's clone, a release.
  problem,
}

/// One thing a check found.
final class Finding {
  /// [message] at [severity], with [fix] saying what to do.
  const Finding(this.severity, this.message, {this.fix});

  /// How bad it is.
  final Severity severity;

  /// What was found.
  final String message;

  /// What to do about it.
  final String? fix;

  /// This finding for `--json`.
  Map<String, Object?> toJson() =>
      compactJson({'severity': severity.name, 'message': message, 'fix': fix});

  /// The mark `just doctor` prints before it: `ok`, `!` or `x`.
  String get mark => switch (severity) {
    Severity.ok => 'ok',
    Severity.warning => ' !',
    Severity.problem => ' x',
  };
}

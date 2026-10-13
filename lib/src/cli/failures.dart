/// How a command says it failed, and the exit codes that follow.
library;

/// The exit codes every `just` command uses.
abstract final class ExitCodes {
  /// It worked (or there was nothing to do).
  static const int ok = 0;

  /// It failed: the message says why. Nothing was left half done.
  static const int failure = 1;

  /// It was called wrongly: an unknown command, a missing argument, a bad
  /// option.
  static const int usage = 2;
}

/// A command failed in a way the user can act on. The runner prints
/// [message] (no stack trace) and exits with [exitCode].
final class CommandFailure implements Exception {
  /// A failure explained by [message].
  const CommandFailure(this.message, {this.exitCode = ExitCodes.failure});

  /// What went wrong, and what to do about it.
  final String message;

  /// The process's exit code.
  final int exitCode;

  @override
  String toString() => message;
}

/// A command was called wrongly. Exits with [ExitCodes.usage], printing the
/// command's usage after [message].
final class UsageFailure implements Exception {
  /// A misuse explained by [message].
  const UsageFailure(this.message);

  /// What was wrong with the call.
  final String message;

  @override
  String toString() => message;
}

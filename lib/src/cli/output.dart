/// How commands report: lines for a person, or one JSON document.
library;

import 'dart:convert';

import 'context.dart';
import 'findings.dart';

/// What a command prints.
///
/// In text mode, [line]s go to the context's `out` as they come, and
/// [info], [warn] and [error] to `err`. With `--json`, nothing reaches `out`
/// until the command ends; then the runner prints one document:
///
/// ```json
/// {"ok": true, "command": "dev link", "exitCode": 0, "result": {...},
///  "warnings": ["..."], "error": null}
/// ```
///
/// [info] and [warn] still go to `err`, so a script that reads `out` gets
/// only JSON, and a person watching still sees progress.
final class Output {
  /// Output for a run in [context], as JSON when [json].
  Output(this.context, {required this.json, this.verbose = false});

  /// Where it prints.
  final JustContext context;

  /// Whether the run ends with one JSON document instead of lines.
  final bool json;

  /// Whether [detail] messages are shown.
  final bool verbose;

  /// What the command found or did, for `--json`. Commands set it.
  Object? result;

  final List<String> _warnings = [];

  /// The warnings so far.
  List<String> get warnings => List.unmodifiable(_warnings);

  /// A line of the command's result: the text a person reads, and what a
  /// script would parse were it not for `--json`. Dropped with `--json`,
  /// where [result] carries it instead.
  void line([String text = '']) {
    if (!json) context.out.writeln(text);
  }

  /// Progress or a note for the person watching.
  void info(String text) => context.err.writeln(text);

  /// Something the user should know, that didn't stop the command.
  void warn(String text) {
    _warnings.add(text);
    context.err.writeln('! $text');
  }

  /// Prints [found] as `just doctor` does — a mark ([Finding.mark]) and the
  /// message, the fix below it — and returns whether any is a
  /// [Severity.problem].
  bool findings(Iterable<Finding> found) {
    var problem = false;
    for (final f in found) {
      line('${f.mark} ${f.message}');
      if (f.fix != null) line('     ${f.fix}');
      if (f.severity == Severity.problem) problem = true;
    }
    return problem;
  }

  /// Extra detail, shown with `--verbose`.
  void detail(String text) {
    if (verbose) context.err.writeln(text);
  }

  /// Prints the JSON document for a run that ended with [exitCode] (an
  /// [error] message when it failed). Does nothing in text mode.
  void finish({required String command, required int exitCode, String? error}) {
    if (!json) return;
    context.out.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'ok': exitCode == 0,
        'command': command,
        'exitCode': exitCode,
        'result': result,
        'warnings': _warnings,
        'error': error,
      }),
    );
  }
}

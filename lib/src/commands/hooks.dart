/// Running the plugins' hooks: what `create`, `check`, `doctor` and
/// `upgrade` ask the installed plugins to do for themselves.
library;

import 'dart:convert';

import '../cli/command.dart';
import '../cli/plugin_command.dart';
import '../cli/plugins.dart';
import '../json/json.dart';
import '../project/just_project.dart';

/// The plugins in [project] that have a [hook] and may run for [command],
/// each with the command it names (`my_tool check`).
///
/// They run under the rule every plugin command follows
/// ([PluginTrust.trusted]); any other is asked about when there is a
/// terminal and no `--yes` ([askPluginTrust]), and one that may not run is
/// skipped with a warning that says how to allow it — never silently.
/// Packages in [skip] are left out without a word (asked already).
List<(Plugin, String)> trustedHooks(
  JustCommand command,
  JustProject project,
  String hook, {
  Set<String>? skip,
}) {
  final out = <(Plugin, String)>[];
  for (final p in PluginFinder.inProject(project)) {
    final run = p.manifest.hooks[hook];
    if (run == null || (skip?.contains(p.package) ?? false)) continue;
    if (mayRunPlugin(command, p, adds: run, project: project)) {
      out.add((p, run));
      continue;
    }
    skip?.add(p.package);
    command.output.warn(
      "Skipped ${p.package}'s `$hook` hook "
      '(`${command.context.invokedAs} $run`): ${p.package} is not allowed '
      'to run here. To allow it, '
      '${howToAllowPlugin(command.context, p, project: project)}.',
    );
  }
  return out;
}

/// What a hook's run came to.
final class HookRun {
  /// A run of [hook] that exited with [exitCode], printing [document] (its
  /// own `--json` document) when it was asked for one.
  const HookRun(this.hook, this.exitCode, [this.document]);

  /// The command it ran: `my_tool check`.
  final String hook;

  /// Its exit code.
  final int exitCode;

  /// Its `--json` document, when the run had `--json` and it printed one.
  final Map<String, Object?>? document;

  /// Whether it passed.
  bool get ok => exitCode == 0;

  /// Whether, run with `--check`, it said it can't check
  /// ([PluginManifest.cannotCheck]).
  bool get cannotCheck => PluginManifest.cannotCheck.contains(exitCode);

  /// The `result` of its document.
  Object? get result => document?['result'];

  /// This run for the core's `--json` result, under the plugin's name.
  Map<String, Object?> toJson() => compactJson({
    'hook': hook,
    'ok': ok,
    'exitCode': exitCode,
    'result': result,
    'warnings': document?['warnings'],
    'error': document?['error'],
  });
}

/// Runs [plugin]'s hook [command] for [from], then [extra], in [project]
/// (the run's own when null), passing on `--json` and `--verbose`.
///
/// With `--json` — or [document], when the core needs the hook's result
/// whatever the run prints (`upgrade`'s bumps) — the hook gets `--json` and
/// its stdout is read for its own document (kept in the [HookRun], for the
/// core's result), and anything else it printed goes to stderr: stdout
/// holds only [from]'s output.
Future<HookRun> runHook(
  JustCommand from,
  Plugin plugin,
  String command, {
  List<String> extra = const [],
  JustProject? project,
  bool document = false,
}) async {
  final json = from.output.json || document;
  final args = withOptions(
    [...command.split(' '), ...extra],
    [if (json) '--json', if (from.output.verbose) '--verbose'],
  );
  if (!json) {
    final code = await launchPlugin(
      from.context,
      plugin,
      args,
      project: project,
    );
    return HookRun(command, code);
  }
  final printed = StringBuffer();
  final code = await launchPlugin(
    from.context,
    plugin,
    args,
    project: project,
    stdout: printed,
  );
  final (printedDocument, rest) = splitDocument('$printed');
  if (rest.trim().isNotEmpty) from.context.err.write(rest);
  return HookRun(command, code, printedDocument);
}

/// [printed] (what a `--json` run printed on stdout) split into its JSON
/// document — the JSON object that starts a line and runs to the end —
/// and whatever came before it (`dart run`'s own lines). No document: null,
/// and all of it.
(Map<String, Object?>?, String) splitDocument(String printed) {
  for (var i = 0; i < printed.length; i++) {
    if (printed[i] != '{' || (i > 0 && printed[i - 1] != '\n')) continue;
    try {
      final json = jsonDecode(printed.substring(i));
      if (json is Map<String, Object?>) return (json, printed.substring(0, i));
    } on FormatException {
      continue;
    }
  }
  return (null, printed);
}

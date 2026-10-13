/// A plugin's manifest, `just_plugin.json`: the commands and hooks it adds
/// to `just`. Pure Dart: it reads text, so it works on every platform.
library;

import '../create/package_set.dart';
import '../json/json.dart';

/// A package's `just_plugin.json`: the commands it adds to `just`.
///
/// ```json
/// {
///   "schema": 1,
///   "commands": [{"name": "hello", "summary": "Say hello."}],
///   "shortcuts": {"hi": "hello world"},
///   "hooks": {"check": "hello check"}
/// }
/// ```
///
/// `just` reads it to list the commands in its help without running any of
/// the package's code, and runs a command with `dart run <package>:just_plugin`
/// — every plugin's entry point is `bin/just_plugin.dart`.
final class PluginManifest {
  /// A manifest adding [commands], [shortcuts] and [hooks].
  const PluginManifest({
    this.commands = const {},
    this.shortcuts = const {},
    this.hooks = const {},
  });

  /// The manifest's file name, at the package root.
  static const String fileName = 'just_plugin.json';

  /// The plugin's entry point, under `bin/`.
  static const String entryPoint = 'just_plugin';

  /// The newest manifest format this version reads.
  static const int currentSchema = 1;

  /// The exit codes of a hook's `--check` that mean it can't check — a
  /// usage error, `just`'s own (2) or EX_USAGE (64): it takes no `--check`,
  /// or not an argument given after `--`. `just` warns and goes on; any
  /// other non-zero code stops it.
  static const Set<int> cannotCheck = {2, 64};

  /// The commands it adds: name → one-line summary.
  final Map<String, String> commands;

  /// Short names for longer commands: `hi` → `hello world`.
  final Map<String, String> shortcuts;

  /// The plugin's commands `just` runs at certain moments, by hook. Each
  /// runs only when its plugin may (the trust rule, `PluginTrust.trusted`); any other
  /// plugin's is asked about in a terminal, or skipped with a warning. Each
  /// gets `--json` and `--verbose` when the run had them; with `--json`, its
  /// own document goes into the run's result, under the plugin's name.
  ///
  /// Wherever `just` calls a hook with `--check`, the hook must change
  /// nothing and exit non-zero, saying why, when what it would do could not
  /// be done; a hook that can't check exits with a usage error
  /// ([cannotCheck]: 2, or 64) and `just` warns and goes on.
  ///
  /// - `create`: fill in a new project of the kind the plugin makes
  ///   ([ToolSet.kinds]), run by `just create` in that project with
  ///   `--title`, `--org`, `--platforms`, `--template`, `--source` and
  ///   `--local` as given, and `--yes` only when the user gave it. The
  ///   versions of its own packages are its own to choose. It owns the
  ///   pubspec from then on, and must keep just_core_cli and itself in
  ///   `dev_dependencies`, one line each (`name: ^1.2.3`), so `just upgrade`
  ///   can move them.
  /// - `check` and `doctor`: the plugin's part of `just check` and
  ///   `just doctor`; exit 0 when all is well.
  /// - `upgrade`: move the plugin's own packages to the versions it carries,
  ///   as one-line constraint bumps in `pubspec.yaml` — never `pub get`, no
  ///   other file, no project lock (`just upgrade` holds it, and fetches
  ///   the packages itself). With `--check` it changes nothing and reports
  ///   what it would move; `just upgrade` always reads its document, which
  ///   lists the bumps as `packages: {name: {from, to}}`. Run with `--yes`
  ///   inside `just upgrade`'s transaction; a failure rolls the upgrade back.
  /// - `migrate`: bring the plugin's files up to date. `just upgrade` runs
  ///   it with `--check` before it changes anything and again once the new
  ///   packages are fetched, before it commits — one that says no stops
  ///   the upgrade with nothing changed — then for real, passing on anything
  ///   given after `--` to `just upgrade`, the checks too. It gets `--yes`
  ///   only once the user said yes; without it, it asks before it rewrites
  ///   anything. Its result's `migrated` (a list) says what it rewrote.
  /// - `link`: what the plugin does with local checkouts. After
  ///   `just dev link` commits, with `<name>=<path>` for every checkout;
  ///   before `just dev unlink`, with `--unlink --check` and the linked
  ///   ones — non-zero keeps the links; after it, with `--unlink`.
  final Map<String, String> hooks;

  /// [text] as a manifest.
  static PluginManifest parse(String text) {
    final json = JsonFields.parse(text);
    final schema = json.optInt('schema', min: 1) ?? 1;
    if (schema > currentSchema) {
      throw json.error(
        'schema',
        'This plugin needs a newer version of just (format $schema).',
      );
    }
    final name = RegExp(r'^[a-z][a-z0-9-]*$');
    final commands = <String, String>{};
    for (final c in json.objects('commands')) {
      final n = c.string('name');
      if (!name.hasMatch(n)) {
        throw c.error('name', '"$n" is not a command name.');
      }
      commands[n] = c.optString('summary') ?? '';
    }
    final shortcuts = json.stringMap('shortcuts');
    for (final e in shortcuts.entries) {
      if (!name.hasMatch(e.key)) {
        throw json.error('shortcuts', '"${e.key}" is not a command name.');
      }
      final target = e.value.split(' ').first;
      if (!commands.containsKey(target)) {
        throw json.error(
          'shortcuts',
          '"${e.key}" points at "$target", which this plugin does not add.',
        );
      }
    }
    return PluginManifest(
      commands: commands,
      shortcuts: shortcuts,
      hooks: json.stringMap('hooks'),
    );
  }
}

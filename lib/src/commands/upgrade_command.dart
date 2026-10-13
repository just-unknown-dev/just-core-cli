/// `just upgrade`: move a project to a tool set, and each plugin's packages
/// to what it says.
library;

import '../cli/command.dart';
import '../cli/failures.dart';
import '../cli/pinning.dart';
import '../cli/plugins.dart';
import '../create/package_set.dart';
import '../json/semver.dart';
import '../project/just_project.dart';
import '../project/pub_runner.dart';
import '../project/pubspec_constraints.dart';
import '../project/transaction.dart';
import 'hooks.dart';

/// `just upgrade [--to <set>] [-- <migrate arguments>]`: the tools moved to
/// the tool set this `just` carries (or [--to]'s), each plugin's own
/// packages moved by its `upgrade` hook, the packages fetched and the set
/// recorded in `just.json` — all in one transaction — then the plugins'
/// migrations (their `migrate` hooks).
///
/// 1. When the tools stay, each `upgrade` hook is asked with `--check`
///    what it would move; nothing to move is "up to date".
/// 2. Before anything changes, each `migrate` hook is asked with `--check`
///    whether its migration could run.
/// 3. In the transaction: the tools' constraints, `pub get` (the plugins'
///    new versions resolve), each `upgrade` hook with `--yes` (one-line
///    bumps in `pubspec.yaml`, no `pub get`), `pub get` again when it
///    changed, each `migrate` hook with `--check` again (the new versions
///    may know more), `just.json`'s set — then the commit. Any failure
///    rolls it all back.
/// 4. The migrations, with `--yes` (the user said yes to the upgrade).
///
/// A `--check` that exits with a usage error ([PluginManifest.cannotCheck])
/// can't say: a warning, not a stop. Anything after `--` goes to every
/// `migrate` hook, the checks and the migration alike
/// (`just upgrade -- --engine-only`). On a project that is up to date, the
/// migrations run without `--yes` unless it was given: each asks before it
/// rewrites anything.
final class UpgradeCommand extends JustCommand {
  /// The command and its options.
  UpgradeCommand() {
    argParser.addOption(
      'to',
      valueHelp: 'set',
      help: 'The tool set to move to (default: the newest this just knows).',
    );
  }

  @override
  String get name => 'upgrade';

  @override
  String get description =>
      "Move the project's tools to a tool set and each plugin's packages to "
      "its versions, then run the plugins' migrations. Anything after `--` "
      'goes to every migrate hook.';

  @override
  String get invocation =>
      '${context.invokedAs} upgrade [--to <set>] [-- <migrate arguments>]';

  final Set<String> _skipped = {};

  @override
  Future<int> run() async {
    final project = requireProject();
    final setId = argResults!.option('to');
    final set = setId == null
        ? ToolSet.current
        : ToolSet.named(setId) ??
              (throw CommandFailure(
                'This just does not know the tool set "$setId" (it knows '
                '${ToolSet.known.map((s) => s.id).join(', ')}).',
              ));

    final pinned = ProjectPin.resolvedVersion(project);
    final self = Version.parse(context.version);
    if (pinned != null &&
        (Version.tryParse(pinned)?.compareTo(self) ?? 0) > 0) {
      throw CommandFailure(
        'The project pins just_core_cli $pinned, newer than this one '
        '(${context.version}): update your just first '
        '(`dart pub global activate just_core_cli`).',
      );
    }

    // The tools: every package of the tool set the pubspec names.
    final pubspec = project.readText(JustProject.pubspec)!;
    var nextPubspec = pubspec;
    final bumps = <String, (String, String)>{};
    for (final p in set.packages) {
      for (final section in const ['dependencies', 'dev_dependencies']) {
        final now = PubspecConstraints.of(nextPubspec, section, p.name);
        if (now == null || now == p.constraint) continue;
        nextPubspec = PubspecConstraints.set(
          nextPubspec,
          section,
          p.name,
          p.constraint,
        );
        bumps[p.name] = (now, p.constraint);
      }
    }
    final file = project.readProjectFile();
    for (final e in bumps.entries) {
      output.line('  ~ ${e.key}  ${e.value.$1} -> ${e.value.$2}');
    }
    final plugins = <String, Map<String, Object?>>{};
    void record(Plugin plugin, String hook, HookRun run) =>
        (plugins[plugin.package] ??= {})[hook] = run.toJson();

    // The plugins' packages: when the tools stay, ask what would move.
    var pluginMoves = false;
    if (bumps.isEmpty) {
      for (final (plugin, hook) in _hooks(project, 'upgrade')) {
        final run = await runHook(
          this,
          plugin,
          hook,
          extra: ['--check'],
          document: true,
        );
        record(plugin, 'upgrade', run);
        if (run.ok) {
          pluginMoves |= _printBumps(run).isNotEmpty;
        } else if (run.cannotCheck) {
          pluginMoves = true;
          output.warn(
            "${plugin.package} can't say beforehand what it would move "
            '(`${context.invokedAs} $hook --check` exited with '
            '${run.exitCode}); its upgrade runs all the same.',
          );
        } else {
          throw CommandFailure(
            "Nothing was changed: ${plugin.package}'s upgrade could not run "
            '(`${context.invokedAs} $hook --check` exited with '
            '${run.exitCode}; it says why above).',
          );
        }
      }
    }

    final moves = bumps.isNotEmpty || file.set != set.id || pluginMoves;
    var migrateHooks = _hooks(project, 'migrate');
    if (moves) {
      // Each migration says first whether it could run after the move.
      await _check(migrateHooks, 'before anything changes');
      if (!confirm('Upgrade the project to the ${set.id} tool set?')) {
        throw const CommandFailure(
          'Nothing was changed: the upgrade was declined.',
        );
      }
      migrateHooks =
          await _move(project, pubspec, nextPubspec, set.id, record) ??
          migrateHooks;
    } else {
      output.line(
        'The project is on the ${set.id} tool set, and its packages are up to '
        'date.',
      );
    }

    // The plugins' own migrations, each in its own process: with --yes once
    // the user said yes to a move; else each asks before it rewrites.
    var code = 0;
    var migrated = false;
    for (final (plugin, hook) in migrateHooks) {
      output.info('${plugin.package}: ${context.invokedAs} $hook');
      final run = await runHook(
        this,
        plugin,
        hook,
        extra: [if (moves || yes) '--yes', ...rest],
      );
      record(plugin, 'migrate', run);
      final result = run.result;
      if (result is Map && result['migrated'] is List) {
        migrated |= (result['migrated'] as List).isNotEmpty;
      }
      if (!run.ok) {
        code = 1;
        output.warn(
          "${plugin.package}'s migration failed (exit code ${run.exitCode}). "
          'Run `${context.invokedAs} $hook` once the problem is fixed.',
        );
      }
    }
    output.result = {
      'set': set.id,
      'changed': moves || migrated,
      'packages': {
        for (final e in bumps.entries)
          e.key: {'from': e.value.$1, 'to': e.value.$2},
      },
      ...plugins,
    };
    if (moves) output.line('The project is on the ${set.id} tool set.');
    return code;
  }

  /// The plugins whose [hook] may run here ([trustedHooks]); one not
  /// allowed is warned about once.
  List<(Plugin, String)> _hooks(JustProject project, String hook) =>
      trustedHooks(this, project, hook, skip: _skipped);

  /// Prints the bumps an `upgrade` hook's document lists, and returns them.
  Map<String, Object?> _printBumps(HookRun run) {
    final result = run.result;
    final packages = result is Map ? result['packages'] : null;
    if (packages is! Map) return const {};
    packages.forEach((name, bump) {
      if (bump is Map) {
        output.line('  ~ $name  ${bump['from']} -> ${bump['to']}');
      }
    });
    return packages.cast<String, Object?>();
  }

  /// Asks each of [hooks] with `--check` (and the arguments after `--`)
  /// whether its migration could run, [when]. Throws [CommandFailure] when
  /// one says no; one that can't check ([PluginManifest.cannotCheck]) is a
  /// warning.
  Future<void> _check(List<(Plugin, String)> hooks, String when) async {
    for (final (plugin, hook) in hooks) {
      output.detail('${plugin.package}: $hook --check');
      final run = await runHook(
        this,
        plugin,
        hook,
        extra: ['--check', ...rest],
      );
      if (run.ok) continue;
      if (run.cannotCheck) {
        output.warn(
          "${plugin.package} can't say beforehand whether its migration will "
          'run (`${context.invokedAs} $hook --check` exited with '
          '${run.exitCode}: it takes no --check, or not the arguments after '
          '--). Its migration runs after the upgrade all the same.',
        );
        continue;
      }
      throw CommandFailure(
        "Nothing was changed: ${plugin.package}'s migration could not run "
        '($when, `${context.invokedAs} $hook --check` exited with '
        '${run.exitCode}; it says why above). Fix that, then upgrade again.',
      );
    }
  }

  /// The transaction: [nextPubspec] (when it differs from [pubspec]) and
  /// `pub get`, the plugins' `upgrade` hooks and `pub get` again when they
  /// changed the pubspec, the migrations asked again with the new packages,
  /// `just.json`'s set, [setId] — read again then, so what was allowed
  /// during the upgrade stays allowed — all of it, or (a step fails) none
  /// of it. Each hook's run goes
  /// to [record]. Returns the `migrate` hooks of the packages now fetched;
  /// null when nothing was fetched.
  Future<List<(Plugin, String)>?> _move(
    JustProject project,
    String pubspec,
    String nextPubspec,
    String setId,
    void Function(Plugin plugin, String hook, HookRun run) record,
  ) async {
    final lock = ProjectLock.acquire(project);
    try {
      ProjectTransaction.recover(project);
      final txn = ProjectTransaction.begin(project, trash: 'upgrade')
        ..backUp([
          JustProject.pubspec,
          'pubspec.lock',
          '.dart_tool/package_config.json',
          '.dart_tool/package_graph.json',
          JustProject.projectFile,
        ]);
      try {
        var fetched = false;
        if (nextPubspec != pubspec) {
          txn.write(JustProject.pubspec, nextPubspec);
          await _pubGet(project);
          fetched = true;
        }
        // Each plugin moves its own packages: one-line bumps, no pub get.
        final before = project.readText(JustProject.pubspec);
        for (final (plugin, hook) in _hooks(project, 'upgrade')) {
          output.info('${plugin.package}: ${context.invokedAs} $hook');
          final run = await runHook(
            this,
            plugin,
            hook,
            extra: ['--yes'],
            document: true,
          );
          record(plugin, 'upgrade', run);
          if (!run.ok) {
            throw CommandFailure(
              "${plugin.package}'s upgrade failed (exit code ${run.exitCode}), "
              'so nothing was changed.',
            );
          }
          _printBumps(run);
        }
        if (project.readText(JustProject.pubspec) != before) {
          await _pubGet(project);
          fetched = true;
        }
        List<(Plugin, String)>? after;
        if (fetched) {
          after = _hooks(project, 'migrate');
          await _check(after, 'with the new packages');
        }
        txn.write(
          JustProject.projectFile,
          project.readProjectFile().copyWith(set: setId).toText(),
        );
        txn.commit();
        return after;
      } on Object {
        txn.rollBack();
        rethrow;
      }
    } finally {
      lock.release();
    }
  }

  Future<void> _pubGet(JustProject project) async {
    final sdk = await SdkLocator.find(
      project.root,
      environment: context.environment,
    );
    output.info('Getting packages…');
    final code = await context.launcher.run(
      sdk?.flutter ?? 'dart',
      ['pub', 'get'],
      workingDirectory: project.root,
      toStderr: output.json,
    );
    if (code != 0) {
      throw CommandFailure(
        'pub get failed (exit code $code), so nothing was changed.',
      );
    }
  }
}

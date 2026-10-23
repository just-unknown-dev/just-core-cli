/// `just dev`: working on the ecosystem's packages from a project.
library;

import 'dart:io';

import '../cli/command.dart';
import '../cli/context.dart';
import '../cli/failures.dart';
import '../create/dev_links.dart';
import '../project/just_project.dart';
import '../project/overrides_target.dart';
import '../project/pub_runner.dart';
import '../project/transaction.dart';
import 'hooks.dart';

/// `just dev link|unlink`.
final class DevCommand extends JustCommand {
  /// The command and its subcommands.
  DevCommand() {
    addSubcommand(DevLinkCommand());
    addSubcommand(DevUnlinkCommand());
  }

  @override
  String get name => 'dev';

  @override
  String get description =>
      "Work on the ecosystem's packages from this project: link it to local "
      'checkouts.';
}

/// `just dev link <folder>...`: path overrides to the local checkouts in
/// each folder (say a workspace's `packages/` and `plugins/`) in
/// `pubspec_overrides.yaml`, fetched all or nothing — then each
/// plugin's `link` hook, with `<name>=<path>` for every checkout.
final class DevLinkCommand extends JustCommand {
  @override
  String get name => 'link';

  @override
  String get description =>
      "Point the project at local checkouts of the ecosystem's packages: "
      'path overrides in pubspec_overrides.yaml, then what each plugin does '
      'with them (its `link` hook).';

  @override
  String get invocation =>
      '${context.invokedAs} dev link <folder> [<folder>...]';

  @override
  Future<int> run() async {
    final project = requireProject();
    final args = argResults!.rest;
    if (args.isEmpty) {
      throw UsageFailure('Name the folders holding the checkouts.');
    }
    final folders = [
      for (final arg in args)
        File(arg).isAbsolute ? arg : '${context.workingDirectory}/$arg',
    ];
    final List<Checkout> checkouts;
    try {
      checkouts = DevLinks.scanAll([for (final f in folders) Directory(f)]);
    } on DevLinkClash catch (e) {
      throw CommandFailure('$e');
    }
    if (checkouts.isEmpty) {
      throw CommandFailure('No just_* packages in ${folders.join(', ')}.');
    }
    final before = DevLinks.linked(project);
    final text = DevLinks.overridesText(project, checkouts);
    output.line('Linking ${checkouts.length} packages:');
    for (final c in checkouts) {
      final mark = before.containsKey(c.name) ? ' ' : '+';
      output.line('  $mark ${c.name}  ${DevLinks.pathFrom(project, c.path)}');
    }
    await writeAndGet(context, project, text, output.json);
    if (!await OverridesTarget.isGitIgnored(project, JustProject.overrides)) {
      output.warn(
        'pubspec_overrides.yaml is not ignored by git, and its paths are '
        "this machine's. Add it to .gitignore.",
      );
    }
    final result = <String, Object?>{
      'linked': {
        for (final c in checkouts) c.name: DevLinks.pathFrom(project, c.path),
      },
    };
    output.result = result;
    // What the plugins do with the links is theirs to say.
    var code = 0;
    for (final (plugin, hook) in trustedHooks(this, project, 'link')) {
      output.detail('${plugin.package}: $hook');
      final run = await runHook(
        this,
        plugin,
        hook,
        extra: [for (final c in checkouts) '${c.name}=${c.path}'],
      );
      result[plugin.package] = run.toJson();
      if (!run.ok) {
        code = 1;
        output.warn(
          "${plugin.package}'s `link` hook failed (exit code ${run.exitCode}); "
          'the links are made.',
        );
      }
    }
    return code;
  }
}

/// `just dev unlink`: the links `just dev link` made, removed. Each
/// plugin's `link` hook is asked first, with `--unlink --check` (one that
/// says no keeps the links), and told after, with `--unlink`.
final class DevUnlinkCommand extends JustCommand {
  @override
  String get name => 'unlink';

  @override
  String get description =>
      'Remove the links `just dev link` made (the checkouts stay).';

  @override
  Future<int> run() async {
    final project = requireProject();
    final before = DevLinks.linked(project);
    if (before.isEmpty) {
      output
        ..result = {'unlinked': <String>[]}
        ..line('Nothing is linked.');
      return 0;
    }
    final pairs = [
      for (final e in before.entries)
        '${e.key}=${File(e.value).isAbsolute ? e.value : project.path(e.value)}',
    ];
    final hooks = trustedHooks(this, project, 'link');
    final result = <String, Object?>{'unlinked': before.keys.toList()};
    for (final (plugin, hook) in hooks) {
      final run = await runHook(
        this,
        plugin,
        hook,
        extra: ['--unlink', '--check', ...pairs],
      );
      if (run.ok) continue;
      if (run.cannotCheck) {
        output.warn(
          "${plugin.package} can't say whether the project needs the links "
          '(`${context.invokedAs} $hook --unlink --check` exited with '
          '${run.exitCode}).',
        );
        continue;
      }
      throw CommandFailure(
        'Nothing was unlinked: ${plugin.package} says the project still needs '
        'the links (`${context.invokedAs} $hook --unlink --check` exited with '
        '${run.exitCode}; it says why above).',
      );
    }
    await writeAndGet(
      context,
      project,
      DevLinks.overridesText(project, const []),
      output.json,
    );
    output
      ..result = result
      ..line('Unlinked ${before.length} packages.');
    var code = 0;
    for (final (plugin, hook) in hooks) {
      final run = await runHook(
        this,
        plugin,
        hook,
        extra: ['--unlink', ...pairs],
      );
      result[plugin.package] = run.toJson();
      if (!run.ok) {
        code = 1;
        output.warn(
          "${plugin.package}'s `link --unlink` hook failed (exit code "
          '${run.exitCode}); the links are gone.',
        );
      }
    }
    return code;
  }
}

/// Writes [overrides] as [project]'s `pubspec_overrides.yaml` and runs
/// `pub get`, all or nothing: if pub get fails, the file is put back.
Future<void> writeAndGet(
  JustContext context,
  JustProject project,
  String overrides,
  bool quiet,
) async {
  final lock = ProjectLock.acquire(project);
  try {
    ProjectTransaction.recover(project);
    final txn = ProjectTransaction.begin(project, trash: 'dev')
      ..backUp([
        JustProject.overrides,
        'pubspec.lock',
        '.dart_tool/package_config.json',
        '.dart_tool/package_graph.json',
      ]);
    try {
      txn.write(JustProject.overrides, overrides);
      final sdk = await SdkLocator.find(
        project.root,
        environment: context.environment,
      );
      final code = await context.launcher.run(
        sdk?.flutter ?? 'dart',
        ['pub', 'get'],
        workingDirectory: project.root,
        toStderr: quiet,
      );
      if (code != 0) {
        throw CommandFailure(
          'pub get failed (exit code $code), so nothing was changed.',
        );
      }
      txn.commit();
    } on Object {
      txn.rollBack();
      rethrow;
    }
  } finally {
    lock.release();
  }
}

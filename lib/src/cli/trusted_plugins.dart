/// Running another plugin from a command: `just create` fills a new project
/// in with its kind's plugin, and one plugin's command calls another's.
library;

import '../project/just_project.dart';
import '../project/package_info.dart';
import 'command.dart';
import 'failures.dart';
import 'plugin_command.dart';
import 'plugins.dart';

/// The plugin [package] among [project]'s resolved packages, with the
/// [hook] (`create`) when one is named, once it may run for [command].
///
/// It may run under the rule every plugin command follows
/// ([PluginTrust.trusted]): one of the ecosystem's own from a local
/// checkout or the ecosystem's repositories (or pub.dev, for the names it
/// published there), or one the user allowed (in the project's `just.json`,
/// or the user's `plugins.json`). Any other is asked about when there is a
/// terminal and no `--yes`, the answer saved ([askPluginTrust]).
///
/// Throws a [CommandFailure] that says why when the project has no such
/// package (or pub has not run in it), when it lacks the hook, or when it
/// may not run — and how to allow it.
Plugin requireTrustedPlugin(
  JustCommand command,
  JustProject project,
  String package, {
  String? hook,
  String? adds,
}) {
  final found = PluginFinder.inProject(
    project,
  ).where((p) => p.package == package).firstOrNull;
  if (found == null) {
    final fetched = PackageConfig.read(project.root) != null;
    throw CommandFailure(
      '${project.root} has no $package among its packages'
      '${fetched ? '' : ' (they have not been fetched: run `flutter pub get`)'}'
      '.',
    );
  }
  final hookCommand = hook == null ? null : found.manifest.hooks[hook];
  if (hook != null && hookCommand == null) {
    final version = found.version;
    throw CommandFailure(
      '$package${version == null ? '' : ' $version'} has no `$hook` hook in '
      'its ${PluginManifest.fileName}.',
    );
  }
  if (!mayRunPlugin(
    command,
    found,
    adds: hookCommand ?? adds ?? package,
    project: project,
  )) {
    throw CommandFailure(
      '$package is not allowed to run here, so it was not run. To allow it, '
      '${howToAllowPlugin(command.context, found, project: project)}'
      '${command.yes ? ' (--yes never allows a plugin)' : ''}.',
    );
  }
  return found;
}

/// Runs the plugin [package] with [args], in [project] (the run's own when
/// null), once [requireTrustedPlugin] says it may run for [command], and
/// returns its exit code.
///
/// With [hook], the command the plugin names for it in its manifest comes
/// first, then [args]. With [toStderr], what the plugin
/// prints goes to stderr (for a `--json` run); with [stdout], its stdout
/// goes there instead (its own `--json` document). Throws a
/// [CommandFailure] when there is no project, or the plugin may not run.
Future<int> runTrustedPlugin(
  JustCommand command,
  String package,
  List<String> args, {
  JustProject? project,
  String? hook,
  bool toStderr = false,
  StringSink? stdout,
}) {
  final where = project ?? command.requireProject();
  final plugin = requireTrustedPlugin(
    command,
    where,
    package,
    hook: hook,
    adds: args.take(2).join(' '),
  );
  return launchPlugin(
    command.context,
    plugin,
    [
      ...?hook == null ? null : plugin.manifest.hooks[hook]!.split(' '),
      ...args,
    ],
    project: where,
    toStderr: toStderr,
    stdout: stdout,
  );
}

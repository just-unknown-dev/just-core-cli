/// `just check`: every installed plugin's own checks.
library;

import '../cli/command.dart';
import '../cli/failures.dart';
import '../project/package_info.dart';
import 'hooks.dart';

/// `just check`: runs the `check` hook of each plugin in the project that
/// may run ([trustedHooks]), and fails when one does.
///
/// It never passes without checking: a project whose packages were not
/// fetched, or where no plugin's check ran, fails too, so a CI gate can't
/// pass vacuously. With `--json`, each plugin's own document is in the
/// result, under its package name.
final class CheckCommand extends JustCommand {
  @override
  String get name => 'check';

  @override
  String get description =>
      "Run the installed plugins' checks (their `check` hooks). A plugin's "
      'own checks are under its own command too.';

  @override
  Future<int> run() async {
    final project = requireProject();
    if (rest.isNotEmpty) {
      throw UsageFailure(
        'check takes no arguments. To run one check, use the command of the '
        'plugin that has it (`${context.invokedAs} --help` lists them).',
      );
    }
    if (PackageConfig.read(project.root) == null) {
      throw const CommandFailure(
        "Nothing was checked: the project's packages have not been fetched. "
        'Run `flutter pub get` first.',
      );
    }
    final result = <String, Object?>{};
    output.result = result;
    final hooks = trustedHooks(this, project, 'check');
    if (hooks.isEmpty) {
      throw const CommandFailure(
        'Nothing was checked: no installed plugin that may run here has a '
        '`check` hook.',
      );
    }
    var failed = false;
    for (final (plugin, hook) in hooks) {
      output.info('${plugin.package}: ${context.invokedAs} $hook');
      final run = await runHook(this, plugin, hook);
      result[plugin.package] = run.toJson();
      if (!run.ok) failed = true;
    }
    output.line(
      failed
          ? 'A check failed.'
          : 'Every check passed (${hooks.map((h) => h.$1.package).join(', ')}).',
    );
    return failed ? 1 : 0;
  }
}

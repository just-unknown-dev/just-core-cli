/// `just create`: a new project of one of the ecosystem's kinds.
library;

import 'dart:io';

import '../cli/command.dart';
import '../cli/failures.dart';
import '../cli/plugin_command.dart';
import '../cli/plugins.dart';
import '../create/dev_links.dart';
import '../create/package_set.dart';
import '../create/template_renderer.dart';
import '../json/names.dart';
import '../project/just_project.dart';
import '../project/project_file.dart';
import '../project/pub_runner.dart';
import '../project/pubspec_constraints.dart';
import 'hooks.dart';

/// `just create <folder> [--kind <kind>]`: `flutter create`, then `just.json`
/// and the tools — just_core_cli and the kind's plugin — as plain dev
/// dependencies on pub.dev versions (with `--local`, `pubspec_overrides.yaml`
/// also points every just_* package in those folders at its checkout), then
/// the kind's plugin fills the project in: its `create` hook. On a failure
/// the folder is deleted when this run made it, or emptied when it was
/// there already, empty; anything that can't be deleted (a file in use) is
/// named.
///
/// The hook owns the pubspec from then on, and must keep those two dev
/// dependencies, on one line each, so `just upgrade` can move them. It gets
/// `--title`, `--org`, `--platforms`, `--template`, `--source` and
/// `--local` (one for each folder) as given, each as one `--name=value`
/// argument (so a value that starts with `-` stays a value), and `--yes`,
/// `--json` and `--verbose` only when the run had them. The versions of its own packages are the
/// plugin's to choose; `just.json`'s `set` is the tool set's id.
final class CreateCommand extends JustCommand {
  /// The command and its options.
  CreateCommand() {
    final kinds = ToolSet.current.kinds;
    argParser
      ..addOption(
        'kind',
        allowed: kinds.keys,
        allowedHelp: {
          for (final e in kinds.entries)
            e.key: 'Filled in by ${e.value} (its `create` hook).',
        },
        defaultsTo: kinds.keys.firstOrNull,
        help: 'What to make.',
      )
      ..addOption(
        'template',
        abbr: 't',
        help:
            "What to start from, passed to the kind's plugin (default: its "
            'own empty project).',
      )
      ..addOption(
        'title',
        help:
            "The project's name as people see it (default: from the "
            'folder).',
      )
      ..addOption(
        'org',
        defaultsTo: 'com.example',
        help: 'The reverse-domain organisation, for app ids.',
      )
      ..addOption(
        'platforms',
        defaultsTo: 'windows,macos,linux,android,ios,web',
        help: 'The platforms to create, separated by commas.',
      )
      ..addMultiOption(
        'local',
        valueHelp: 'folder',
        splitCommas: false,
        help:
            "Point the ecosystem's packages at local checkouts in this folder "
            '(pubspec_overrides.yaml), for working on the ecosystem; repeat '
            'for several, such as packages/ and plugins/.',
      )
      ..addMultiOption(
        'source',
        valueHelp: 'catalog',
        help:
            "Where the kind's plugin finds a --template, passed to it; repeat "
            'for several.',
      );
  }

  @override
  String get name => 'create';

  @override
  String get description {
    final kinds = ToolSet.current.kinds.keys;
    return kinds.isEmpty
        ? 'Make a new project.'
        : 'Make a new project of one of the kinds the tools know '
              '(${kinds.first} by default).';
  }

  @override
  String get invocation => '${context.invokedAs} create <folder> [options]';

  @override
  Future<int> run() async {
    final arg = singleArgument('the folder to create');
    final target = Directory(
      File(arg).isAbsolute ? arg : '${context.workingDirectory}/$arg',
    ).absolute;
    final dir = normalPath(target.path);
    final names = ProjectNames(
      dir.split('/').last,
      title: argResults!.option('title'),
    );
    final problem = PackageNames.idProblem(names.name);
    if (problem != null) {
      throw UsageFailure(
        '"${names.name}" can\'t be a Dart package name: $problem',
      );
    }
    final titleProblem = ProjectNames.titleProblem(names.title);
    if (titleProblem != null) throw UsageFailure('--title: $titleProblem');
    if (target.existsSync() && target.listSync().isNotEmpty) {
      throw CommandFailure('$dir already exists and is not empty.');
    }
    final template = argResults!.option('template');
    if (template != null && PackageNames.idProblem(template) != null) {
      throw UsageFailure('"$template" is not a template id.');
    }

    final set = ToolSet.current;
    final kind = argResults!.option('kind');
    final pluginName = kind == null ? null : set.kinds[kind];
    if (kind == null || pluginName == null) {
      throw const UsageFailure('create needs a --kind.');
    }
    final tools = [
      for (final name in {'just_core_cli', pluginName})
        set[name] ?? (throw StateError('The ${set.id} set has no $name.')),
    ];

    final locals = argResults!.multiOption('local');
    final localDirs = [
      for (final local in locals)
        normalPath(
          Directory(
            File(local).isAbsolute
                ? local
                : '${context.workingDirectory}/$local',
          ).absolute.path,
        ),
    ];
    final List<Checkout> checkouts;
    try {
      checkouts = DevLinks.scanAll([for (final d in localDirs) Directory(d)]);
    } on DevLinkClash catch (e) {
      throw CommandFailure('$e');
    }
    if (locals.isNotEmpty && checkouts.isEmpty) {
      throw CommandFailure('No just_* packages in ${locals.join(', ')}.');
    }
    final sdk = await SdkLocator.find(
      context.workingDirectory,
      environment: context.environment,
    );
    if (sdk == null) {
      throw const CommandFailure(
        'Flutter was not found. Install it, put it on the PATH, or set '
        'FLUTTER_ROOT.',
      );
    }

    final existed = target.existsSync();
    final HookRun hook;
    try {
      final project = await _flutterCreate(
        sdk,
        dir,
        names,
        set,
        tools,
        localDirs,
        checkouts,
      );
      final plugin = _kindPlugin(project, pluginName, kind);
      output.info('Making the $kind with $pluginName…');
      hook = await runHook(
        this,
        plugin,
        plugin.manifest.hooks['create']!,
        project: project,
        // Each value joined to its option, so a value that looks like one
        // (`--title --json`) stays a value.
        extra: [
          '--title=${names.title}',
          '--org=${argResults!.option('org')!}',
          '--platforms=${argResults!.option('platforms')!}',
          if (template != null) '--template=$template',
          for (final s in argResults!.multiOption('source')) '--source=$s',
          for (final d in localDirs) '--local=$d',
          // Only when given: without it the hook may still ask, in a
          // terminal, whether to trust a plugin it calls.
          if (yes) '--yes',
        ],
      );
      if (!hook.ok) {
        throw CommandFailure(
          '$pluginName (`create` hook) failed (exit code ${hook.exitCode}).',
        );
      }
    } on Object {
      // Nothing half-made is left behind: the folder this run made goes,
      // or — when it was there already, empty — what was made in it. What
      // can't go (a file in use) is named, and the run's own failure is
      // the one reported.
      if (target.existsSync()) {
        output.info('Removing the half-made project in $dir.');
        try {
          if (existed) {
            for (final e in target.listSync()) {
              e.deleteSync(recursive: true);
            }
          } else {
            target.deleteSync(recursive: true);
          }
        } on FileSystemException catch (e) {
          output.warn(
            'Could not remove all of the half-made project in $dir '
            '(${e.path ?? dir}: ${e.osError?.message ?? e.message}): '
            'delete it by hand.',
          );
        }
      }
      rethrow;
    }
    output
      ..result = {
        'path': dir,
        'name': names.name,
        'title': names.title,
        'kind': kind,
        'template': template,
        'set': set.id,
        'linked': [for (final c in checkouts) c.name],
        pluginName: hook.toJson(),
      }
      ..line()
      ..line('Created ${names.title} in $dir.')
      ..line('  cd ${names.name}');
    return 0;
  }

  /// `flutter create`, then `just.json`, the [tools] as dev dependencies,
  /// the links to [checkouts] (in [localDirs]) and `pub get`: a project the
  /// kind's plugin can run in.
  Future<JustProject> _flutterCreate(
    FlutterSdk sdk,
    String dir,
    ProjectNames names,
    ToolSet set,
    List<SetPackage> tools,
    List<String> localDirs,
    List<Checkout> checkouts,
  ) async {
    final quiet = output.json;
    output.info('Creating the Flutter project…');
    await _must(
      'flutter create',
      context.launcher.run(sdk.flutter, [
        'create',
        '--empty',
        '--project-name',
        names.name,
        '--org',
        argResults!.option('org')!,
        '--platforms',
        argResults!.option('platforms')!,
        dir,
      ], toStderr: quiet),
    );

    final project = JustProject(dir);
    project.writeProjectFile(JustProjectFile(title: names.title, set: set.id));
    // Plain entries, as a person writes them: the kind's plugin keeps them
    // in the pubspec it writes, and `just upgrade` moves them on.
    var pubspec =
        project.readText(JustProject.pubspec) ?? 'name: ${names.name}\n';
    for (final p in tools) {
      if (p.source != PackageSource.hosted && checkouts.isEmpty) {
        throw StateError(
          '${p.name} does not come from pub.dev in the ${set.id} set, so '
          '`just create` can\'t add it as a tool.',
        );
      }
      pubspec = PubspecConstraints.add(
        pubspec,
        'dev_dependencies',
        p.name,
        p.constraint,
      );
    }
    writeTextAtomic(project.file(JustProject.pubspec), pubspec);
    final gitignore = project.file('.gitignore');
    writeTextAtomic(
      gitignore,
      GitIgnores.withDefaults(
        gitignore.existsSync() ? gitignore.readAsStringSync() : '',
      ),
    );
    if (checkouts.isNotEmpty) {
      output.info(
        'Linking ${checkouts.length} packages in ${localDirs.join(', ')}…',
      );
      writeTextAtomic(
        project.file(JustProject.overrides),
        DevLinks.overridesText(project, checkouts),
      );
    }

    output.info('Getting packages…');
    await _must(
      'flutter pub get',
      context.launcher.run(
        sdk.flutter,
        ['pub', 'get'],
        workingDirectory: dir,
        toStderr: quiet,
      ),
    );
    return project;
  }

  /// The kind's plugin [name] in the new [project], with its `create` hook,
  /// once it may run ([mayRunPlugin]): trusted, or allowed when asked —
  /// saved in the new project's `just.json`.
  Plugin _kindPlugin(JustProject project, String name, String kind) {
    final plugin = PluginFinder.inProject(
      project,
    ).where((p) => p.package == name).firstOrNull;
    if (plugin == null) {
      throw CommandFailure(
        'The new project has no $name after pub get, so the $kind could not '
        'be made.',
      );
    }
    final hook = plugin.manifest.hooks['create'];
    if (hook == null) {
      throw CommandFailure(
        '$name has no `create` hook in its ${PluginManifest.fileName}, so '
        'the $kind could not be made.',
      );
    }
    if (!mayRunPlugin(this, plugin, adds: hook, project: project)) {
      throw CommandFailure(
        '$name was not allowed to run, so the $kind was not made. Run '
        '`${context.invokedAs} create` in a terminal, without --yes, to be '
        'asked.',
      );
    }
    return plugin;
  }

  static Future<void> _must(String what, Future<int> run) async {
    final code = await run;
    if (code != 0) throw CommandFailure('$what failed (exit code $code).');
  }
}

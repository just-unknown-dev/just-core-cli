/// The commands plugins add, as `just` shows and runs them.
library;

import 'dart:io';

import 'package:args/args.dart';

import '../project/just_project.dart';
import '../project/pub_runner.dart';
import 'command.dart';
import 'context.dart';
import 'failures.dart';
import 'pinning.dart';
import 'plugins.dart';

/// A command a plugin adds: listed from its `just_plugin.json`, and run as
/// `dart run <package>:just_plugin <command> <arguments>` — in the project
/// for the project's plugins, with `dart pub global run` for global ones.
///
/// Everything after the command's name goes to the plugin untouched, so
/// its own help (`just hello --help`) and options work; `--json`, `--yes`
/// and `--verbose` given before the name are passed on too. A plugin that
/// isn't the ecosystem's own ([PluginTrust]) asks once before it first
/// runs; `--yes` never answers that question.
final class PluginCommand extends JustCommand {
  /// The command [name] that [plugin] adds, described by [pluginSummary]. A
  /// shortcut runs [prefix] (`hello world`) instead of [name].
  PluginCommand(this.plugin, this.name, this.pluginSummary, {this.prefix});

  /// The plugin that runs it.
  final Plugin plugin;

  @override
  final String name;

  /// The plugin's one-line description of it.
  final String pluginSummary;

  /// For a shortcut: the plugin command it stands for.
  final List<String>? prefix;

  @override
  final ArgParser argParser = ArgParser.allowAnything();

  @override
  bool get printsOwnDocument => true;

  @override
  String get description {
    final what = prefix == null
        ? pluginSummary
        : 'Same as `${prefix!.join(' ')}`.';
    return '$what [${plugin.package}]';
  }

  @override
  String get invocation => '${context.invokedAs} $name <arguments>';

  @override
  Future<int> run() async {
    switch (askPluginTrust(this, plugin, adds: name)) {
      case PluginTrustAnswer.trusted || PluginTrustAnswer.allowedNow:
        break;
      case PluginTrustAnswer.declined:
        throw CommandFailure(
          '${plugin.package} was not allowed to run. To allow it later, '
          '${howToAllowPlugin(context, plugin)}.',
        );
      case PluginTrustAnswer.notAsked:
        throw CommandFailure(
          '${plugin.package} is not allowed to run here yet, and '
          '${yes ? '--yes does not allow a plugin: it runs its own code' : 'there is nobody to ask'}. '
          'To allow it, ${howToAllowPlugin(context, plugin)}, or run the '
          'command in a terminal without --yes to be asked.',
        );
    }
    output.detail('Running ${plugin.package} (${plugin.scope.name} plugin).');
    // The flags given before the name go to the plugin too — before any
    // `--`, after which arguments are the plugin's to pass on.
    final options = rest.takeWhile((a) => a != '--').toList();
    return launchPlugin(
      context,
      plugin,
      withOptions(
        [...?prefix, if (prefix == null) name, ...rest],
        [
          if (output.json && !options.contains('--json')) '--json',
          if (yes && !options.contains('--yes')) '--yes',
          if (output.verbose && !options.contains('--verbose')) '--verbose',
        ],
      ),
    );
  }
}

/// [args] with [options] added before the first `--` (at the end when
/// there is none): after a `--`, a plugin passes arguments on untouched, so
/// an option there would never reach it.
List<String> withOptions(List<String> args, List<String> options) {
  final at = args.indexOf('--');
  return at < 0
      ? [...args, ...options]
      : [...args.take(at), ...options, ...args.skip(at)];
}

/// What came of [askPluginTrust].
enum PluginTrustAnswer {
  /// The plugin may run: it is the ecosystem's own, or was allowed before.
  trusted,

  /// The user allowed it just now; the answer is saved.
  allowedNow,

  /// The user said no.
  declined,

  /// Nobody was asked: `--yes` was given (it never allows a plugin), or
  /// there is no terminal.
  notAsked,
}

/// Whether [plugin] may run for [command], asking the user when it isn't
/// trusted yet ([PluginTrust]) and there is a terminal and no `--yes`. The
/// user's [UserPluginAllowList] allows a plugin everywhere — a project's
/// too, so a CI or a team behind a package mirror can allow one before any
/// project exists; a project's `just.json` allows it there. A yes is saved
/// in `just.json` for a project's plugin, in the user's list for a global
/// one. [adds] names what it would run
/// (a command, or a hook), for the question. [project] is the project the
/// plugin is in, when it is not the run's own (`just create`'s new one).
PluginTrustAnswer askPluginTrust(
  JustCommand command,
  Plugin plugin, {
  required String adds,
  JustProject? project,
}) {
  final context = command.context;
  project ??= context.project;
  final global = plugin.scope == PluginScope.global || project == null;
  final allowed = [
    ...UserPluginAllowList.read(environment: context.environment),
    if (!global) ...project.readProjectFile().allowedPlugins,
  ];
  if (PluginTrust.trusted(plugin, allowed)) return PluginTrustAnswer.trusted;

  final version = plugin.version;
  final official = PluginTrust.official.contains(plugin.package);
  command.output.info(
    '${plugin.package}${version == null ? '' : ' $version'} adds '
    '`${context.invokedAs} $adds`. A plugin runs its own code on this '
    'machine.${official ? ' (Its name is one of the ecosystem\'s, but it '
              'comes from ${_from(plugin.source)}, not from a local '
              'checkout or github.com/${PluginTrust.ecosystemOwner}.)' : ''}',
  );
  if (command.yes || !context.interactive) return PluginTrustAnswer.notAsked;
  final where = global ? 'for your user' : 'in this project';
  context.err.write('Allow ${plugin.package} to run $where? [y/N] ');
  final answer = context.readLine()?.trim().toLowerCase() ?? '';
  if (answer != 'y' && answer != 'yes') return PluginTrustAnswer.declined;
  if (global) {
    UserPluginAllowList.add(plugin.package, environment: context.environment);
    command.output.info(
      'Allowed ${plugin.package} '
      '(saved in ${UserPluginAllowList.path(environment: context.environment)}).',
    );
  } else {
    project.writeProjectFile(
      project.readProjectFile().allowing(plugin.package),
    );
    command.output.info('Allowed ${plugin.package} (saved in just.json).');
  }
  return PluginTrustAnswer.allowedNow;
}

/// Whether [plugin] may run for [command]: [askPluginTrust]'s answer, as a
/// yes or a no.
bool mayRunPlugin(
  JustCommand command,
  Plugin plugin, {
  required String adds,
  JustProject? project,
}) => switch (askPluginTrust(command, plugin, adds: adds, project: project)) {
  PluginTrustAnswer.trusted || PluginTrustAnswer.allowedNow => true,
  PluginTrustAnswer.declined || PluginTrustAnswer.notAsked => false,
};

String _from(PluginSource source) => switch (source.kind) {
  'hosted' => 'a package server (${source.url ?? 'pub.dev'})',
  'git' => 'the git repository ${source.url}',
  'store' => 'a community item the Asset Store installed',
  'unknown' => 'a source no pubspec.lock names',
  final kind => kind,
};

/// How to allow [plugin] by hand: the file and the entry to add. [project]
/// is the project the plugin is in, when it is not the run's own.
String howToAllowPlugin(
  JustContext context,
  Plugin plugin, {
  JustProject? project,
}) {
  if (plugin.scope == PluginScope.global ||
      (project ?? context.project) == null) {
    final path =
        UserPluginAllowList.path(environment: context.environment) ??
        'plugins.json in your just_core_cli settings folder';
    return 'add "${plugin.package}" to "allowed" in $path';
  }
  final user = UserPluginAllowList.path(environment: context.environment);
  return 'add "${plugin.package}" to "plugins": {"allowed": [...]} in '
      'just.json${user == null ? '' : ' (this project), or to "allowed" in $user (every project)'}';
}

/// Runs [plugin] with [args] — `dart run <package>:just_plugin` in the
/// project, or `dart pub global run` for a global one — telling it the
/// project, the user's folder and the name `just` was started as. With
/// [toStderr], what it prints goes to stderr (for a `--json` run of a
/// command that calls a plugin on the way); with [stdout], what it prints
/// on stdout goes there (its `--json` document) and the rest to stderr.
/// [project] replaces the run's own (`just create` runs the new project's
/// plugin).
Future<int> launchPlugin(
  JustContext context,
  Plugin plugin,
  List<String> args, {
  JustProject? project,
  bool toStderr = false,
  StringSink? stdout,
}) async {
  project ??= context.project;
  final sdk = await SdkLocator.find(
    project?.root ?? context.workingDirectory,
    environment: context.environment,
  );
  final entry = '${plugin.package}:${PluginManifest.entryPoint}';
  final inProject = plugin.scope == PluginScope.project && project != null;
  return context.launcher.run(
    dartExecutable(sdk),
    inProject
        ? ['run', entry, ...args]
        : ['pub', 'global', 'run', entry, ...args],
    workingDirectory: inProject ? project.root : context.workingDirectory,
    environment: {
      'JUST_CORE_CLI_PROTOCOL': '1',
      'JUST_CORE_CLI_INVOKED_AS': context.invokedAs,
      'JUST_CORE_CLI_VERSION': context.version,
      'JUST_CORE_CLI_CWD': context.workingDirectory,
      'JUST_CORE_CLI_PROJECT': ?project?.root,
      'FLUTTER_ROOT': ?sdk?.root,
      // A `just` the plugin starts is a run of its own, not this one handed
      // over: it may hand over again.
      ProjectPin.delegatedVariable: '',
    },
    toStderr: toStderr,
    stdout: stdout,
  );
}

/// The Dart to run plugins with: the project's Flutter SDK's, else the one
/// running this tool, else `dart` on the PATH.
String dartExecutable(FlutterSdk? sdk) {
  if (sdk != null && File(sdk.dart).existsSync()) return sdk.dart;
  final self = Platform.resolvedExecutable;
  final base = self.replaceAll(r'\', '/').split('/').last.toLowerCase();
  if (base == 'dart' || base == 'dart.exe') return self;
  return 'dart';
}

/// The commands the plugins [context] can see add: the project's packages'
/// first, then those activated globally (a package in both counts once, as
/// the project's). The ecosystem's own plugins ([PluginTrust.isOfficial])
/// win a name clash; among the rest the first wins. Names in [taken] (the
/// tool's own) are never given to a plugin. Every clash, and every broken
/// manifest, is said in [problems].
List<PluginCommand> discoverPluginCommands(
  JustContext context, {
  required Set<String> taken,
  List<String>? problems,
}) {
  final project = context.project;
  final plugins = [
    if (project != null) ...PluginFinder.inProject(project, problems: problems),
  ];
  final inProject = {for (final p in plugins) p.package};
  for (final p in PluginFinder.global(
    environment: context.environment,
    problems: problems,
  )) {
    if (!inProject.contains(p.package)) plugins.add(p);
  }
  return pluginCommands(plugins, taken, problems: problems);
}

/// The commands [plugins] add, left out where [taken] (the tool's own) or
/// another plugin already has the name; each clash is said in [problems].
///
/// The ecosystem's own plugins ([PluginTrust.isOfficial]) come first, their
/// shortcuts included (an official plugin's shortcut beats another plugin's
/// command of that name); then the rest. Within each, commands before shortcuts, and
/// plugins in their order.
List<PluginCommand> pluginCommands(
  List<Plugin> plugins,
  Set<String> taken, {
  List<String>? problems,
}) {
  final owners = <String, String>{for (final t in taken) t: 'just itself'};
  final out = <PluginCommand>[];
  void add(PluginCommand c) {
    final owner = owners[c.name];
    if (owner == null) {
      owners[c.name] = c.plugin.package;
      out.add(c);
    } else {
      problems?.add(
        '${c.plugin.package} adds `${c.name}`, but $owner has that name; '
        "${c.plugin.package}'s was left out.",
      );
    }
  }

  for (final group in [
    plugins.where(PluginTrust.isOfficial).toList(),
    plugins.where((p) => !PluginTrust.isOfficial(p)).toList(),
  ]) {
    for (final p in group) {
      p.manifest.commands.forEach((name, summary) {
        add(PluginCommand(p, name, summary));
      });
    }
    for (final p in group) {
      p.manifest.shortcuts.forEach((name, target) {
        add(PluginCommand(p, name, '', prefix: target.split(' ')));
      });
    }
  }
  return out;
}

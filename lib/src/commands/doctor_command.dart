/// `just doctor`: what is wrong with a project's setup, and how to fix it.
library;

import 'dart:io';

import '../cli/command.dart';
import '../cli/findings.dart';
import '../cli/pinning.dart';
import '../cli/plugin_command.dart';
import '../cli/plugin_manifest.dart';
import '../create/package_set.dart';
import '../create/template_renderer.dart';
import '../json/json.dart';
import '../json/semver.dart';
import '../project/just_project.dart';
import '../project/package_info.dart';
import '../project/pub_runner.dart';
import 'hooks.dart';

/// `just doctor`: the tool, the SDKs and the project's package versions,
/// then each installed plugin's own checks (its `doctor` hook), for those
/// that may run ([trustedHooks]).
final class DoctorCommand extends JustCommand {
  @override
  String get name => 'doctor';

  @override
  String get description =>
      "Check the project's setup: Flutter, the tools' versions, the links "
      "to checkouts, then each installed plugin's own checks.";

  @override
  Future<int> run() async {
    final project = context.project;
    final findings = <Finding>[
      ..._path(),
      if (project != null) ...await _project(project),
      ..._plugins(),
    ];
    final named = context.projectOverride;
    if (project == null && named != null) {
      // Asked to check a project that isn't there: a typo is a failure.
      findings.add(
        Finding(
          Severity.problem,
          'No pubspec.yaml in $named (--project): it is not a project, so '
          'only the tool itself was checked.',
          fix: "Pass the folder that holds the project's pubspec.yaml.",
        ),
      );
    } else if (project == null) {
      findings.add(
        const Finding(
          Severity.warning,
          'Not in a project: only the tool itself was checked.',
        ),
      );
    }
    var code = output.findings(findings) ? 1 : 0;
    // What plugins check for themselves. With --json, each one's own
    // document goes in the result, under its package name.
    final plugins = <String, Object?>{};
    // Which plugins may run is in just.json: unreadable, it is a finding
    // above, and the plugins' checks wait until it is fixed.
    final readable = project != null && _readable(project);
    if (project != null && !readable) {
      output.warn(
        "The plugins' checks were skipped: ${JustProject.projectFile} can't "
        'be read.',
      );
    }
    if (project != null && readable) {
      for (final (plugin, hook) in trustedHooks(this, project, 'doctor')) {
        output.info('${plugin.package}: ${context.invokedAs} $hook');
        final run = await runHook(this, plugin, hook);
        if (!run.ok) code = 1;
        plugins[plugin.package] = run.toJson();
        findings.add(
          Finding(
            run.ok ? Severity.ok : Severity.problem,
            '${plugin.package}: `$hook` ${run.ok ? 'passed' : 'failed'}.',
          ),
        );
      }
    }
    output.result = {
      'findings': [for (final f in findings) f.toJson()],
      ...plugins,
    };
    if (code == 0) output.line('\nNo problems found.');
    return code;
  }

  /// Which `just` the PATH finds.
  List<Finding> _path() {
    final env = context.environment;
    final path = env['PATH'] ?? env['Path'] ?? '';
    final separator = Platform.isWindows ? ';' : ':';
    final names = Platform.isWindows
        ? const ['just.exe', 'just.bat', 'just.cmd']
        : const ['just'];
    for (final dir in path.split(separator)) {
      if (dir.isEmpty) continue;
      for (final n in names) {
        final f = File('$dir/$n');
        if (!f.existsSync()) continue;
        if (_isOurs(f)) {
          return [Finding(Severity.ok, '`just` on the PATH is this tool.')];
        }
        return [
          Finding(
            Severity.warning,
            '`just` on the PATH is another program (${normalPath(f.path)}).',
            fix: 'Use `ju`: the same tool under a second name.',
          ),
        ];
      }
    }
    return const [];
  }

  /// The plugins' broken manifests and command-name clashes.
  List<Finding> _plugins() {
    final problems = <String>[];
    discoverPluginCommands(
      context,
      taken: {
        for (final e in justRunner.commands.entries)
          if (e.value is! PluginCommand) e.key,
      },
      problems: problems,
    );
    return [
      for (final p in problems)
        Finding(
          Severity.warning,
          p,
          // A manifest that can't be read, or a command-name clash.
          fix: p.contains(PluginManifest.fileName)
              ? "The plugin's ${PluginManifest.fileName} can't be used: it "
                    "isn't UTF-8 or valid JSON, or needs a newer just. Fix "
                    'or reinstall the package, or upgrade just.'
              : 'Remove the package, or ask its author to rename the '
                    'command.',
        ),
    ];
  }

  /// Whether [f], a `just` on the PATH, is this tool: the running program,
  /// one in the same folder (a release's `just` beside its `ju`), one with a
  /// `ju` beside it (as the install scripts lay them out), or pub's launcher
  /// script for just_core_cli.
  static bool _isOurs(File f) {
    final path = normalPath(f.absolute.path);
    final self = normalPath(Platform.resolvedExecutable);
    if (samePath(path, self)) return true;
    final folder = path.substring(0, path.lastIndexOf('/'));
    final selfName = self.split('/').last.toLowerCase().replaceAll('.exe', '');
    if ((selfName == 'just' || selfName == 'ju') &&
        samePath(folder, self.substring(0, self.lastIndexOf('/')))) {
      return true;
    }
    final ext = Platform.isWindows ? '.exe' : '';
    if (f.lengthSync() > 64 * 1024) {
      return File('$folder/ju$ext').existsSync();
    }
    try {
      // pub's launcher script names the package it runs.
      return f.readAsStringSync().contains('just_core_cli');
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    }
  }

  Future<List<Finding>> _project(JustProject project) async {
    final out = <Finding>[];
    var set = ToolSet.current;
    try {
      set = _setOf(project);
    } on JsonFormatException catch (e) {
      out.add(
        Finding(
          Severity.problem,
          '$e',
          fix:
              'Fix ${JustProject.projectFile}, or remove it to start from the '
              'defaults.',
        ),
      );
    }
    final sdk = await SdkLocator.find(
      project.root,
      environment: context.environment,
    );

    // The SDKs.
    if (sdk == null) {
      out.add(
        const Finding(
          Severity.problem,
          'Flutter was not found.',
          fix: 'Install it, put it on the PATH, or set FLUTTER_ROOT.',
        ),
      );
    } else {
      // The floors are the plugins' to check: they know what they need.
      final flutter = sdk.flutterVersion;
      final dart = sdk.dartVersion;
      out.add(
        Finding(
          Severity.ok,
          'Flutter ${flutter ?? '(version unknown)'} at ${sdk.root}'
          '${dart == null ? '' : ', with Dart $dart'}.',
        ),
      );
    }

    // What pub resolved.
    final config = PackageConfig.read(project.root);
    if (config == null) {
      out.add(
        const Finding(
          Severity.problem,
          "The project's packages have not been fetched.",
          fix: 'Run `flutter pub get`.',
        ),
      );
      return [...out, ..._files(project)];
    }
    final versions = <String, Version>{
      for (final p in config.packages.values)
        p.name: ?Version.tryParse(
          pubspecVersion('${p.rootPath}/pubspec.yaml') ?? '',
        ),
    };

    // The tool itself.
    final pinned = versions['just_core_cli'];
    if (!ProjectPin.declares(project)) {
      out.add(
        Finding(
          Severity.warning,
          'The project does not pin just_core_cli.',
          fix:
              'Add `just_core_cli: ${set['just_core_cli']?.constraint ?? '^0.1.0'}` to '
              'dev_dependencies, so everyone runs the same just on it.',
        ),
      );
    } else if (pinned != null) {
      out.add(Finding(Severity.ok, 'The project pins just_core_cli $pinned.'));
    }

    // The tools, against the tool set.
    for (final p in set.packages) {
      final v = versions[p.name];
      if (v == null) continue;
      if (!p.versions.allows(v)) {
        out.add(
          Finding(
            Severity.warning,
            '${p.name} is $v; the ${set.id} tool set has ${p.constraint}.',
            fix: '`${context.invokedAs} upgrade` moves the project to its set.',
          ),
        );
      }
    }

    // Constraints a path override hides: fine here, broken in a clone.
    for (final p in config.packages.values) {
      if (!p.name.startsWith('just_')) continue;
      final pubspec = File('${p.rootPath}/pubspec.yaml');
      if (!pubspec.existsSync()) continue;
      for (final dep in _justConstraints(pubspec.readAsStringSync()).entries) {
        final have = versions[dep.key];
        final want = VersionConstraint.tryParse(dep.value);
        if (have == null || want == null || want.allows(have)) continue;
        out.add(
          Finding(
            Severity.problem,
            '${p.name} asks for ${dep.key} ${dep.value}, but $have is what '
            'resolves (an override hides it).',
            fix:
                'Fix the constraint in ${p.name}, or the version in '
                '${dep.key}: a project without the override will not resolve.',
          ),
        );
      }
    }
    return [...out, ..._files(project)];
  }

  /// The project's files: its links to checkouts ignored by git.
  List<Finding> _files(JustProject project) {
    final out = <Finding>[];
    final ignore = project.readText('.gitignore') ?? '';
    final missing = GitIgnores.missing(ignore, GitIgnores.links);
    if (missing.isNotEmpty) {
      out.add(
        Finding(
          Severity.warning,
          '.gitignore does not ignore ${missing.join(', ')}, which holds '
          "this machine's paths.",
          fix: 'Add it to .gitignore.',
        ),
      );
    }

    return out;
  }

  static bool _readable(JustProject project) {
    try {
      project.readProjectFile();
      return true;
    } on JsonFormatException {
      return false;
    }
  }

  ToolSet _setOf(JustProject project) {
    final id = project.readProjectFile().set;
    return (id == null ? null : ToolSet.named(id)) ?? ToolSet.current;
  }

  /// The `just_*` dependencies [pubspec] declares, with their constraints,
  /// from `dependencies` and `dev_dependencies`.
  static Map<String, String> _justConstraints(String pubspec) => {
    for (final s in const ['dependencies', 'dev_dependencies'])
      for (final e in _section(pubspec, s).entries)
        if (e.key.startsWith('just_') && e.value.isNotEmpty) e.key: e.value,
  };

  /// The entries of a top-level [section]: name → its inline constraint
  /// (empty for a block like `path:` or `sdk:`).
  static Map<String, String> _section(String pubspec, String section) {
    final out = <String, String>{};
    var inside = false;
    for (final raw in pubspec.split('\n')) {
      final line = raw.trimRight();
      if (line.isEmpty || line.trimLeft().startsWith('#')) continue;
      if (!line.startsWith(' ')) {
        inside = line.startsWith('$section:');
        continue;
      }
      if (!inside) continue;
      final m = RegExp(r'^  ([A-Za-z_]\w*)\s*:\s*(.*)$').firstMatch(line);
      if (m == null) continue;
      var value = m.group(2)!.trim();
      if (value.startsWith('"') || value.startsWith("'")) {
        value = value.substring(1, value.length - 1);
      }
      out[m.group(1)!] = value;
    }
    return out;
  }
}

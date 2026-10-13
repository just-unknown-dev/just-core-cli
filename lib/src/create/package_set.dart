/// Versions of packages that work together: the model every set uses, and
/// the tool set `just` itself carries.
library;

import '../json/semver.dart';

/// Where a package in a set comes from.
enum PackageSource {
  /// pub.dev: a version constraint.
  hosted,

  /// Installed into the project by a plugin, from its own catalog — not
  /// resolved by pub from a constraint.
  plugin,

  /// A git repository, at a tag: for a package that has to be in the
  /// project before anything else can install it (a plugin that installs
  /// packages).
  git,
}

/// One package of a set.
final class SetPackage {
  /// [name] at [constraint], from [source] ([git] holds the repository,
  /// [ref] the tag and [path] the package's folder in it when it is
  /// [PackageSource.git]).
  const SetPackage(
    this.name,
    this.constraint, {
    this.source = PackageSource.hosted,
    this.git,
    this.ref,
    this.path,
    this.dev = false,
  });

  /// The package's name.
  final String name;

  /// The versions the set allows: `^2.0.0`.
  final String constraint;

  /// Where it comes from.
  final PackageSource source;

  /// The repository, for [PackageSource.git].
  final String? git;

  /// The tag, for [PackageSource.git].
  final String? ref;

  /// Where in the repository the package is, for [PackageSource.git]; null
  /// when it is the repository's root.
  final String? path;

  /// Whether a project lists it under `dev_dependencies` (tools: what must
  /// never ship).
  final bool dev;

  /// [constraint], parsed.
  VersionConstraint get versions => VersionConstraint.parse(constraint);
}

/// Packages, at versions that work together, under a name ([id]).
///
/// The core's own is the [ToolSet]; a plugin that manages packages of its
/// own extends this with them (and with what else they need, an SDK floor
/// say).
class PackageSet {
  /// The set [id], holding [packages].
  const PackageSet({required this.id, required this.packages});

  /// Its name: the year and month it was made, say.
  final String id;

  /// The packages, and where each comes from.
  final List<SetPackage> packages;

  /// The package [name], or null when the set has none.
  SetPackage? operator [](String name) {
    for (final p in packages) {
      if (p.name == name) return p;
    }
    return null;
  }
}

/// The tools `just` keeps a project on: just_core_cli itself, and the
/// plugin of each kind of project `just create` makes ([kinds]).
///
/// It is what `just create` adds to a new project, what `just doctor`
/// checks the tools against and what `just upgrade` moves them to; its id
/// is the `set` in `just.json`. Each plugin keeps its own packages' versions
/// and moves them through its `upgrade` hook.
///
/// Each just_core_cli release carries its own tool set, so the tool and the
/// versions it writes are always tested together.
final class ToolSet extends PackageSet {
  /// The tool set [id], holding [packages], with the [kinds] of project
  /// `just create` makes.
  const ToolSet({
    required super.id,
    required super.packages,
    this.kinds = const {},
  });

  /// The tool set this version of just_core_cli is made for.
  static const ToolSet current = ToolSet(
    id: '2026.10',
    packages: [
      SetPackage('just_core_cli', '^0.1.0', dev: true),
      SetPackage('just_game_engine_cli', '^0.1.0', dev: true),
    ],
    kinds: {'game': 'just_game_engine_cli'},
  );

  /// The tool sets this version knows, oldest first.
  static const List<ToolSet> known = [current];

  /// The tool set called [id], or null when this version doesn't know it.
  static ToolSet? named(String id) {
    for (final s in known) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// The kinds of project `just create` makes, each with the plugin package
  /// that fills one in (its `create` hook): `game` → `just_game_engine_cli`.
  /// The first is the default.
  final Map<String, String> kinds;
}

/// `just.json`: what `just` knows about a project.
library;

import '../create/package_set.dart';
import '../json/json.dart';

/// A project's `just.json`.
///
/// ```json
/// {
///   "schema": 1,
///   "title": "Space Rocks",
///   "set": "2026.10",
///   "entry": {"app": "lib/main.dart", "tool": "bin/tool.dart"},
///   "plugins": {"allowed": ["my_studio_tools"]}
/// }
/// ```
///
/// Everything is optional: a project without the file gets the defaults.
/// What this version doesn't know — a newer tool's keys, a plugin's own —
/// is kept as it was whenever the file is written again.
final class JustProjectFile {
  /// A project file with these values.
  const JustProjectFile({
    this.title,
    this.set,
    this.entries = const {},
    this.allowedPlugins = const [],
    this.extra = const {},
  }) : _pluginsExtra = const {},
       _entryExtra = const {},
       _entryRaw = null;

  const JustProjectFile._({
    required this.title,
    required this.set,
    required this.entries,
    required this.allowedPlugins,
    required this.extra,
    required Map<String, Object?> pluginsExtra,
    required Map<String, Object?> entryExtra,
    required Object? entryRaw,
  }) : _pluginsExtra = pluginsExtra,
       _entryExtra = entryExtra,
       _entryRaw = entryRaw;

  /// The newest `just.json` format this version reads.
  static const int currentSchema = 1;

  /// The keys this version reads; every other one is [extra].
  static const Set<String> knownKeys = {
    'schema',
    'title',
    'set',
    'entry',
    'plugins',
  };

  /// The project's name as people see it — the app's title. A product's
  /// release check can look for it in a build to know whose build it is.
  final String? title;

  /// The tool set ([ToolSet]) the project's tools come from; each plugin
  /// keeps its own packages' versions.
  final String? set;

  /// The project's entry points by name (`entry` in the file): `app` →
  /// `lib/main.dart`. The products that read one know its default. Only
  /// the string values are here; any other value is kept as it was.
  final Map<String, String> entries;

  /// Packages whose `just` commands the user allowed, beyond the official
  /// ones.
  final List<String> allowedPlugins;

  /// The file's other top-level keys, as they were read: a newer tool's, or
  /// a plugin's own. Written back as they are.
  final Map<String, Object?> extra;

  /// The keys of `plugins` besides `allowed`, kept as they were.
  final Map<String, Object?> _pluginsExtra;

  /// The keys of `entry` whose values are not strings, kept as they were.
  final Map<String, Object?> _entryExtra;

  /// `entry` as it was, when it is not an object at all.
  final Object? _entryRaw;

  /// [text] as a project file.
  static JustProjectFile parse(String text) {
    final json = JsonFields.parse(text);
    final schema = json.optInt('schema', min: 1) ?? 1;
    if (schema > currentSchema) {
      throw json.error(
        'schema',
        'This project was saved by a newer version of just (format '
            '$schema). Update just_core_cli.',
      );
    }
    final plugins = json.optObject('plugins');
    final entry = json.raw('entry');
    return JustProjectFile._(
      title: json.optString('title'),
      set: json.optString('set'),
      entries: {
        if (entry is Map)
          for (final e in entry.entries)
            if (e.value is String) '${e.key}': e.value as String,
      },
      entryExtra: {
        if (entry is Map)
          for (final e in entry.entries)
            if (e.value is! String) '${e.key}': e.value,
      },
      entryRaw: entry is Map ? null : entry,
      allowedPlugins: plugins?.strings('allowed') ?? const [],
      extra: {
        for (final k in json.keys)
          if (!knownKeys.contains(k)) k: json.raw(k),
      },
      pluginsExtra: {
        for (final k in plugins?.keys ?? const <String>[])
          if (k != 'allowed') k: plugins!.raw(k),
      },
    );
  }

  /// A copy with the values given replaced; what the file held besides
  /// them stays.
  JustProjectFile copyWith({
    String? title,
    String? set,
    Map<String, String>? entries,
    List<String>? allowedPlugins,
    Map<String, Object?>? extra,
  }) => JustProjectFile._(
    title: title ?? this.title,
    set: set ?? this.set,
    entries: entries ?? this.entries,
    allowedPlugins: allowedPlugins ?? this.allowedPlugins,
    extra: extra ?? this.extra,
    pluginsExtra: _pluginsExtra,
    entryExtra: _entryExtra,
    entryRaw: _entryRaw,
  );

  /// A copy that allows [package]'s commands.
  JustProjectFile allowing(String package) =>
      copyWith(allowedPlugins: {...allowedPlugins, package}.toList()..sort());

  /// The file's text. The keys this version knows are left out when they
  /// say nothing (no title, no entries); what it doesn't know is written
  /// back as it was read — a `null`, `{}` or `[]` too.
  String toText() {
    final plugins = {
      ..._pluginsExtra,
      if (allowedPlugins.isNotEmpty) 'allowed': allowedPlugins,
    };
    final entry = _entryRaw != null && entries.isEmpty
        ? _entryRaw
        : {..._entryExtra, ...entries};
    return canonicalJson({
      ...extra,
      ...compactJson({
        'schema': currentSchema,
        'title': title,
        'set': set,
        'entry': entry,
      }),
      if (plugins.isNotEmpty) 'plugins': plugins,
    });
  }
}

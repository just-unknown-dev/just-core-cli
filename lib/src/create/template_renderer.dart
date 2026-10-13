/// Filling in a template's files for a new project, and the lines a new
/// project's files get.
library;

import 'dart:convert';

import '../project/project_paths.dart';
import '../project/pubspec_editor.dart';
import 'package_set.dart';

/// What a new project is called, and how its files name it.
final class ProjectNames {
  /// The names for the package [name], titled [title] (from the name when
  /// null).
  ProjectNames(this.name, {String? title})
    : title = title ?? _titleOf(name),
      app = '${_pascal(name)}App';

  /// The Dart package name: `space_rocks`.
  final String name;

  /// The project's name as people see it: `Space Rocks`.
  final String title;

  /// The app widget's class: `SpaceRocksApp`.
  final String app;

  static String _titleOf(String name) => name
      .split('_')
      .where((w) => w.isNotEmpty)
      .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');

  static String _pascal(String name) => _titleOf(name).replaceAll(' ', '');

  /// Why [title] can't be a project's title, or null when it can: it must
  /// have something besides spaces, and no control characters (a line
  /// break, a tab), which no file it goes into could hold as they are.
  static String? titleProblem(String title) {
    if (title.trim().isEmpty) return 'It is empty.';
    for (final c in title.runes) {
      if (c < 0x20 || (c >= 0x7F && c <= 0x9F) || c == 0x2028 || c == 0x2029) {
        return 'It holds a control character (U+'
            '${c.toRadixString(16).toUpperCase().padLeft(4, '0')}): leave it '
            'out.';
      }
    }
    return null;
  }

  /// [text] for the inside of a Dart string literal quoted with `'`.
  static String dartString(String text) => text
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$');

  /// [text] for the inside of a YAML string quoted with `"`.
  static String yamlString(String text) =>
      text.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

  /// [text] for the inside of a JSON string.
  static String jsonString(String text) {
    final quoted = jsonEncode(text);
    return quoted.substring(1, quoted.length - 1);
  }

  /// [text] for XML (a plist, an Android manifest): text or an attribute.
  static String xmlText(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  /// [text] for the inside of a C or C++ string literal (a runner's).
  static String cString(String text) =>
      text.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
}

/// Fills a template's placeholders for one project.
///
/// A placeholder is a key in double braces. The names every project has
/// come from [ProjectNames]: `{{name}}` (the package name), `{{App}}` (the
/// app widget's class), and the title — `{{title}}` as it is (for comments
/// and Markdown), or escaped for where it goes: `{{title.dart}}` in a Dart
/// string quoted with `'`, `{{title.yaml}}` in a YAML string quoted with
/// `"`, `{{title.json}}`, `{{title.xml}}` and `{{title.c}}` (a C/C++
/// string). A product adds its own values, and lists of lines (a pubspec's
/// dependencies), each written as lines of their own.
///
/// Each placeholder is filled once: what is filled in is never read as a
/// placeholder. One nobody gave a value for is left as it is.
abstract final class TemplateRenderer {
  static final RegExp _placeholder = RegExp(
    r'\{\{([A-Za-z_]+(?:\.[a-z]+)?)\}\}(\r?\n)?',
  );

  /// The values every project has, by placeholder: its names and its
  /// title, escaped for each kind of file.
  static Map<String, String> namesOf(ProjectNames names) => {
    'name': names.name,
    'title': names.title,
    'title.dart': ProjectNames.dartString(names.title),
    'title.yaml': ProjectNames.yamlString(names.title),
    'title.json': ProjectNames.jsonString(names.title),
    'title.xml': ProjectNames.xmlText(names.title),
    'title.c': ProjectNames.cString(names.title),
    'App': names.app,
  };

  /// [files] (path → text) with their placeholders filled for [names],
  /// plus [values] and [lines]. A placeholder in [lines] is replaced, with
  /// the line break after it, by its lines, each ending in a line break
  /// (nothing at all for none). Throws [ArgumentError] for a title with a
  /// [ProjectNames.titleProblem].
  static Map<String, String> render(
    Map<String, String> files, {
    required ProjectNames names,
    Map<String, String> values = const {},
    Map<String, List<String>> lines = const {},
  }) {
    final titleProblem = ProjectNames.titleProblem(names.title);
    if (titleProblem != null) {
      throw ArgumentError.value(names.title, 'names.title', titleProblem);
    }
    final all = {...namesOf(names), ...values};
    String fill(String text) {
      // A block's lines end as the file's lines do.
      final fileEnding = text.contains('\r\n') ? '\r\n' : '\n';
      return text.replaceAllMapped(_placeholder, (m) {
        final key = m.group(1)!;
        final newline = m.group(2) ?? '';
        final block = lines[key];
        if (block != null) {
          final nl = newline.isEmpty ? fileEnding : newline;
          return block.isEmpty ? '' : '${block.join(nl)}$nl';
        }
        final value = all[key];
        return value == null ? m.group(0)! : '$value$newline';
      });
    }

    return {for (final e in files.entries) e.key: fill(e.value)};
  }

  /// The pubspec lines for [package]: a constraint, a git source, or a
  /// constraint resolved through a path override ([hosted], for linked
  /// checkouts). Each value is written as [PubspecEditor.scalar] writes it
  /// — quoted when YAML would read it otherwise (`>=1.0.0 <2.0.0`, a URL
  /// with a `#`) — so it reads back as the same string.
  static List<String> dependencyLines(
    SetPackage package, {
    bool hosted = false,
  }) {
    final q = PubspecEditor.scalar;
    if (package.source == PackageSource.git && !hosted) {
      return [
        '  ${package.name}:',
        '    git:',
        '      url: ${q(package.git ?? '')}',
        '      ref: ${q(package.ref ?? '')}',
        if (package.path != null) '      path: ${q(package.path!)}',
      ];
    }
    return ['  ${package.name}: ${q(package.constraint)}'];
  }
}

/// A project's `.gitignore`, added to without disturbing it.
abstract final class GitIgnores {
  /// What every project ignores: its links to local checkouts
  /// (`just dev link`), whose paths are this machine's.
  static const List<String> links = ['pubspec_overrides.yaml'];

  /// The entries among [entries] that [text] (a `.gitignore`) does not
  /// ignore, as lines of their own.
  static List<String> missing(String text, Iterable<String> entries) {
    final have = text.split(RegExp(r'\r?\n')).map((l) => l.trim()).toSet();
    return [
      for (final e in entries)
        if (!have.contains(e)) e,
    ];
  }

  /// [text] (a `.gitignore`) with [entries] ignored, the missing ones added
  /// at the end under [comment] (each of its lines a `#` comment), in the
  /// file's own line endings; unchanged when it ignores them all.
  static String withEntries(
    String text,
    Iterable<String> entries, {
    String? comment,
  }) {
    final add = missing(text, entries);
    if (add.isEmpty) return text;
    final nl = text.contains('\r\n') ? '\r\n' : '\n';
    final lead = text.isEmpty || text.endsWith(nl) ? '' : nl;
    final note = comment == null
        ? ''
        : [for (final l in comment.split('\n')) '# $l$nl'].join();
    // A blank line before the new entries, unless the file was empty.
    final gap = text.isEmpty ? '' : nl;
    return '$text$lead$gap$note${add.join(nl)}$nl';
  }

  /// [text] with [links] ignored.
  static String withLinks(String text) => withEntries(
    text,
    links,
    comment: 'Links to local checkouts (`just dev link`): machine-local.',
  );

  /// The default trash: where a change's replaced and removed folders go
  /// ([ProjectPaths.trashRoot]), restorable but not shared.
  static const List<String> trash = ['${ProjectPaths.trashRoot}/'];

  /// [text] with what every new project ignores: [links] and [trash].
  static String withDefaults(String text) => withEntries(
    withLinks(text),
    trash,
    comment: 'What changes by `just` and its plugins moved aside: restorable.',
  );
}

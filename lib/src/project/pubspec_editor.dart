/// Line-based edits to `pubspec.yaml` and `pubspec_overrides.yaml` that keep
/// everything outside a tool's marked block exactly as it was.
library;

/// Whose block a [PubspecEditor] edits: the markers around the entries one
/// tool owns. Each tool edits only its own block, so several tools — a
/// plugin that installs packages, `just dev link` — can manage overrides in
/// the same file. Each tool defines its own block, and keeps its markers
/// as projects already hold them.
final class ManagedBlock {
  /// The block [owner] manages, its start marker saying [hint]. The owner
  /// is a tool's name — letters, digits, `_`, `.` and `-` ([isValid]) — and
  /// the hint one line; [PubspecEditor.parse] refuses any other.
  const ManagedBlock(this.owner, {this.hint}) : assert(owner.length > 0);

  /// Whether [owner] is a name the markers can carry (letters, digits,
  /// `_`, `.`, `-`) and [hint] fits on the marker's line.
  bool get isValid =>
      RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(owner) &&
      !(hint?.contains(RegExp('[\r\n]')) ?? false);

  /// `just dev link`'s block: path overrides to local checkouts.
  static const ManagedBlock devLinks = ManagedBlock(
    'just_core_cli',
    hint: 'just dev link',
  );

  /// Who manages the entries, as the markers name them.
  final String owner;

  /// What to do instead of editing by hand, shown in the start marker.
  final String? hint;

  /// The block's first line, after its indent.
  String get start =>
      '# >>> $owner managed${hint == null ? '' : ' ($hint)'} >>>';

  /// The block's last line, after its indent.
  String get end => '# <<< $owner managed <<<';

  /// What a start marker begins with, whatever its hint says.
  String get startPrefix => '# >>> $owner managed';

  /// What an end marker begins with.
  String get endPrefix => '# <<< $owner managed';
}

/// A dependency as a tool writes it into a pubspec.
sealed class DependencySpec {
  const DependencySpec();

  /// The YAML lines for `name:` at [indent], each without a line ending.
  List<String> toLines(String name, String indent);
}

/// `name: {path: ...}`, written as a block.
final class PathDependency extends DependencySpec {
  /// A dependency on the package at [path], relative to the pubspec.
  const PathDependency(this.path);

  /// The folder, with `/` between parts.
  final String path;

  @override
  List<String> toLines(String name, String indent) => [
    '$indent$name:',
    '$indent  path: ${_scalar(path)}',
  ];

  @override
  bool operator ==(Object other) =>
      other is PathDependency && _normalPath(other.path) == _normalPath(path);

  @override
  int get hashCode => _normalPath(path).hashCode;

  @override
  String toString() => 'path: $path';
}

/// `name: ^1.2.0`, from pub.dev (or [url]'s repository).
final class HostedDependency extends DependencySpec {
  /// A dependency on [constraint] of a hosted package.
  const HostedDependency(this.constraint, {this.url});

  /// The version constraint, as written.
  final String constraint;

  /// The package repository, when not pub.dev.
  final String? url;

  @override
  List<String> toLines(String name, String indent) => url == null
      ? ['$indent$name: ${_scalar(constraint)}']
      : [
          '$indent$name:',
          '$indent  hosted: ${_scalar(url!)}',
          '$indent  version: ${_scalar(constraint)}',
        ];

  @override
  bool operator ==(Object other) =>
      other is HostedDependency &&
      other.constraint.trim() == constraint.trim() &&
      other.url == url;

  @override
  int get hashCode => Object.hash(constraint.trim(), url);

  @override
  String toString() => url == null ? constraint : '$constraint from $url';
}

/// A dependency written in a form a tool doesn't write itself (git,
/// sdk, flow maps with several keys…). Kept as text.
final class OtherDependency extends DependencySpec {
  /// [text], the entry's lines as found.
  const OtherDependency(this.text);

  /// The entry's lines, joined with `\n`.
  final String text;

  @override
  List<String> toLines(String name, String indent) => text.split('\n');

  @override
  bool operator ==(Object other) =>
      other is OtherDependency && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => text.trim();
}

/// A pubspec a tool can't edit safely, or an edit that would clash with
/// lines it doesn't own.
final class PubspecEditException implements Exception {
  /// [message] about the file, naming [names] when it is about entries.
  const PubspecEditException(this.message, {this.names = const []});

  /// What is wrong, in a sentence.
  final String message;

  /// The entries involved.
  final List<String> names;

  @override
  String toString() => 'PubspecEditException: $message';
}

/// A `pubspec.yaml` or `pubspec_overrides.yaml` held as lines, edited only
/// inside one tool's marked block ([marker]) — here `my_tool`'s, made with
/// `ManagedBlock('my_tool', hint: 'my_tool add')`:
///
/// ```yaml
/// dependency_overrides:
///   # >>> my_tool managed (my_tool add) >>>
///   some_package:
///     path: packages/some_package
///   # <<< my_tool managed <<<
/// ```
///
/// Everything outside the blocks — comments, order, blank lines, a byte
/// order mark, CRLF or LF line endings, a missing final newline — comes
/// back exactly as it was. Sections written inline (`dependencies: {}`),
/// tabs in indentation and YAML anchors are refused rather than guessed at.
///
/// Another tool's block — any pair of `# >>> owner managed` and
/// `# <<< owner managed <<<` lines — is off-limits: its entries are never
/// taken over or removed, and writing one of them into this block is a
/// clash.
final class PubspecEditor {
  PubspecEditor._(this._lines, this._ends, this._eol, this._bom, this.marker);

  /// Reads [text], to edit inside [marker]'s block.
  ///
  /// Throws [ArgumentError] for a [marker] that isn't [ManagedBlock.isValid].
  factory PubspecEditor.parse(String text, {required ManagedBlock marker}) {
    if (!marker.isValid) {
      throw ArgumentError.value(
        marker.owner,
        'marker',
        'A block is named after a tool (letters, digits, _ . -), its hint '
            'one line',
      );
    }
    var body = text;
    final bom = body.startsWith('\uFEFF');
    if (bom) body = body.substring(1);
    final crlf = '\r\n'.allMatches(body).length;
    final lf = '\n'.allMatches(body).length - crlf;
    final eol = crlf > lf ? '\r\n' : '\n';
    // Each line keeps its own ending, so a file with mixed endings comes
    // back as it was; lines the tool adds use the more common one.
    final lines = <String>[];
    final ends = <String>[];
    var start = 0;
    while (start < body.length) {
      final nl = body.indexOf('\n', start);
      if (nl < 0) {
        lines.add(body.substring(start));
        ends.add('');
        break;
      }
      var line = body.substring(start, nl);
      var end = '\n';
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
        end = '\r\n';
      }
      lines.add(line);
      ends.add(end);
      start = nl + 1;
    }
    return PubspecEditor._(lines, ends, eol, bom, marker);
  }

  /// Whose marked block this edits.
  final ManagedBlock marker;

  /// [value] written so YAML reads it back as the same string: plain when
  /// it can be, else single-quoted — `>=1.0.0 <2.0.0` and `1.0` (a number
  /// otherwise) quoted, `^1.2.3` as it is.
  static String scalar(String value) => _scalar(value);

  final List<String> _lines;

  /// What ends each line in [_lines]: `\r\n`, `\n`, or nothing for a last
  /// line without a final newline.
  final List<String> _ends;
  final String _eol;
  final bool _bom;

  /// The file's text, with its line endings, byte order mark and final
  /// newline as they were.
  String get text {
    final out = StringBuffer();
    if (_bom) out.write('\uFEFF');
    for (var i = 0; i < _lines.length; i++) {
      out
        ..write(_lines[i])
        ..write(_ends[i]);
    }
    return out.toString();
  }

  /// The line ending the file mostly uses, which added lines get: `\r\n` or
  /// `\n`.
  String get lineEnding => _eol;

  /// Inserts [lines] before line [at], ending each with [lineEnding]. At
  /// the end of the file, the last new line takes over whether the file
  /// ended with a newline.
  void _insert(int at, List<String> lines) {
    if (lines.isEmpty) return;
    final ends = List.filled(lines.length, _eol);
    if (at == _lines.length && _lines.isNotEmpty) {
      ends[ends.length - 1] = _ends.last;
      _ends[_ends.length - 1] = _eol;
    }
    _lines.insertAll(at, lines);
    _ends.insertAll(at, ends);
  }

  /// Removes lines [start] (inclusive) to [end] (exclusive). Removing the
  /// last line hands its ending (or the lack of one) to the new last line.
  void _remove(int start, int end) {
    if (start >= end) return;
    final tail = end == _lines.length ? _ends.last : null;
    _lines.removeRange(start, end);
    _ends.removeRange(start, end);
    if (tail != null && _lines.isNotEmpty) _ends[_ends.length - 1] = tail;
  }

  /// Whether the top-level [section] exists.
  bool hasSection(String section) => _find(section) != null;

  /// The names melos says it manages, from a
  /// `# melos_managed_dependency_overrides: a,b` comment.
  Set<String> get melosManaged {
    for (final line in _lines) {
      final m = RegExp(
        r'^\s*#\s*melos_managed_dependency_overrides\s*:\s*(.*)$',
      ).firstMatch(line);
      if (m != null) {
        return {
          for (final name in m[1]!.split(','))
            if (name.trim().isNotEmpty) name.trim(),
        };
      }
    }
    return const {};
  }

  /// The entries in [section]'s managed block.
  Map<String, DependencySpec> managed(String section) {
    final s = _find(section);
    if (s == null) return const {};
    final block = _block(s);
    if (block == null) return const {};
    return _entries(block.start + 1, block.end, s.childIndent);
  }

  /// The entries in [section] outside its managed block (other tools'
  /// blocks included).
  Map<String, DependencySpec> unmanaged(String section) {
    final s = _find(section);
    if (s == null) return const {};
    final block = _block(s);
    if (block == null) return _entries(s.start + 1, s.end, s.childIndent);
    return {
      ..._entries(s.start + 1, block.start, s.childIndent),
      ..._entries(block.end + 1, s.end, s.childIndent),
    };
  }

  /// The entries in [s] outside every tool's block: the ones a person
  /// wrote.
  Map<String, DependencySpec> _written(_Section s) {
    final out = <String, DependencySpec>{};
    var from = s.start + 1;
    for (final b in _blocks(s)) {
      out.addAll(_entries(from, b.start, s.childIndent));
      from = b.end + 1;
    }
    out.addAll(_entries(from, s.end, s.childIndent));
    return out;
  }

  /// The entries in other tools' blocks in [s], with their owners.
  Map<String, String> _foreign(_Section s) => {
    for (final b in _blocks(s))
      if (b.owner != marker.owner)
        for (final name in _entries(b.start + 1, b.end, s.childIndent).keys)
          name: b.owner,
  };

  /// Makes [section]'s managed block hold exactly [entries], sorted by
  /// name.
  ///
  /// An entry a person wrote in the section is taken into the block when it
  /// is identical (the tool adopts what it would have written). When it
  /// differs, when another tool's block holds the name, or when melos
  /// manages it, a [PubspecEditException] lists the clashes and nothing
  /// changes. An empty [entries] removes the block, and the section's
  /// header too when the block was all it held; a section without the
  /// block is left as it is.
  void setManaged(String section, Map<String, DependencySpec> entries) {
    var s = _find(section);
    if (s != null) {
      final written = _written(s);
      final foreign = _foreign(s);
      final melos = section == 'dependency_overrides'
          ? melosManaged
          : const <String>{};
      final differ = [
        for (final e in entries.entries)
          if (melos.contains(e.key) ||
              (written.containsKey(e.key) && written[e.key] != e.value))
            e.key,
      ]..sort();
      final others = [
        for (final name in entries.keys)
          if (foreign.containsKey(name)) name,
      ]..sort();
      if (differ.isNotEmpty || others.isNotEmpty) {
        throw PubspecEditException(
          [
            if (differ.isNotEmpty)
              'These are already in $section, written differently: '
                  '${differ.join(', ')}.',
            if (others.isNotEmpty)
              'These are in $section in another tool\'s block '
                  '(${{for (final n in others) foreign[n]}.join(', ')}): '
                  '${others.join(', ')}.',
          ].join(' '),
          names: {...differ, ...others}.toList()..sort(),
        );
      }
      // Adopt identical entries: remove them from where they were written.
      for (final name in entries.keys) {
        if (written.containsKey(name)) {
          _removeEntry(section, name);
        }
      }
      s = _find(section)!;
    }

    if (entries.isEmpty) {
      if (s == null) return;
      final block = _block(s);
      if (block == null) return; // Nothing of ours: left as written.
      _remove(block.start, block.end + 1);
      final after = _find(section)!;
      final hasContent =
          _lines[after.start].contains('#') ||
          [
            for (var i = after.start + 1; i < after.end; i++) _lines[i],
          ].any((l) => l.trim().isNotEmpty);
      if (!hasContent) {
        // Drop the now-empty header (and the blank lines it would leave).
        var end = after.start + 1;
        while (end < after.end && _lines[end].trim().isEmpty) {
          end++;
        }
        _remove(after.start, end);
        _trimBlankRun(after.start);
      }
      return;
    }

    final indent = ' ' * (s?.childIndent ?? 2);
    final names = entries.keys.toList()..sort();
    final blockLines = [
      '$indent${marker.start}',
      for (final name in names) ...entries[name]!.toLines(name, indent),
      '$indent${marker.end}',
    ];

    if (s == null) {
      // A new section at the end of the file, after one blank line.
      while (_lines.isNotEmpty && _lines.last.trim().isEmpty) {
        _remove(_lines.length - 1, _lines.length);
      }
      _insert(_lines.length, [
        if (_lines.isNotEmpty) '',
        '$section:',
        ...blockLines,
      ]);
      return;
    }
    final block = _block(s);
    if (block != null) {
      _remove(block.start, block.end + 1);
      _insert(block.start, blockLines);
      return;
    }
    // Right after the section's last entry line — not after the blank lines
    // and comments that lead into whatever follows it. Another tool's block
    // ends in a comment too, and this one goes after it, never inside.
    var at = s.end;
    while (at > s.start + 1) {
      final l = _lines[at - 1];
      if (l.trim().isNotEmpty &&
          (!l.trimLeft().startsWith('#') || _anyEndMarker.hasMatch(l))) {
        break;
      }
      at--;
    }
    _insert(at, blockLines);
  }

  /// The start marker of any tool's block; group 1 is the tool.
  static final RegExp _anyStartMarker = RegExp(r'^\s*# >>> (\S+) managed\b');

  /// The end marker of any tool's block; group 1 is the tool.
  static final RegExp _anyEndMarker = RegExp(r'^\s*# <<< (\S+) managed <<<');

  /// A top-level key, plain or quoted (groups 1-3), and what follows its
  /// `:` (group 4).
  static final RegExp _sectionKey = RegExp(
    r'''^(?:"([A-Za-z_][\w-]*)"|'([A-Za-z_][\w-]*)'|([A-Za-z_][\w-]*))\s*:(.*)$''',
  );

  /// An entry's key at [indent], plain or quoted (groups 1-3), and what
  /// follows its `:` (group 4).
  static RegExp _entryKey(int indent) => RegExp(
    '^${' ' * indent}'
    r'''(?:"([A-Za-z_]\w*)"|'([A-Za-z_]\w*)'|([A-Za-z_]\w*))\s*:(.*)$''',
  );

  // ---------------------------------------------------------------------

  _Section? _find(String section) {
    for (var i = 0; i < _lines.length; i++) {
      final line = _lines[i];
      final m = _sectionKey.firstMatch(line);
      if (m == null || (m[1] ?? m[2] ?? m[3]) != section) continue;
      final rest = m[4]!.trim();
      if (rest.isNotEmpty && !rest.startsWith('#')) {
        throw PubspecEditException(
          '"$section" is written on one line ("${line.trim()}"). Write it '
          'as a block, one entry per line, so it can be edited.',
        );
      }
      var end = i + 1;
      while (end < _lines.length) {
        final l = _lines[end];
        if (l.isNotEmpty &&
            l[0] != ' ' &&
            l[0] != '\t' &&
            l[0] != '#' &&
            l.trim().isNotEmpty) {
          break;
        }
        end++;
      }
      var childIndent = 2;
      for (var j = i + 1; j < end; j++) {
        final l = _lines[j];
        if (l.startsWith('\t') || RegExp(r'^ *\t').hasMatch(l)) {
          throw PubspecEditException(
            '"$section" uses tabs for indentation, which YAML forbids.',
          );
        }
        if (RegExp(r':\s*[&*][A-Za-z0-9_]').hasMatch(l) ||
            RegExp(r'^\s*<<\s*:').hasMatch(l)) {
          throw PubspecEditException(
            '"$section" uses YAML anchors or aliases; only plain entries are '
            'edited.',
          );
        }
      }
      for (var j = i + 1; j < end; j++) {
        final l = _lines[j];
        if (l.trim().isEmpty || l.trimLeft().startsWith('#')) continue;
        childIndent = l.length - l.trimLeft().length;
        break;
      }
      // Trailing column-0 comments belong to whatever follows.
      while (end > i + 1 && _lines[end - 1].startsWith('#')) {
        end--;
      }
      return _Section(i, end, childIndent);
    }
    return null;
  }

  /// This tool's block in [s], or null. Throws when there are two.
  _Block? _block(_Section s) {
    _Block? own;
    for (final b in _blocks(s)) {
      if (b.owner != marker.owner) continue;
      if (own != null) {
        throw PubspecEditException(
          'The ${marker.owner} block appears twice in "${_name(s)}"; merge '
          'them into one.',
        );
      }
      own = b;
    }
    return own;
  }

  /// Every tool's block in [s], in order. Throws when one has a start but
  /// no end, an end but no start, or another block inside it.
  List<_Block> _blocks(_Section s) {
    final out = <_Block>[];
    int? start;
    String? owner;
    for (var i = s.start + 1; i < s.end; i++) {
      final line = _lines[i];
      final open = _anyStartMarker.firstMatch(line);
      final close = open == null ? _anyEndMarker.firstMatch(line) : null;
      if (open != null) {
        if (start != null) {
          throw PubspecEditException(
            'The $owner block has a start but no end.',
          );
        }
        start = i;
        owner = open[1];
      } else if (close != null) {
        if (start == null || close[1] != owner) {
          throw PubspecEditException(
            'The ${close[1]} block has an end but no start.',
          );
        }
        out.add(_Block(start, i, owner!));
        start = null;
        owner = null;
      }
    }
    if (start != null) {
      throw PubspecEditException('The $owner block has a start but no end.');
    }
    return out;
  }

  String _name(_Section s) {
    final m = _sectionKey.firstMatch(_lines[s.start])!;
    return m[1] ?? m[2] ?? m[3]!;
  }

  Map<String, DependencySpec> _entries(int from, int to, int indent) {
    final out = <String, DependencySpec>{};
    final key = _entryKey(indent);
    var i = from;
    while (i < to) {
      final line = _lines[i];
      final m = key.firstMatch(line);
      if (m == null || line.trimLeft().startsWith('#')) {
        i++;
        continue;
      }
      final name = m[1] ?? m[2] ?? m[3]!;
      final value = _stripComment(m[4]!).trim();
      final children = <String>[];
      var j = i + 1;
      while (j < to) {
        final l = _lines[j];
        if (l.trim().isEmpty || l.trimLeft().startsWith('#')) {
          j++;
          continue;
        }
        if (l.length - l.trimLeft().length <= indent) break;
        children.add(l);
        j++;
      }
      out[name] = _spec(value, children, [
        for (var k = i; k < j; k++) _lines[k],
      ]);
      i = j;
    }
    return out;
  }

  /// Removes [name] from [section], outside the managed block — for when
  /// the tool takes over an entry it was asked to replace.
  void removeUnmanaged(String section, String name) {
    if (_find(section) == null) return;
    if (!unmanaged(section).containsKey(name)) return;
    _removeEntry(section, name);
  }

  /// Removes [name] where a person wrote it in [section]: never from a
  /// tool's block.
  void _removeEntry(String section, String name) {
    final s = _find(section)!;
    final blocks = _blocks(s);
    final key = _entryKey(s.childIndent);
    for (var i = s.start + 1; i < s.end; i++) {
      if (blocks.any((b) => i >= b.start && i <= b.end)) continue;
      final m = key.firstMatch(_lines[i]);
      if (m == null || (m[1] ?? m[2] ?? m[3]) != name) continue;
      var j = i + 1;
      while (j < s.end) {
        final l = _lines[j];
        if (l.trim().isNotEmpty &&
            l.length - l.trimLeft().length <= s.childIndent) {
          break;
        }
        if (l.trim().isEmpty) {
          // Keep a blank line that separates it from what follows.
          final next = j + 1 < s.end ? _lines[j + 1] : '';
          if (next.trim().isNotEmpty &&
              next.length - next.trimLeft().length <= s.childIndent) {
            break;
          }
        }
        j++;
      }
      _remove(i, j);
      return;
    }
  }

  void _trimBlankRun(int at) {
    if (at >= _lines.length) {
      // The section was last: drop the blank lines that led to it.
      while (_lines.isNotEmpty && _lines.last.trim().isEmpty) {
        _remove(_lines.length - 1, _lines.length);
      }
      return;
    }
    // Collapse the run of blank lines left at [at] to one.
    while (at > 0 &&
        at < _lines.length &&
        _lines[at].trim().isEmpty &&
        _lines[at - 1].trim().isEmpty) {
      _remove(at, at + 1);
    }
  }
}

final class _Section {
  const _Section(this.start, this.end, this.childIndent);

  /// The header line.
  final int start;

  /// The first line after the section.
  final int end;
  final int childIndent;
}

final class _Block {
  const _Block(this.start, this.end, this.owner);

  /// The start marker's line.
  final int start;

  /// The end marker's line.
  final int end;

  /// The tool the markers name.
  final String owner;
}

DependencySpec _spec(String value, List<String> children, List<String> raw) {
  if (children.isEmpty) {
    if (value.isEmpty) return OtherDependency(raw.join('\n'));
    final flow = _flowPath(value);
    if (flow != null) return PathDependency(_unquote(flow));
    if (value.startsWith('{')) return OtherDependency(raw.join('\n'));
    return HostedDependency(_unquote(value));
  }
  final fields = <String, String>{};
  for (final c in children) {
    final m = RegExp(r'^\s*([A-Za-z_]+)\s*:(.*)$').firstMatch(c);
    if (m == null) return OtherDependency(raw.join('\n'));
    fields[m[1]!] = _unquote(_stripComment(m[2]!).trim());
  }
  if (fields.length == 1 && fields.containsKey('path')) {
    return PathDependency(fields['path']!);
  }
  if (fields.keys.toSet().difference({'hosted', 'version'}).isEmpty &&
      fields.containsKey('version') &&
      !(fields['hosted'] ?? '').startsWith('{')) {
    return HostedDependency(
      fields['version']!,
      url: fields['hosted']?.isEmpty ?? true ? null : fields['hosted'],
    );
  }
  return OtherDependency(raw.join('\n'));
}

/// The path of `{path: <path>}`, or null for any other value. Read in one
/// pass, so a long line costs its length, never its square.
String? _flowPath(String value) {
  if (!value.startsWith('{') || !value.endsWith('}')) return null;
  final inner = value.substring(1, value.length - 1).trimLeft();
  if (!inner.startsWith('path')) return null;
  final rest = inner.substring('path'.length).trimLeft();
  if (!rest.startsWith(':')) return null;
  final path = rest.substring(1).trim();
  if (path.isEmpty ||
      path.contains(',') ||
      path.contains('{') ||
      path.contains('}')) {
    return null;
  }
  return path;
}

String _stripComment(String value) {
  // A " #" starts a comment outside quotes.
  var quote = '';
  for (var i = 0; i < value.length; i++) {
    final ch = value[i];
    if (quote.isNotEmpty) {
      if (ch == quote) quote = '';
    } else if (ch == "'" || ch == '"') {
      quote = ch;
    } else if (ch == '#' && (i == 0 || value[i - 1] == ' ')) {
      return value.substring(0, i);
    }
  }
  return value;
}

String _unquote(String value) {
  final v = value.trim();
  if (v.length >= 2 &&
      ((v.startsWith("'") && v.endsWith("'")) ||
          (v.startsWith('"') && v.endsWith('"')))) {
    return v.substring(1, v.length - 1);
  }
  return v;
}

/// [value] written so YAML reads it back as the same string: plain when it
/// can be, else single-quoted.
String _scalar(String value) =>
    RegExp(r'^[A-Za-z0-9_./^+-]+$').hasMatch(value) && !_notString(value)
    ? value
    : "'${value.replaceAll("'", "''")}'";

/// Whether YAML reads plain [value] as something other than a string: a
/// null, a boolean (YAML 1.1's yes/no/on/off included) or a number.
bool _notString(String value) =>
    const {
      'null', '~', 'true', 'false', 'yes', 'no', 'on', 'off', 'y', 'n', //
    }.contains(value.toLowerCase()) ||
    RegExp(
      r'^[-+]?(?:\d[\d_]*(?:\.\d*)?(?:e[-+]?\d+)?|\.\d+(?:e[-+]?\d+)?'
      r'|0x[0-9a-f_]+|0o[0-7_]+|\.(?:inf|nan))$',
      caseSensitive: false,
    ).hasMatch(value);

String _normalPath(String path) {
  var p = path.replaceAll(r'\', '/');
  while (p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  if (p.startsWith('./')) p = p.substring(2);
  return p;
}

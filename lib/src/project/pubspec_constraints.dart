/// Changing the version constraints a person wrote in a pubspec.
library;

/// Edits the constraint of an entry written on one line — `  name: ^1.2.3`
/// — in a top-level section, leaving every other byte as it was: comments,
/// order, line endings, the section's indent. Entries written as blocks or
/// flow collections (`path:`, `git:`, `{path: ..}`) and entries inside a
/// tool's managed block are left alone.
abstract final class PubspecConstraints {
  /// The one-line constraint of [name] in [section], or null when it has
  /// none (absent, a block, a flow collection, or in a managed block).
  static String? of(String text, String section, String name) =>
      _find(text, section, name)?.constraint;

  /// [text] with [name]'s constraint in [section] set to [constraint]; the
  /// text unchanged when the entry isn't a one-line constraint.
  ///
  /// The constraint keeps the entry's quotes; an unquoted entry is quoted
  /// when the new constraint needs it (`>=1.0.0 <2.0.0`).
  static String set(
    String text,
    String section,
    String name,
    String constraint,
  ) {
    final found = _find(text, section, name);
    if (found == null) return text;
    final String value;
    if (found.quote == '"') {
      value = '"${constraint.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
    } else if (found.quote == "'" || !_plain.hasMatch(constraint)) {
      value = "'${constraint.replaceAll("'", "''")}'";
    } else {
      value = constraint;
    }
    return text.replaceRange(found.start, found.end, value);
  }

  /// [text] with [name] in [section] at [constraint], on one line as a
  /// person writes it — so [set] (and `just upgrade`) can move it later.
  ///
  /// When [name] is there already on one line, its constraint is [set];
  /// when it is there in another form (a block, a tool's managed block),
  /// the text comes back unchanged. Otherwise the entry goes after the
  /// section's last entry, at its indent, or in a new section at the end of
  /// the file. Line endings stay as the file has them.
  static String add(
    String text,
    String section,
    String name,
    String constraint,
  ) {
    if (of(text, section, name) != null) {
      return set(text, section, name, constraint);
    }
    final crlf = text.contains('\r\n');
    final nl = crlf ? '\r\n' : '\n';
    final value = _plain.hasMatch(constraint)
        ? constraint
        : "'${constraint.replaceAll("'", "''")}'";
    final entry = '$name: $value';
    final header = RegExp(
      '^(?:${RegExp.escape(section)}|"${RegExp.escape(section)}"|'
      "'${RegExp.escape(section)}')"
      r'\s*:\s*(#.*)?$',
    );
    // An entry's key, at the section's own indent: a key nested deeper
    // (`path:` under a git dependency) is not an entry.
    final key = RegExp(
      '^(?:${RegExp.escape(name)}|"${RegExp.escape(name)}"|'
      "'${RegExp.escape(name)}')"
      r'\s*:',
    );
    final lines = text.split('\n');
    final at = lines.indexWhere((l) => header.hasMatch(l.trimRight()));
    if (at < 0) {
      final lead = text.isEmpty || text.endsWith('\n') ? '' : nl;
      return '$text$lead${text.isEmpty ? '' : nl}$section:$nl  $entry$nl';
    }
    var last = at;
    String? indent;
    for (var i = at + 1; i < lines.length; i++) {
      final line = lines[i].trimRight();
      if (line.isEmpty) continue;
      if (!line.startsWith(' ')) {
        if (line.startsWith('#')) continue;
        break;
      }
      final trimmed = line.trimLeft();
      final pad = line.substring(0, line.length - trimmed.length);
      if (!trimmed.startsWith('#')) {
        indent ??= pad;
        if (pad == indent && key.hasMatch(trimmed)) return text;
      }
      last = i;
    }
    final row = '${indent ?? '  '}$entry';
    if (last == lines.length - 1) {
      // The section ends the file, without a final line break.
      lines
        ..[last] = '${lines[last]}${crlf ? '\r' : ''}'
        ..add(row);
    } else {
      lines.insert(last + 1, '$row${crlf ? '\r' : ''}');
    }
    return lines.join('\n');
  }

  /// A constraint YAML reads as a string as it stands: `any`, `1.2.3`,
  /// `^1.2.3`.
  static final RegExp _plain = RegExp(r'^\^?[0-9A-Za-z][0-9A-Za-z.+-]*$');

  static final RegExp _blockStart = RegExp(r'^\s*# >>> \S+ managed\b');
  static final RegExp _blockEnd = RegExp(r'^\s*# <<< \S+ managed <<<');

  /// Where [name]'s constraint in [section] is in [text] (its quotes
  /// included), its quote, and the constraint.
  static _Found? _find(String text, String section, String name) {
    final header = RegExp(
      '^(?:${RegExp.escape(section)}|"${RegExp.escape(section)}"|'
      "'${RegExp.escape(section)}')"
      r'\s*:\s*(#.*)?$',
    );
    final key = RegExp(
      '^(?:${RegExp.escape(name)}|"${RegExp.escape(name)}"|'
      "'${RegExp.escape(name)}')"
      r'\s*:',
    );
    var inside = false;
    var inBlock = false;
    int? indent;
    var start = 0;
    while (start < text.length) {
      var end = text.indexOf('\n', start);
      if (end < 0) end = text.length;
      var lineEnd = end;
      if (lineEnd > start && text[lineEnd - 1] == '\r') lineEnd--;
      final line = text.substring(start, lineEnd);
      final lineStart = start;
      start = end + 1;
      final trimmed = line.trimLeft();
      if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('#')) {
        inside = header.hasMatch(line.trimRight());
        inBlock = false;
        indent = null;
        continue;
      }
      if (!inside || trimmed.isEmpty) continue;
      if (trimmed.startsWith('#')) {
        if (_blockStart.hasMatch(line)) inBlock = true;
        if (_blockEnd.hasMatch(line)) inBlock = false;
        continue;
      }
      final pad = line.length - trimmed.length;
      indent ??= pad;
      if (inBlock || pad != indent || !line.startsWith(' ' * pad)) continue;
      final m = key.firstMatch(trimmed);
      if (m == null) continue;
      final found = _value(line, pad + m.end);
      if (found == null) return null;
      final (from, to, quote, constraint) = found;
      return _Found(lineStart + from, lineStart + to, quote, constraint);
    }
    return null;
  }

  /// The one-line value in [line] after [at] (just past the `:`): its
  /// start and end (quotes included), its quote and its text. Null when it
  /// isn't a one-line scalar.
  static (int, int, String, String)? _value(String line, int at) {
    var i = at;
    while (i < line.length && (line[i] == ' ' || line[i] == '\t')) {
      i++;
    }
    if (i >= line.length) return null; // A block follows.
    final first = line[i];
    if (first == '"' || first == "'") {
      final close = line.indexOf(first, i + 1);
      if (close < 0) return null;
      final rest = line.substring(close + 1);
      if (!RegExp(r'^\s*(#.*)?$').hasMatch(rest)) return null;
      final inner = line.substring(i + 1, close);
      if (inner.trim().isEmpty) return null;
      return (i, close + 1, first, inner);
    }
    // Flow collections, comments, anchors, aliases, tags and block
    // scalars are not constraints.
    if ('{[#&*!|>%@`'.contains(first)) return null;
    var end = line.length;
    final comment = line.indexOf(' #', i);
    if (comment >= 0) end = comment;
    while (end > i && (line[end - 1] == ' ' || line[end - 1] == '\t')) {
      end--;
    }
    if (end <= i) return null;
    return (i, end, '', line.substring(i, end));
  }
}

final class _Found {
  const _Found(this.start, this.end, this.quote, this.constraint);

  /// Where the value (with its quotes) starts and ends in the text.
  final int start, end;

  /// `'`, `"` or nothing.
  final String quote;

  /// The constraint, without quotes.
  final String constraint;
}

/// The rules a path from an archive must pass before anything is written.
library;

/// A path in an archive or a package that is not safe to write.
final class UnsafePathException implements Exception {
  /// [path] broke a rule, explained by [reason].
  const UnsafePathException(this.path, this.reason);

  /// The offending path, as the archive wrote it.
  final String path;

  /// Why it was refused, in a sentence.
  final String reason;

  @override
  String toString() => 'Unsafe path "${_printable(path)}": $reason';
}

/// Checks paths from untrusted archives so they can only ever land inside
/// the folder they are extracted to, on every desktop platform.
///
/// A safe path is relative, uses `/` between parts, and each part is a
/// plain name: not `.` or `..`, no characters Windows forbids, not a name
/// Windows reserves (`CON`, `NUL`, `COM1`…), and not ending in a dot or a
/// space, which Windows would silently drop. It holds no control
/// characters (C0 or C1) and no invisible ones — zero-width spaces,
/// direction overrides, line separators, byte-order marks — that would
/// let a name pass for another when printed.
abstract final class SafePaths {
  /// The longest path accepted, in characters. Windows' classic limit is
  /// 260 for the whole path; this leaves room for the project folder and
  /// `packages/<category>/<name>/` (or `plugins/…`) in front of it.
  static const int maxLength = 180;

  /// [path] if it is safe, else throws [UnsafePathException].
  ///
  /// A trailing `/` marks a folder and is kept.
  static String check(String path) {
    if (path.isEmpty) throw UnsafePathException(path, 'it is empty.');
    if (path.length > maxLength) {
      throw UnsafePathException(
        path,
        'it is longer than $maxLength characters.',
      );
    }
    for (final unit in path.codeUnits) {
      if (unit < 0x20 || (unit >= 0x7F && unit <= 0x9F)) {
        throw UnsafePathException(path, 'it contains a control character.');
      }
      if (_isInvisible(unit)) {
        throw UnsafePathException(
          path,
          'it contains an invisible character '
          '(U+${unit.toRadixString(16).toUpperCase().padLeft(4, '0')}).',
        );
      }
    }
    if (path.contains(r'\')) {
      throw UnsafePathException(path, r'it uses "\" between folders.');
    }
    if (path.startsWith('/')) {
      throw UnsafePathException(path, 'it is absolute.');
    }
    final body = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    if (body.isEmpty) throw UnsafePathException(path, 'it has no name.');
    for (final part in body.split('/')) {
      _checkPart(path, part);
    }
    return path;
  }

  /// Whether [path] passes [check].
  static bool isSafe(String path) {
    try {
      check(path);
      return true;
    } on UnsafePathException {
      return false;
    }
  }

  /// The key two paths share when a case-insensitive or Unicode-normalising
  /// file system (Windows, macOS) could see them as the same file.
  ///
  /// Deliberately broad: besides case, accents are dropped — combining
  /// marks, and the accented Latin letters that decompose into a letter
  /// and a mark — so `café` written either way, and plain `cafe`, all
  /// share a key.
  static String caseKey(String path) {
    final out = StringBuffer();
    for (final rune in path.toLowerCase().runes) {
      if (rune >= 0x300 && rune <= 0x36F) continue;
      out.writeCharCode(_baseLetters[rune] ?? rune);
    }
    return out.toString();
  }

  static bool _isInvisible(int unit) =>
      (unit >= 0x200B && unit <= 0x200F) ||
      (unit >= 0x2028 && unit <= 0x202E) ||
      (unit >= 0x2066 && unit <= 0x2069) ||
      unit == 0xFEFF;

  static void _checkPart(String path, String part) {
    if (part.isEmpty) {
      throw UnsafePathException(path, 'it has an empty folder name ("//").');
    }
    if (part == '.' || part == '..') {
      throw UnsafePathException(path, 'it contains "$part".');
    }
    for (final char in const ['<', '>', ':', '"', '|', '?', '*']) {
      if (part.contains(char)) {
        throw UnsafePathException(
          path,
          'it contains "$char", which Windows does not allow.',
        );
      }
    }
    if (part.endsWith('.') || part.endsWith(' ')) {
      throw UnsafePathException(
        path,
        '"$part" ends in a dot or a space, which Windows drops.',
      );
    }
    final stem = part.split('.').first.toUpperCase().trimRight();
    if (_reserved.contains(stem)) {
      throw UnsafePathException(
        path,
        '"$part" is a name Windows reserves for a device.',
      );
    }
  }

  static final Set<String> _reserved = {
    'CON', 'PRN', 'AUX', 'NUL', //
    for (var i = 1; i <= 9; i++) ...['COM$i', 'LPT$i'],
    'COM¹', 'COM²', 'COM³', 'LPT¹', 'LPT²', 'LPT³',
  };

  /// Lower-case Latin-1 Supplement and Latin Extended-A letters that
  /// decompose (NFD) into a base letter and a combining mark, by that base
  /// letter.
  static final Map<int, int> _baseLetters = {
    for (final (base, letters) in const [
      ('a', 'àáâãäåāăą'),
      ('c', 'çćĉċč'),
      ('d', 'ď'),
      ('e', 'èéêëēĕėęě'),
      ('g', 'ĝğġģ'),
      ('h', 'ĥ'),
      ('i', 'ìíîïĩīĭį'),
      ('j', 'ĵ'),
      ('k', 'ķ'),
      ('l', 'ĺļľ'),
      ('n', 'ñńņň'),
      ('o', 'òóôõöōŏő'),
      ('r', 'ŕŗř'),
      ('s', 'śŝşš'),
      ('t', 'ţť'),
      ('u', 'ùúûüũūŭůűų'),
      ('w', 'ŵ'),
      ('y', 'ýÿŷ'),
      ('z', 'źżž'),
    ])
      for (final unit in letters.codeUnits) unit: base.codeUnitAt(0),
  };
}

/// [path] with every character [SafePaths.check] refuses as control or
/// invisible written as an escape, so printing it can't fool a terminal.
String _printable(String path) {
  final out = StringBuffer();
  for (final unit in path.codeUnits) {
    if (unit < 0x20 || (unit >= 0x7F && unit <= 0x9F)) {
      out.write(
        r'\x'
        '${unit.toRadixString(16).padLeft(2, '0')}',
      );
    } else if (SafePaths._isInvisible(unit)) {
      out.write(
        r'\u'
        '${unit.toRadixString(16).padLeft(4, '0')}',
      );
    } else {
      out.writeCharCode(unit);
    }
  }
  return out.toString();
}

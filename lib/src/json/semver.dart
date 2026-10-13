/// Semantic versions and the constraints pub writes, so a tool can check
/// what pub's overrides let through unchecked.
library;

/// A semantic version (semver 2.0): `1.2.3`, `1.2.3-dev.4`, `1.2.3+5`.
final class Version implements Comparable<Version> {
  Version._(this.major, this.minor, this.patch, this._pre, this._build);

  /// `major.minor.patch` with no pre-release or build part.
  factory Version(int major, int minor, int patch) {
    if (major < 0 || minor < 0 || patch < 0) {
      throw ArgumentError('Version parts must not be negative.');
    }
    return Version._(major, minor, patch, const [], const []);
  }

  /// Reads [text]. Throws [FormatException] if it is not a version.
  factory Version.parse(String text) {
    final match = _versionPattern.firstMatch(text.trim());
    if (match == null) {
      throw FormatException('"$text" is not a version like 1.2.3.');
    }
    int number(String s) {
      if (s.length > 1 && s.startsWith('0')) {
        throw FormatException('"$text" has a leading zero.');
      }
      return int.parse(s);
    }

    return Version._(
      number(match[1]!),
      number(match[2]!),
      number(match[3]!),
      _identifiers(match[5]),
      _identifiers(match[8]),
    );
  }

  /// [text] as a version, or null.
  static Version? tryParse(String text) {
    try {
      return Version.parse(text);
    } on FormatException {
      return null;
    }
  }

  /// The parts of the version number.
  final int major, minor, patch;

  final List<Object> _pre;
  final List<Object> _build;

  /// Whether this is a pre-release, like `2.0.0-dev.1`.
  bool get isPreRelease => _pre.isNotEmpty;

  /// The first version a `^` constraint on this one excludes: the next
  /// major version, or the next minor one before 1.0.0 — as pub does.
  Version get nextBreaking =>
      major > 0 ? Version(major + 1, 0, 0) : Version(0, minor + 1, 0);

  /// This version without its pre-release and build parts.
  Version get release => Version(major, minor, patch);

  @override
  int compareTo(Version other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    // A release outranks its pre-releases.
    if (_pre.isEmpty != other._pre.isEmpty) return _pre.isEmpty ? 1 : -1;
    final pre = _compareIdentifiers(_pre, other._pre);
    if (pre != 0) return pre;
    // Build metadata does not affect precedence; it only breaks ties so the
    // order is total.
    return _compareIdentifiers(_build, other._build);
  }

  /// Whether this comes before [other].
  bool operator <(Version other) => compareTo(other) < 0;

  /// Whether this comes after [other].
  bool operator >(Version other) => compareTo(other) > 0;

  /// Whether this comes before [other] or is it.
  bool operator <=(Version other) => compareTo(other) <= 0;

  /// Whether this comes after [other] or is it.
  bool operator >=(Version other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) => other is Version && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(
    major,
    minor,
    patch,
    Object.hashAll(_pre),
    Object.hashAll(_build),
  );

  @override
  String toString() {
    final out = StringBuffer('$major.$minor.$patch');
    if (_pre.isNotEmpty) out.write('-${_pre.join('.')}');
    if (_build.isNotEmpty) out.write('+${_build.join('.')}');
    return out.toString();
  }

  static final RegExp _versionPattern = RegExp(
    r'^(\d+)\.(\d+)\.(\d+)'
    r'(-([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?'
    r'(\+([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$',
  );

  static List<Object> _identifiers(String? text) {
    if (text == null) return const [];
    return [
      // A number too long for an int stays text, as pub_semver keeps it.
      for (final part in text.split('.'))
        RegExp(r'^\d+$').hasMatch(part) ? (_exactInt(part) ?? part) : part,
    ];
  }

  /// [digits] as an int, when an int holds it exactly: on the web, where an
  /// int is a double, a number past 2^53 would come back rounded instead
  /// of failing, so it stays text there as it does on the VM past 2^63.
  static int? _exactInt(String digits) {
    final n = int.tryParse(digits);
    if (n == null) return null;
    final plain = digits.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    return '$n' == plain ? n : null;
  }

  static int _compareIdentifiers(List<Object> a, List<Object> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x is int && y is int) {
        if (x != y) return x.compareTo(y);
      } else if (x is int) {
        return -1; // numeric identifiers sort first
      } else if (y is int) {
        return 1;
      } else {
        final c = (x as String).compareTo(y as String);
        if (c != 0) return c;
      }
    }
    return a.length.compareTo(b.length);
  }
}

/// Which versions are acceptable, written the way pubspecs write it:
/// `any`, `1.2.3`, `^1.2.3`, `>=1.0.0 <2.0.0`.
final class VersionConstraint {
  const VersionConstraint._(
    this._text, {
    this.min,
    this.max,
    this.includeMin = false,
    this.includeMax = false,
  });

  /// Every version.
  static const VersionConstraint any = VersionConstraint._('any');

  /// Exactly [version].
  factory VersionConstraint.exactly(Version version) => VersionConstraint._(
    '$version',
    min: version,
    max: version,
    includeMin: true,
    includeMax: true,
  );

  /// `^version`: [version] up to, not including, its next breaking one.
  factory VersionConstraint.compatibleWith(Version version) =>
      VersionConstraint._(
        '^$version',
        min: version,
        max: version.nextBreaking,
        includeMin: true,
      );

  /// Reads [text]. Throws [FormatException] if it is not a constraint.
  factory VersionConstraint.parse(String text) {
    final trimmed = text.trim();
    if (trimmed == 'any') return any;
    if (trimmed.startsWith('^')) {
      return VersionConstraint.compatibleWith(
        Version.parse(trimmed.substring(1)),
      );
    }
    if (!trimmed.startsWith(RegExp('[<>]'))) {
      return VersionConstraint.exactly(Version.parse(trimmed));
    }
    Version? min, max;
    var includeMin = false, includeMax = false;
    final pattern = RegExp(r'\s*(>=|<=|>|<)\s*([^\s<>]+)');
    var at = 0;
    while (at < trimmed.length) {
      final m = pattern.matchAsPrefix(trimmed, at);
      if (m == null) {
        throw FormatException('"$text" is not a version constraint.');
      }
      final op = m[1]!;
      final version = Version.parse(m[2]!);
      at = m.end;
      if (op.startsWith('>')) {
        if (min != null) {
          throw FormatException('"$text" has two lower bounds.');
        }
        min = version;
        includeMin = op == '>=';
      } else {
        if (max != null) {
          throw FormatException('"$text" has two upper bounds.');
        }
        max = version;
        includeMax = op == '<=';
      }
    }
    if (min != null &&
        max != null &&
        (min > max || (min == max && !(includeMin && includeMax)))) {
      throw FormatException('"$text" allows no version.');
    }
    return VersionConstraint._(
      trimmed,
      min: min,
      max: max,
      includeMin: includeMin,
      includeMax: includeMax,
    );
  }

  /// [text] as a constraint, or null.
  static VersionConstraint? tryParse(String text) {
    try {
      return VersionConstraint.parse(text);
    } on FormatException {
      return null;
    }
  }

  /// The lowest version allowed, or null for no lower bound.
  final Version? min;

  /// The highest version allowed, or null for no upper bound.
  final Version? max;

  /// Whether [min] itself is allowed.
  final bool includeMin;

  /// Whether [max] itself is allowed.
  final bool includeMax;

  final String _text;

  /// Whether this allows every version.
  bool get isAny => min == null && max == null;

  /// Whether [version] satisfies this constraint.
  ///
  /// As in pub, an exclusive upper bound also excludes that version's
  /// pre-releases — `<2.0.0` does not allow `2.0.0-dev` — unless the lower
  /// bound is itself one of them, or the bound has build metadata.
  bool allows(Version version) {
    final lo = min;
    if (lo != null) {
      final c = version.compareTo(lo);
      if (c < 0 || (c == 0 && !includeMin)) return false;
    }
    final hi = max;
    if (hi != null) {
      final c = version.compareTo(hi);
      if (c > 0 || (c == 0 && !includeMax)) return false;
      if (!includeMax &&
          version.isPreRelease &&
          !hi.isPreRelease &&
          hi._build.isEmpty &&
          version.release == hi.release &&
          !(lo != null && lo.isPreRelease && lo.release == hi.release)) {
        return false;
      }
    }
    return true;
  }

  /// The highest of [versions] this allows, preferring releases over
  /// pre-releases as pub does; null if it allows none.
  Version? bestOf(Iterable<Version> versions) {
    Version? best;
    Version? bestPre;
    for (final v in versions) {
      if (!allows(v)) continue;
      if (v.isPreRelease) {
        if (bestPre == null || v > bestPre) bestPre = v;
      } else {
        if (best == null || v > best) best = v;
      }
    }
    return best ?? bestPre;
  }

  @override
  bool operator ==(Object other) =>
      other is VersionConstraint &&
      other.min == min &&
      other.max == max &&
      other.includeMin == includeMin &&
      other.includeMax == includeMax;

  @override
  int get hashCode => Object.hash(min, max, includeMin, includeMax);

  @override
  String toString() => _text;
}

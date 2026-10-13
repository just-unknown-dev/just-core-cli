/// Packages released on GitHub: where a repository's release files are.
library;

/// A GitHub repository, as `https://github.com/<owner>/<repo>` names it.
///
/// Its release files are plain downloads from GitHub's CDN —
/// `https://github.com/<owner>/<repo>/releases/download/<tag>/<file>`, or
/// `.../releases/latest/download/<file>` for the newest release — not the
/// GitHub API, which allows only 60 requests an hour without signing in.
/// That is why every package release carries a file with a fixed name,
/// [manifestFile], that says what the release holds.
final class GitHubRepo {
  /// The repository [owner]/[name]: neither empty nor `.` or `..`
  /// (asserted in debug builds). [tryParse] checks text from a person in
  /// full.
  const GitHubRepo(this.owner, this.name)
    : assert(owner.length > 0 && name.length > 0),
      assert(owner != '.' && owner != '..' && name != '.' && name != '..');

  /// The file every release of a package carries, describing it: version,
  /// archive and SHA-256.
  static const String manifestFile = 'just_release.json';

  /// The account or organisation.
  final String owner;

  /// The repository's name.
  final String name;

  /// Reads `https://github.com/<owner>/<repo>` (with or without `.git`, a
  /// trailing `/`, or `www.`), `github.com/<owner>/<repo>`, or
  /// `<owner>/<repo>`. Null for anything else — including any other host.
  static GitHubRepo? tryParse(String text) {
    var t = text.trim();
    var hasHost = false;
    for (final scheme in const ['https://', 'http://']) {
      if (t.toLowerCase().startsWith(scheme)) {
        t = t.substring(scheme.length);
        hasHost = true;
        break;
      }
    }
    if (t.endsWith('/')) t = t.substring(0, t.length - 1);
    if (t.endsWith('.git')) t = t.substring(0, t.length - 4);
    var parts = t.split('/');
    // A host (after a scheme, or anything with a dot where the owner would
    // be) must be GitHub's own.
    if (hasHost || parts.first.contains('.')) {
      final host = parts.first.toLowerCase();
      if (host != 'github.com' && host != 'www.github.com') return null;
      parts = parts.sublist(1);
    }
    if (parts.length != 2) return null;
    // GitHub's own rules: an owner is letters, digits and hyphens; a
    // repository may also hold dots and underscores.
    if (!RegExp(r'^[A-Za-z0-9-]{1,39}$').hasMatch(parts[0])) return null;
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,100}$').hasMatch(parts[1])) return null;
    if (parts[1] == '.' || parts[1] == '..') return null;
    return GitHubRepo(parts[0], parts[1]);
  }

  /// The repository's page.
  Uri get url => Uri.https('github.com', '/$owner/$name');

  /// The release file [file] of [tag], or of the newest release when [tag]
  /// is null.
  ///
  /// Throws [ArgumentError] unless both are plain names — letters, digits,
  /// `.`, `_`, `+` and `-`, not `.` or `..` — so neither can lead out of
  /// this repository's releases.
  Uri releaseFile(String file, {String? tag}) {
    _checkName(file, 'file');
    if (tag == null) {
      return Uri.https(
        'github.com',
        '/$owner/$name/releases/latest/download/$file',
      );
    }
    _checkName(tag, 'tag');
    return Uri.https(
      'github.com',
      '/$owner/$name/releases/download/$tag/$file',
    );
  }

  /// The [manifestFile] of [tag], or of the newest release.
  ///
  /// Throws [ArgumentError] when [tag] is not a plain name (see
  /// [releaseFile]).
  Uri manifest({String? tag}) => releaseFile(manifestFile, tag: tag);

  static void _checkName(String value, String name) {
    if (value == '.' || value == '..' || !_plainName.hasMatch(value)) {
      throw ArgumentError.value(
        value,
        name,
        'Must be letters, digits, ".", "_", "+" or "-".',
      );
    }
  }

  static final RegExp _plainName = RegExp(r'^[A-Za-z0-9._+-]+$');

  @override
  bool operator ==(Object other) =>
      other is GitHubRepo &&
      other.owner.toLowerCase() == owner.toLowerCase() &&
      other.name.toLowerCase() == name.toLowerCase();

  @override
  int get hashCode => Object.hash(owner.toLowerCase(), name.toLowerCase());

  @override
  String toString() => '$owner/$name';
}

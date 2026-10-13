/// The naming rules shared by catalogs, manifests and generated code.
library;

/// Rules for package names (pub's) and the names written into generated code.
abstract final class PackageNames {
  /// The longest item id accepted.
  static const int maxIdLength = 64;

  /// Why [id] can't be a Dart package name (and so a package's id), or
  /// null if it can.
  ///
  /// Ids are lowercase letters, digits and underscores, start with a
  /// letter, and are not Dart reserved words — pub's rules for package
  /// names.
  static String? idProblem(String id) {
    if (id.isEmpty) return 'It is empty.';
    if (id.length > maxIdLength) {
      return 'It is longer than $maxIdLength characters.';
    }
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(id)) {
      return 'Use lowercase letters, digits and underscores, starting with a '
          'letter.';
    }
    if (_reservedWords.contains(id)) return '"$id" is a Dart reserved word.';
    return null;
  }

  /// Whether [id] is a valid package name.
  static bool isId(String id) => idProblem(id) == null;

  /// Whether [text] is a Dart name, optionally dotted (`MyPlugin` or
  /// `MyPlugin.extension`), and nothing else — so it can be written
  /// into generated code without letting anything else in.
  static bool isDottedIdentifier(String text) =>
      RegExp(r'^[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*)*$').hasMatch(text) &&
      !text.split('.').any(_reservedWords.contains);

  /// Whether [text] is a category id: lowercase words joined by `-`.
  static bool isCategory(String text) =>
      RegExp(r'^[a-z][a-z0-9]*(-[a-z0-9]+)*$').hasMatch(text) &&
      text.length <= 40;

  static const Set<String> _reservedWords = {
    'assert', 'break', 'case', 'catch', 'class', 'const', 'continue', //
    'default', 'do', 'else', 'enum', 'extends', 'false', 'final',
    'finally', 'for', 'if', 'in', 'is', 'new', 'null', 'rethrow',
    'return', 'super', 'switch', 'this', 'throw', 'true', 'try', 'var',
    'void', 'while', 'with',
  };
}

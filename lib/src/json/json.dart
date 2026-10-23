/// Strict reading and canonical writing of the ecosystem's JSON files.
library;

import 'dart:convert';

import 'semver.dart';

/// A JSON file that is not valid: wrong JSON shape, a missing field, a value
/// out of range.
final class JsonFormatException implements Exception {
  /// [message] about the value at [where] (like `items[2].versions[0]`) in
  /// [file].
  const JsonFormatException(this.message, {this.where = '', this.file});

  /// What is wrong, in a sentence.
  final String message;

  /// The JSON path to the value, empty for the whole file.
  final String where;

  /// The file, when known.
  final String? file;

  /// This error, placed in [file].
  JsonFormatException inFile(String file) =>
      JsonFormatException(message, where: where, file: file);

  @override
  String toString() {
    final at = [if (file != null) file, if (where.isNotEmpty) where].join(': ');
    return at.isEmpty ? message : '$at: $message';
  }
}

/// A JSON object read field by field, each read naming its path when it
/// fails. Unknown fields are ignored, so newer files still read.
final class JsonFields {
  /// [value], which must be a JSON object, found at [where].
  JsonFields(Object? value, [this.where = ''])
    : _map = value is Map
          ? value.cast<String, Object?>()
          : throw JsonFormatException('Expected an object.', where: where);

  /// [text] parsed as a JSON object.
  factory JsonFields.parse(String text) {
    final Object? value;
    try {
      value = jsonDecode(text);
    } on FormatException catch (e) {
      throw JsonFormatException('It is not valid JSON: ${e.message}');
    }
    return JsonFields(value);
  }

  final Map<String, Object?> _map;

  /// Where this object sits in its file.
  final String where;

  /// Whether [key] is present (even if null).
  bool has(String key) => _map.containsKey(key);

  /// The object's keys, in file order.
  Iterable<String> get keys => _map.keys;

  /// The raw value at [key].
  Object? raw(String key) => _map[key];

  String _at(String key) => where.isEmpty ? key : '$where.$key';

  /// A [JsonFormatException] about [key].
  JsonFormatException error(String key, String message) =>
      JsonFormatException(message, where: _at(key));

  /// The non-empty string at [key].
  String string(String key) {
    final v = _map[key];
    if (v is String && v.isNotEmpty) return v;
    throw error(key, v == null ? 'Missing.' : 'Expected a non-empty string.');
  }

  /// The string at [key], or null when absent.
  String? optString(String key) {
    final v = _map[key];
    if (v == null) return null;
    if (v is String) return v;
    throw error(key, 'Expected a string.');
  }

  /// The integer at [key], at least [min].
  ///
  /// On the web (JavaScript), where every number is a double, `1.0` and
  /// `1e3` in the JSON read as the integers 1 and 1000: once the text is
  /// parsed, nothing tells them from `1` and `1000`.
  int integer(String key, {int min = 0}) {
    final v = _map[key];
    if (v is int && v >= min) return v;
    throw error(
      key,
      v == null ? 'Missing.' : 'Expected a whole number of at least $min.',
    );
  }

  /// The integer at [key] (at least [min]), or null when absent.
  int? optInt(String key, {int min = 0}) =>
      _map[key] == null ? null : integer(key, min: min);

  /// The number at [key], or null when absent.
  num? optNum(String key) {
    final v = _map[key];
    if (v == null || v is num) return v as num?;
    throw error(key, 'Expected a number.');
  }

  /// The boolean at [key], or [fallback] when absent.
  bool flag(String key, {bool fallback = false}) {
    final v = _map[key];
    if (v == null) return fallback;
    if (v is bool) return v;
    throw error(key, 'Expected true or false.');
  }

  /// The object at [key].
  JsonFields object(String key) {
    final v = _map[key];
    if (v == null) throw error(key, 'Missing.');
    return JsonFields(v, _at(key));
  }

  /// The object at [key], or null when absent.
  JsonFields? optObject(String key) => _map[key] == null ? null : object(key);

  /// The objects in the list at [key]; empty when absent.
  List<JsonFields> objects(String key) {
    final v = _map[key];
    if (v == null) return const [];
    if (v is! List) throw error(key, 'Expected a list.');
    return [
      for (var i = 0; i < v.length; i++) JsonFields(v[i], '${_at(key)}[$i]'),
    ];
  }

  /// The strings in the list at [key]; empty when absent.
  List<String> strings(String key) {
    final v = _map[key];
    if (v == null) return const [];
    if (v is! List) throw error(key, 'Expected a list.');
    return [
      for (var i = 0; i < v.length; i++)
        v[i] is String
            ? v[i] as String
            : throw JsonFormatException(
                'Expected a string.',
                where: '${_at(key)}[$i]',
              ),
    ];
  }

  /// The string-to-string map at [key]; empty when absent.
  Map<String, String> stringMap(String key) {
    final v = _map[key];
    if (v == null) return const {};
    if (v is! Map) throw error(key, 'Expected an object.');
    return {
      for (final e in v.entries)
        '${e.key}': e.value is String
            ? e.value as String
            : throw JsonFormatException(
                'Expected a string.',
                where: '${_at(key)}.${e.key}',
              ),
    };
  }

  /// The map of package names to version constraints at [key].
  Map<String, VersionConstraint> constraints(String key) {
    return {
      for (final e in stringMap(key).entries)
        e.key:
            VersionConstraint.tryParse(e.value) ??
            (throw JsonFormatException(
              '"${e.value}" is not a version constraint.',
              where: '${_at(key)}.${e.key}',
            )),
    };
  }

  /// The version at [key].
  Version version(String key) {
    final text = string(key);
    return Version.tryParse(text) ??
        (throw error(key, '"$text" is not a version like 1.2.3.'));
  }

  /// One of [values] (keyed by their JSON names) at [key], or [fallback]
  /// when absent.
  T choice<T>(String key, Map<String, T> values, {T? fallback}) {
    final v = _map[key];
    if (v == null && fallback != null) return fallback;
    final found = v is String ? values[v] : null;
    if (found != null) return found;
    throw error(key, 'Expected one of: ${values.keys.join(', ')}.');
  }

  /// The time at [key] (ISO 8601), or null when absent.
  DateTime? optTime(String key) {
    final text = optString(key);
    if (text == null) return null;
    return DateTime.tryParse(text) ??
        (throw error(key, '"$text" is not a date like 2026-10-07.'));
  }
}

/// [value] as the ecosystem's tools write every JSON file: keys sorted, two-space
/// indents, LF line endings and a final newline. The same data always
/// gives the same bytes, so files diff cleanly and hash stably.
///
/// Not [pretty]: on one line, for files only programs read (a published
/// catalog's pieces), still with keys sorted and a final newline.
String canonicalJson(Object? value, {bool pretty = true}) => pretty
    ? '${const JsonEncoder.withIndent('  ').convert(_sorted(value))}\n'
    : '${jsonEncode(_sorted(value))}\n';

Object? _sorted(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    return {for (final k in keys) k: _sorted(value[k])};
  }
  if (value is List) return [for (final v in value) _sorted(v)];
  return value;
}

/// Drops null values and empty lists or maps from [map], so files only
/// carry what is set.
Map<String, Object?> compactJson(Map<String, Object?> map) => {
  for (final e in map.entries)
    if (e.value != null &&
        !(e.value is List && (e.value as List).isEmpty) &&
        !(e.value is Map && (e.value as Map).isEmpty))
      e.key: e.value,
};

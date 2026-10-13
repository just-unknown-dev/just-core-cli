/// Where the tools keep per-user files on this machine.
library;

import 'dart:io';

/// Per-user folders shared by the `just` tool and what builds on it, outside any
/// project: caches and settings.
///
/// Empty variables count as unset, and so do relative `XDG_*` ones, as the
/// XDG Base Directory specification says.
abstract final class UserPaths {
  /// A cache folder called [name]: `%LOCALAPPDATA%\<name>` on Windows,
  /// `~/Library/Caches/<name>` on macOS, `$XDG_CACHE_HOME/<name>` (or
  /// `~/.cache/<name>`) elsewhere. Null when the home folder can't be found.
  static String? cacheDir(String name, {Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    String? base;
    if (Platform.isWindows) {
      base = _set(env['LOCALAPPDATA']) ?? _set(env['APPDATA']);
    } else if (Platform.isMacOS) {
      final home = _set(env['HOME']);
      base = home == null ? null : '$home/Library/Caches';
    } else {
      final home = _set(env['HOME']);
      base =
          _absolute(env['XDG_CACHE_HOME']) ??
          (home == null ? null : '$home/.cache');
    }
    return base == null ? null : '${_trimmed(base)}/$name';
  }

  /// The `just` tool's settings folder: `%APPDATA%\just_core_cli` on Windows,
  /// `~/Library/Application Support/just_core_cli` on macOS,
  /// `$XDG_CONFIG_HOME/just_core_cli` (or `~/.config/just_core_cli`) elsewhere —
  /// unless `JUST_CORE_CLI_CONFIG_DIR` names one. Null when the home folder
  /// can't be found.
  static String? configDir({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final override = _set(env['JUST_CORE_CLI_CONFIG_DIR']);
    if (override != null) return _trimmed(override);
    String? base;
    if (Platform.isWindows) {
      base = _set(env['APPDATA']) ?? _set(env['LOCALAPPDATA']);
    } else if (Platform.isMacOS) {
      final home = _set(env['HOME']);
      base = home == null ? null : '$home/Library/Application Support';
    } else {
      final home = _set(env['HOME']);
      base =
          _absolute(env['XDG_CONFIG_HOME']) ??
          (home == null ? null : '$home/.config');
    }
    return base == null ? null : '${_trimmed(base)}/just_core_cli';
  }

  /// [value], or null when it is unset or blank.
  static String? _set(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();

  /// [value] when it is an absolute path, else null.
  static String? _absolute(String? value) {
    final v = _set(value);
    return v != null && v.startsWith('/') ? v : null;
  }

  /// [path] with `/` between parts and no trailing `/`.
  static String _trimmed(String path) {
    var p = path.replaceAll(r'\', '/');
    while (p.length > 1 && p.endsWith('/') && !p.endsWith(':/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }
}

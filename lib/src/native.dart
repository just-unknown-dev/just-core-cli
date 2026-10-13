/// The part of `package:just_core_cli/just_core_cli.dart` that needs a real
/// machine — files, processes, a terminal: the `just` tool's entry points
/// and the command framework plugins build on. The library exports it
/// everywhere but the web (Windows, macOS, Linux, Android, iOS: where
/// `dart:io` is); on the web — where `dart.library.js_interop` is, with
/// JavaScript or WebAssembly — it exports `web.dart` instead.
library;

export 'cli/command.dart';
export 'cli/context.dart';
export 'cli/entry.dart' show runJust, runJustPlugin;
export 'cli/launcher.dart';
export 'cli/output.dart';
export 'cli/pinning.dart' show ProjectPin;
export 'cli/plugin_command.dart' show PluginCommand;
export 'cli/plugins.dart';
export 'cli/runner.dart';
export 'cli/trusted_plugins.dart';

/// The core of `just`, the Just ecosystem's command-line tool: the toolkit
/// every platform can use, and — where there is a real machine — the
/// command framework plugins build on.
///
/// **On every platform, the web included (JavaScript and WebAssembly):**
/// - [JsonFields], [PackageNames], [Version] and [VersionConstraint];
///   [Sha256].
/// - [ZipArchive] and [ZipWriter] (with [SafePaths]): ZIP files read and
///   written in memory.
/// - [PubspecEditor], [ManagedBlock] and [PubspecConstraints]: pubspec
///   edits that keep every other byte.
/// - [TemplateRenderer], [ProjectNames] and [GitIgnores]: a new project's
///   files.
/// - [PackageSet], [ToolSet] and [SetPackage]: versions that work together.
/// - [JustProjectFile] (`just.json`), [ProjectPaths], [PluginManifest]
///   (`just_plugin.json`), [Finding], [ExitCodes] and the failures,
///   [CancelToken], [GitHubRepo], [justCoreCliVersion].
///
/// **Where `dart:io` is (Windows, macOS, Linux, Android, iOS)**, the
/// library also exports the command framework: `runJust` and
/// `runJustPlugin`, `JustCommand`, `JustRunner`, `JustContext`, `Output`,
/// `Launcher`, the plugins and their trust rule, `runTrustedPlugin`. A
/// plugin is a package with a `just_plugin.json` that names its commands
/// and hooks, and a `bin/just_plugin.dart` that runs them with
/// `runJustPlugin`.
///
/// The project toolkit on disk — `JustProject`, transactions, pub — is in
/// `package:just_core_cli/project.dart`; downloads in
/// `package:just_core_cli/fetch.dart`. Both need `dart:io`.
library;

export 'src/archive/safe_paths.dart';
export 'src/archive/zip_reader.dart';
export 'src/archive/zip_writer.dart';
export 'src/cli/failures.dart';
export 'src/cli/findings.dart';
export 'src/cli/plugin_manifest.dart';
export 'src/cli/version.dart';
export 'src/create/package_set.dart';
export 'src/create/template_renderer.dart';
export 'src/crypto/sha256.dart';
export 'src/fetch/cancel.dart';
export 'src/fetch/github_release.dart';
export 'src/json/json.dart';
export 'src/json/names.dart';
export 'src/json/semver.dart';
export 'src/project/project_file.dart';
export 'src/project/project_paths.dart';
export 'src/project/pubspec_constraints.dart';
export 'src/project/pubspec_editor.dart';
// The command framework where there is a machine; nothing more on the web.
// The native barrel is the default, so the analyzer and dartdoc see it.
export 'src/native.dart' if (dart.library.js_interop) 'src/web.dart';

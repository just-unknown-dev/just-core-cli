/// The project toolkit `just` and its plugins share: finding a project,
/// editing its pubspecs without disturbing them, changing it all or nothing,
/// running pub, and reading what pub resolved.
///
/// - [JustProject]: a project folder, and [writeTextAtomic] for its files;
///   [JustProjectFile]: its `just.json`, read and saved with
///   [JustProject.readProjectFile] and [JustProject.writeProjectFile];
///   [ProjectPaths]: the names of its files and folders.
/// - [PubspecEditor]: edits inside one tool's [ManagedBlock], keeping every
///   other line, comment and line ending as it was.
/// - [OverridesTarget]: which file pub reads `dependency_overrides` from.
/// - [ProjectLock] and [ProjectTransaction]: one change at a time, journalled
///   so a failure or a crash is undone.
/// - [SdkLocator], [PubRunner]: the Flutter SDK, and `pub get`.
/// - [PackageConfig], [PackageGraph]: what pub resolved.
/// - [PackageSet] and [SetPackage]: package versions that work together;
///   [ToolSet]: the tools `just` keeps a project on, and the kinds of
///   project `just create` makes; [DevLinks]: overrides to local checkouts.
/// - [ProjectNames], [TemplateRenderer] and [GitIgnores]: a new project's
///   names, its template filled in, and its `.gitignore`.
/// - [Version], [VersionConstraint], [JsonFields], [PackageNames],
///   [Sha256], [FileHashes], [UserPaths].
library;

export 'src/create/dev_links.dart';
export 'src/create/package_set.dart';
export 'src/create/template_renderer.dart';
export 'src/crypto/sha256.dart';
export 'src/json/json.dart';
export 'src/json/names.dart';
export 'src/json/semver.dart';
export 'src/project/just_project.dart' hide samePath;
export 'src/project/overrides_target.dart';
export 'src/project/package_info.dart';
export 'src/project/project_file.dart';
export 'src/project/project_paths.dart';
export 'src/project/pub_runner.dart';
export 'src/project/pubspec_constraints.dart';
export 'src/project/pubspec_editor.dart';
export 'src/project/transaction.dart' hide timeStamp;
export 'src/project/user_paths.dart';

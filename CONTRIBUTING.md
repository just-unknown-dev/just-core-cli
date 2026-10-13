# Contributing to Just CLI

Thank you for your interest in contributing to **Just Core CLI** (just_core_cli), the core of the Just ecosystem's command-line tool: the part every product and plugin builds on. Bug fixes, features, tests and documentation are all welcome.

---

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Reporting Bugs and Suggesting Features](#reporting-bugs-and-suggesting-features)
- [Development Setup](#development-setup)
- [Working Against Unpublished Dependencies](#working-against-unpublished-dependencies)
- [How the Package Fits Together](#how-the-package-fits-together)
- [The `tool/` Folder](#the-tool-folder)
- [Running the Tests](#running-the-tests)
- [Coding Guidelines](#coding-guidelines)
- [Submitting a Pull Request](#submitting-a-pull-request)
- [Releasing](#releasing)
- [Commit Message Convention](#commit-message-convention)
- [License](#license)

---

## Code of Conduct

This project follows our [Code of Conduct](CODE_OF_CONDUCT.md). By taking part you agree to its terms. Please report unacceptable behaviour to the maintainers.

---

## Reporting Bugs and Suggesting Features

Before opening an issue, search the [existing issues](https://github.com/just-unknown-dev/just-core-cli/issues) and check that the problem happens on the latest version.

A bug report should have:

- a clear title;
- the command you ran, and what you expected instead of what happened. Run it again with `--verbose` and include the output; if a script hit the problem, include its `--json` output too;
- the output of `just --version`, `just doctor` and `flutter --version`, and your operating system and shell;
- how you installed `just`: `dart pub global activate just_core_cli`, a release binary (the install scripts in `tool/`), or a project's own. A global `just` run inside a project that pins just_core_cli hands the run to the pinned version, and `--verbose` says when it does;
- for a command that changes a project: the project's `pubspec.yaml`, `pubspec_overrides.yaml` and `just.json`, whether the failed command left anything changed, and whether a journal was left in `.dart_tool/just_core_cli/txn/`.

Most of what `just` does in a project comes from plugins, whose bugs belong in their own repositories: `game` (and what `just create` writes into a game, the game's part of `just check`, `just doctor`, `just upgrade` and `just dev link|unlink`, through its hooks) is [just_game_engine_cli](https://github.com/just-unknown-dev/just-game-engine-cli/issues)'s; `store`, `add` and `remove` are [just_asset_store](https://github.com/just-unknown-dev/just-asset-store/issues)'s. `just --verbose` says which plugin ran.

For a feature, open an issue labelled **`enhancement`** that describes the problem it solves and how it should behave. The core's scope is what every project and every product shares: creating a project (up to its kind's `create` hook), checking its setup, moving its tools to a tool set, linking it to local checkouts, running plugins and their hooks; plus the toolkit plugins build on (the command framework, project transactions, pubspec edits, version sets, templates, downloads and archives). Nothing product-specific belongs here — no package of a product, no SDK floor, no file format: those are the product's plugin's. A change to a command's `--json` output or exit codes, to `just_plugin.json` or its hooks, or to the blocks `just` manages in pubspecs reaches scripts, plugins and existing projects, so open the issue first and agree the approach before you write it.

---

## Development Setup

| Tool | Minimum version |
|------|-----------------|
| Dart | 3.11.0 |
| Flutter | Not needed for the tests. Commands that run Flutter (`create`, `dev link`, `upgrade`) find it on the `PATH` or through `FLUTTER_ROOT`; `just doctor` says which it found (the floors are the plugins': `just game doctor` checks the engine's) |

```bash
git clone https://github.com/just-unknown-dev/just-core-cli.git just_core_cli
cd just_core_cli
dart pub get
dart test
```

If you're working from the Just engine monorepo, run every command from `packages/just_core_cli`.

**Running the tool from source.** `bin/just.dart` and `bin/ju.dart` are the tool's two names; both call `runJust`. Inside this repository the nearest project is just_core_cli itself, so name a project with `--project`:

```bash
dart run bin/just.dart --help
dart run bin/ju.dart --version
dart run bin/just.dart doctor --project ../my_game
```

To use your checkout as `just` everywhere, run `dart pub global activate --source path .`, and `dart pub global deactivate just_core_cli` to go back. `dart compile exe bin/just.dart -o build/just` builds the binary the release ships (`build/` is ignored). A project that pins another version of just_core_cli hands every command except `upgrade` to that version (`ProjectPin`). To run your code there, link the project to your checkouts first: `dart run bin/just.dart dev link <folder with your just_* checkouts> --project ../my_game`.

---

## Working Against Unpublished Dependencies

Besides `args`, the package depends on one package of its own ecosystem: `just_deflate` (compression for `ZipArchive` and `ZipWriter`). When a change needs an unreleased version of it, check it out next to this repository and point this package at it with a `pubspec_overrides.yaml` in the repository root:

```yaml
# pubspec_overrides.yaml: local only, never commit it.
dependency_overrides:
  just_deflate:
    path: ../just_deflate
```

Then run `dart pub get`. Delete the file (or the entry) and run `dart pub get` again to go back to the published version. `.gitignore` already ignores the file.

Do not change `pubspec.yaml` to a path dependency. If your pull request needs a version of it that is not published yet, say so in the pull request: this package can only be released after it.

Three kinds of code depend on this package. The plugins build their commands on `JustCommand` and `runJustPlugin` and use the project toolkit: `just_game_engine_cli` (the game's commands and all six hooks, `PackageSet` for its `GameSet`, `TemplateRenderer`, `GitIgnores`, `PubspecConstraints` and `runTrustedPlugin`) and `just_asset_store` (also the downloads). And every project pins just_core_cli in its `dev_dependencies` (`ToolSet.current`). If you change the public API, `just_plugin.json`, the hooks' arguments or contracts, or the managed pubspec blocks, say in the pull request what they will need.

---

## How the Package Fits Together

| Folder | Contents |
|--------|----------|
| `bin/` | `just.dart` and `ju.dart`: the tool's two names, both calling `runJust` |
| `lib/src/cli/` | The command framework: `runJust`, `runJustPlugin`, `JustRunner`, `JustCommand`, `JustContext`, `Output`, `Finding`, `ExitCodes` and `Launcher`; plugins (`PluginManifest`, `PluginFinder`, `PluginSource`, `PluginTrust`, `UserPluginAllowList`, `PluginCommand`, `runTrustedPlugin`) and the project's pin (`ProjectPin`) |
| `lib/src/commands/` | The built-in commands: `create`, `check`, `dev`, `doctor` and `upgrade` (`version` is in `entry.dart`); `hooks.dart` runs the plugins' hooks |
| `lib/src/create/` | `PackageSet`, `SetPackage` and the `ToolSet`; `DevLinks`; `TemplateRenderer`, `ProjectNames` and `GitIgnores` for a new project's files |
| `lib/src/project/` | `JustProject`, `JustProjectFile`, `PubspecEditor` and `ManagedBlock`, `PubspecConstraints`, `ProjectLock` and `ProjectTransaction`, `SdkLocator` and `PubRunner`, `PackageConfig`, `UserPaths`; `windows_batch.dart`, the rules for passing arguments to a `.bat` through cmd.exe |
| `lib/src/fetch/`, `lib/src/archive/` | `HttpFetcher`, `DownloadCache`, `GitHubRepo` and `CancelToken`; `ZipArchive`, `ZipWriter` and `SafePaths` |
| `lib/src/json/`, `lib/src/crypto/` | `JsonFields`, `PackageNames`, `Version` and `VersionConstraint`; `Sha256` |
| `lib/just_core_cli.dart`, `lib/project.dart`, `lib/fetch.dart` | The public libraries: the primary one (the toolkit on every platform, and the command framework off the web), the project toolkit on disk, and downloads and archives |
| `lib/src/native.dart`, `lib/src/web.dart` | What the primary library adds off the web (the command framework) and on it (nothing): `export 'src/native.dart' if (dart.library.js_interop) 'src/web.dart';` |
| `tool/` | The install scripts (see [below](#the-tool-folder)) |
| `example/` | A plugin that adds `just hello` |
| `test/` | The tests; `test/fixtures/` and `test/support/raw_zip.dart` |
| `.github/workflows/` | `ci.yml`, and `release.yml`, which builds the binaries for a `v*` tag |

A few rules hold the package together. Keep them:

- **The core knows no product.** Nothing in `lib/` names a product in its behaviour, its help or its messages: no product's packages or SDK floors, file formats, folders, pubspec blocks or trash. What is a game's — its template, its packages' versions and SDK floors (`GameSet`), its scenes, its release checks, its saved formats, the editor's trash — lives in `just_game_engine_cli`; the Asset Store's pubspec block and trash live in `just_asset_store`. Two pieces of data are the exception, on purpose:
  - `PluginTrust.official`: the ecosystem's own package names. It is the trust policy — which plugins run without asking — and a policy has to name what it trusts.
  - `ToolSet.current`: the tools a project is kept on — just_core_cli and the plugin of each kind — and the kind map (`game` → `just_game_engine_cli`). It is what `just create` adds and `just upgrade` moves, so it must name them; everything else about a product comes from its plugin.

  Doc comments may name the example plugin (`hello`, from `example/`) or a made-up tool (`my_tool`), never a product.
- **Hooks are the plugins' commands, under the plugins' trust rule.** A manifest's `hooks` name a plugin command for `create`, `check`, `doctor`, `upgrade`, `migrate` and `link` (`PluginManifest.hooks` holds the contract). A plugin that isn't trusted is asked about in a terminal (`askPluginTrust`, the answer saved) or skipped with a warning that says how to allow it — never silently (`trustedHooks` in `lib/src/commands/hooks.dart`). Each hook gets `--json` and `--verbose` when the run had them; under `--json` its stdout is read (`Launcher.run`'s `stdout`) and its document goes into the result under its package name (`runHook`). Wherever a hook is called with `--check`, a usage error (`PluginManifest.cannotCheck`: 2 or 64) is a warning, not a stop.
  - `create` runs the kind's plugin's hook in the new project with `--title`, `--org`, `--platforms`, `--template`, `--source` and `--local`, and `--yes` only when the user gave it; the plugin picks its own packages' versions. `create` writes just_core_cli and the plugin as plain one-line `dev_dependencies` (`PubspecConstraints.add`); the hook owns the pubspec from then on and must keep them so, for `upgrade` to move them.
  - `check` fails when the packages were never fetched or no hook ran. `doctor` checks the tool on the PATH, Flutter (no floor), the tools against the `ToolSet`, constraints an override hides, the overrides' git ignore and plugin clashes, then the hooks.
  - `upgrade` moves the tools; when they stay, it asks each `upgrade` hook with `--check` (always reading its document) what it would move, and is up to date when nothing would. It asks each `migrate` hook with `--check` before anything changes (only when it will move the project). Then, in one transaction: the tools, `pub get`, each `upgrade` hook with `--yes` (one-line bumps, no `pub get`, no lock), `pub get` again when the pubspec changed, each `migrate --check` again, `just.json`; any failure rolls it all back. The migrations run after the commit, with `--yes` once the user said yes (without it, each asks before it rewrites). Arguments after `--` go to every `migrate` hook. With `--json`, each plugin's `upgrade` and `migrate` documents are in the result, and a migration's `migrated` (a list) sets `changed`.
  - `dev link` writes the overrides and fetches in a transaction, then runs each `link` hook with `<name>=<path>` for every checkout; `dev unlink` asks each with `--unlink --check` first (a no keeps the links) and tells each with `--unlink` after. What a link means for the Asset Store is the game plugin's business.
- **A change to a project is all or nothing.** A command that writes project files takes the `ProjectLock`, calls `ProjectTransaction.recover`, writes through a `ProjectTransaction`, and commits or rolls back. The journal lives in `.dart_tool/just_core_cli/txn/`, and folders a change replaces or removes go to `<trashRoot>/<trash>/<stamp>/`: `ProjectTransaction.begin` takes the tool's own `trash` folder name, and a `trashRoot` that defaults to `.just_trash` (`ProjectTransaction.defaultTrashRoot`, which new projects git-ignore through `GitIgnores.withDefaults`). Both are journalled, so `recover` finishes a change in the same place; `recover`'s `trash` and `trashRoot` say where an older journal that names neither goes. A product with a trash of its own passes it (the game plugin and the Asset Store pass `.editor_trash`, which the editor restores from). A failure exits 1 after the rollback; a rollback that fails itself names what is left, and the next `recover` finishes it. Steps after the commit (the migrations at the end of `upgrade`, a `link` hook after `dev link|unlink`) exit 1 with the change kept, and say so (the README lists every exit code). Writes follow a symbolic link only while it stays in the project (a link that leads out is refused), and a link backed up is put back as a link. Release the lock in a `finally`: its heartbeat timer keeps the process alive until then. A rollback can run again after a crash, and `rollBack()` after `commit()` does nothing, so the usual `catch → rollBack(); rethrow` is always safe. `create` removes the folder it made instead.
- **Pubspecs keep every other byte.** `PubspecEditor` changes only the lines inside one tool's `ManagedBlock`, which every `PubspecEditor.parse` names (`marker:` is required — there is no default owner): `ManagedBlock.devLinks` for `just dev link`, and each tool defines its own (the Asset Store's `storeBlock`, in its package). Any other `# >>> owner managed` block is off-limits; `PubspecConstraints` edits and adds one-line entries a person could have written. Comments, order, blank lines, a byte order mark and CRLF or LF endings stay as they were, and what it can't edit safely (inline sections, tabs, anchors) it refuses. Local path overrides go in `pubspec_overrides.yaml`, never in `pubspec.yaml`. `JustProjectFile` keeps the keys of `just.json` it doesn't know, and entry values that aren't paths.
- **Every command keeps the same contract.** A command reads the world through `context` (`JustContext`), prints through `output` (`Output`) and starts programs through `context.launcher`. With `--json` there is one JSON document on stdout and every message goes to stderr. It fails by throwing `CommandFailure` or `UsageFailure`, and exits with `ExitCodes.ok` (0), `ExitCodes.failure` (1) or `ExitCodes.usage` (2), never with a stack trace. A command that hands the terminal to another program (a plugin's: `printsOwnDocument`) prints no document of its own and exits with that program's code. Plugins get the same through `runJustPlugin`, so a change here reaches every plugin.
- **Plugins are read before they run, and projects run the `just` they pin.** `just` lists a plugin's commands from its `just_plugin.json` without running its code, and refuses a manifest newer than `PluginManifest.currentSchema`. A name in `PluginTrust.official` is trusted only when `PluginSource` (read from `pubspec.lock`) says the package comes from a path or a git repository under github.com/just-unknown-dev, or from pub.dev for a name in `PluginTrust.onPubDev` — the names the ecosystem publishes there. **A name goes into `onPubDev` in the just_core_cli release that goes out with that package's first publication, and the package is published right after it** (a plugin depends on just_core_cli, so it can't go first): just_game_engine_cli is published right after this release. Never list a name that won't be published at once: until it is, anyone could take it. Any other plugin, global ones included, is asked about once in a terminal, and the answer is kept in the project's `just.json` (`plugins.allowed`) or, for a global plugin, in the user's `plugins.json` (`UserPluginAllowList`), which counts for every project too. `--yes` never allows a plugin. Hooks and `runTrustedPlugin` follow the same rule. A global `just` hands a run to the project's pinned version through `dart run just_core_cli:just`, except `upgrade`, which moves the pin itself.
- **Versions travel together.** `justCoreCliVersion` in `lib/src/cli/version.dart` must equal the version in `pubspec.yaml` (a test checks it), and `release.yml` refuses a tag that doesn't match. `ToolSet.current` is the set of tool versions this release creates projects on, checks them against and upgrades them to; the plugins' packages are in the plugins' own sets.

---

## The `tool/` Folder

`tool/install.sh` (macOS and Linux) and `tool/install.ps1` (Windows) install `just` and `ju` from the newest GitHub release, checked against its `SHA256SUMS`. `install.ps1` puts its folder at the end of the user `PATH` and `install.sh` tells you to, so another `just` (the command runner) keeps working. Both depend on the archive names `release.yml` writes (`just_core_cli-<tag>-<os>-<arch>.tar.gz`, or `.zip` for Windows): change the workflow and the scripts together. They install a published release, never your checkout.

The game template `just create` lays over a new game is `just_game_engine_cli`'s. To try a change to `create` for real, run `dart run bin/just.dart create <an empty folder>/my_game --local <folder with your just_* checkouts>` (with just_core_cli and just_game_engine_cli among them), then `flutter analyze` and `flutter test` in `my_game`. `--local` links each folder whose name is its package's name and starts with `just_`.

---

## Running the Tests

Run every command from the repository root: the tests read `pubspec.yaml` and `test/fixtures/` by relative path.

```bash
# The whole suite.
dart test

# One file.
dart test test/upgrade_test.dart
```

There is no `dart_test.yaml` and there are no test tags. CI (`.github/workflows/ci.yml`) runs `dart analyze --fatal-infos`, a `dart format` check and `dart test` on Linux, Windows and macOS, and runs `dart pub publish --dry-run`; its `browser` job runs the tests in Chrome, as JavaScript and as WebAssembly.

**On the web.** Test files that need `dart:io` (or `project.dart` / `fetch.dart`) start with `@TestOn('vm')`; the others import only `package:just_core_cli/just_core_cli.dart` and run in a browser too, `test/web_test.dart` among them (a smoke test of the primary library's toolkit). With Chrome installed:

```bash
dart test -p chrome                 # compiled to JavaScript
dart test -p chrome -c dart2wasm    # compiled to WebAssembly
```

**On macOS and Linux.** `test/posix_test.dart` (`@TestOn('linux || mac-os')`) checks that writes and rollbacks keep a file's permissions, go through symbolic links, and that staged files marked executable are executable. It is skipped on Windows; CI runs it on Linux and macOS.

`.gitattributes` keeps every checkout LF, which some tests need.

**No test starts Flutter, a plugin or needs the internet.** The command tests call `runJust(args, context: JustContext(...))` on a temporary folder, with the output in `StringBuffer`s and a fake `Launcher` that records what would have run (`_FakeLauncher` in `test/dispatch_test.dart`, `_Flutter` in `test/project_commands_test.dart`, `_Pub` in `test/upgrade_test.dart`); plugins are folders with a `just_plugin.json`, resolved through a written `package_config.json` and `pubspec.lock`. Downloads are tested against a local `HttpServer` in `test/fetch_test.dart`. `test/pubspec_editor_test.dart` runs `dart pub get --offline` on an edited pubspec; `test/sha256_test.dart` compares with `certutil` on Windows and `test/zip_test.dart` reads the writer's archives with Python, each skipping that check when the tool is missing.

**Fixtures.** `test/fixtures/` holds zips made by real tools (`git archive`, PowerShell, Python) and pubspecs. `template_pubspec.yaml` has CRLF endings and `template_overrides.yaml` LF, on purpose: the pubspec editor must keep both. `test/support/raw_zip.dart` builds broken and hostile zips field by field.

---

## Coding Guidelines

- **Formatting.** Run `dart format lib bin test tool example`; CI fails on unformatted code, and pub.dev takes points for it.
- **Analysis.** `dart analyze --fatal-infos` must report no issues at all: no errors, warnings or infos. The rules are in `analysis_options.yaml`: `package:lints/recommended.yaml`, with `strict-casts` and `strict-raw-types`.
- **Pure Dart.** Nothing in `lib/`, `bin/` or `tool/` may import Flutter. `release.yml` compiles the tool with `dart compile exe`.
- **Keep the primary library web-safe.** pub.dev gives a package its platforms from its primary library, `lib/just_core_cli.dart`: everything it exports directly, and everything those files import, must run on the web — no `dart:io`, `dart:ffi`, `dart:isolate` or `dart:mirrors`, and no import of a file that has one. What needs a machine goes in `lib/src/native.dart` (the command framework), `project.dart` or `fetch.dart`. A pure type may not grow a method that touches files: put that beside the IO code instead (as `JustProject.readProjectFile` does for `JustProjectFile`, and `Output.findings` for `Finding`). Ints are doubles on the web: keep arithmetic within 2^53 or mask it to 32 bits, as `Sha256` and the ZIP code do.
- **No direct I/O in commands.** Use `context`, `output` and `context.launcher`, never `print`, `stdout` or `Process`: tests replace all of them. Add a new built-in command to `builtInCommands()` in `lib/src/cli/entry.dart` — only one every project of the ecosystem needs; a product's goes in its plugin.
- **Documentation.** Give every public API you add a `///` doc comment. Describe user-visible changes in [CHANGELOG.md](CHANGELOG.md), and update [README.md](README.md) if a command or the public API changes.
- **Tests.** Add or update tests for any behaviour you change. A bug fix comes with a test that fails without it.
- **Dependencies.** Do not add a dependency without discussing it in an issue first.
- **Structure.** Match the existing folders under `lib/src/`. Export new public API through `lib/just_core_cli.dart`, `lib/project.dart` or `lib/fetch.dart`. Other code imports those libraries, not files under `lib/src/`.

---

## Submitting a Pull Request

1. Create a topic branch from `main`:
   ```bash
   git checkout -b fix/upgrade-line-endings
   ```
2. Make your change, following the [Coding Guidelines](#coding-guidelines).
3. Check that everything passes:
   ```bash
   dart format lib bin test tool example
   dart analyze --fatal-infos
   dart test
   ```
   If you changed `create`, try `create --local` as described [above](#the-tool-folder).
4. Commit with a [conventional commit message](#commit-message-convention).
5. Push to your fork and open a pull request against `main`. Say what changed and why. List any unpublished `just_deflate` version it needs, and any change it means for `just_game_engine_cli`, `just_asset_store`, other plugins or existing projects.
6. Answer review feedback.

Small pull requests are easier to review.

---

## Releasing

1. Set the version in `pubspec.yaml` and `justCoreCliVersion` (a test checks they match), and give `CHANGELOG.md` a `## <version>` section: the GitHub release takes its notes from it.
2. Publish what this version needs first: the `just_deflate` version `pubspec.yaml` asks for. `just create` adds the tools of `ToolSet.current`, so every version it names must be on pub.dev before people get this release, or `create` fails for them. The order is `just_game_engine_formats`, this package, then `just_game_engine_cli` (which depends on this one, and which the tool set names), then the engine's packages and the store's tag.
3. From a clean checkout of `main`, with no `pubspec_overrides.yaml`: `dart pub publish --dry-run`, then `dart pub publish`.
4. Push the tag `v<version>`. `release.yml` checks it matches `pubspec.yaml`, builds `just` and `ju` for Windows, macOS and Linux, and makes the GitHub release with `SHA256SUMS`, which the install scripts read.

---

## Commit Message Convention

We use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <short summary>
```

| Type | When to use |
|------|-------------|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `perf` | Performance improvement |
| `test` | Adding or updating tests |
| `chore` | Build process, tooling, dependencies |

Use the command or the area as the scope: `create`, `check`, `doctor`, `upgrade` or `dev`; or `cli`, `plugins`, `hooks`, `project`, `fetch`, `archive`, `tool` or `ci`. Mark a change that breaks the public API, a command's `--json` output or exit codes, or `just_plugin.json` with `!` and a `BREAKING CHANGE:` footer.

**Examples:**
```
fix(upgrade): keep the pubspec's line endings when raising a constraint
feat(doctor): report a FLUTTER_ROOT that holds no Flutter SDK
docs(contributing): explain the hook protocol
```

---

## License

By contributing to Just CLI you agree that your contributions will be licensed under the [BSD-3-Clause License](LICENSE).

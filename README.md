# Just Core Cli

The core of `just` (also `ju`), the Just ecosystem's command-line tool. It knows no product of its own: it makes projects, keeps their tools on versions that work together, checks their setup, links them to local checkouts, changes them all or nothing, and runs the commands and hooks plugins add. Everything a product needs — its template, its packages' versions, its checks, its file migrations — comes from its plugin.

The first product built on it is the [Just Game Engine](https://engine.justunknown.com/): every game has the [just_game_engine_cli](https://pub.dev/packages/just_game_engine_cli) plugin, which adds `just game run|build|scene…` and fills in the hooks below; the [Asset Store](https://github.com/just-unknown-dev/just-asset-store) adds `just store`, `add` and `remove`. Your own plugin builds on the same framework.

`ju` is the same tool under a second name, for machines where `just` is another program (such as the `just` command runner).

## Install

```text
dart pub global activate just_core_cli
```

Or download `just` and `ju` for Windows, macOS or Linux from the [releases](https://github.com/just-unknown-dev/just-core-cli/releases) (the install scripts in `tool/` do it for you, and never put our `just` in front of another). `just doctor` checks the rest.

## Use

```text
just create my_game                 # a new project of a kind (--kind game, the default)
cd my_game
just check                          # every installed plugin's checks
just doctor                         # Flutter, the tools, links, then each plugin's checks
just upgrade                        # the tools, each plugin's packages, then its migrations
just dev link ../packages ../plugins  # point the project at local checkouts
just dev unlink
just version
just help game run                  # a plugin command's own help
```

`create <folder>` takes `--kind`, `--template`, `--title`, `--org`, `--platforms`, `--local <folder>` (once for each folder of checkouts) and `--source <catalog>`. It runs `flutter create`, writes `just.json`, adds just_core_cli and the kind's plugin to the dev dependencies as pub.dev versions (with `--local`, `pubspec_overrides.yaml` also points every just_* package in those folders at its checkout; a package checked out in two of them is refused), fetches the packages, and hands the project to the plugin's `create` hook. On a failure the folder is deleted when `create` made it, or emptied when it was there already, empty; anything that can't be deleted (a file in use) is named.

Every command takes `--json` (one JSON document on stdout, messages on stderr), `--yes` (go ahead without asking, for scripts and CI), `--verbose` and `--project <folder>` (a folder without a `pubspec.yaml` is no project), before or after its name but before a `--`.

Exit codes:

- **0** done, or nothing to do.
- **1** failed. A change that fails is rolled back first; if even that fails (a file in use), the message names what is left, and the next run that changes the project finishes the rollback. Two steps come after the change is kept, and a failure there exits 1 too while keeping it: a plugin's migrations at the end of `upgrade`, and a plugin's `link` hook after `dev link` or `dev unlink`. The message says which.
- **2** called wrongly: an unknown command, a missing argument, a bad option.
- A plugin's command, and a run handed to the project's pinned `just`, exit with that process's code; a process ended by a signal gives 128 + the signal's number, as a shell does.

Plugins' commands hand the terminal to the plugin, which prints its own document.

Flutter is found through `FLUTTER_ROOT` first — set it to the SDK's folder, and that SDK is used — then the SDK that last fetched the project's packages, then `flutter` on the `PATH`. When `flutter` there is a launcher outside the SDK (a snap, a version manager's shim), `just` asks it where its SDK is (`flutter --version --machine`, stopped after 20 seconds).

## How it works

- **Projects pin their own `just`.** A project lists just_core_cli in its dev dependencies; a global `just` run inside it hands over to that version (all but `upgrade`, which moves the pin itself), so a team runs the same tool whatever each person installed.
- **Versions travel in sets.** The core carries one set, the **tool set** (`ToolSet`): just_core_cli itself and the plugin of each kind of project (`game` → just_game_engine_cli). Its id is `just.json`'s `set`. Each plugin carries the versions of its own packages and moves them through its `upgrade` hook — the game plugin's `GameSet` holds the engine's, and the Flutter and Dart it needs.
- **Packages add commands.** A package with a `just_plugin.json` and a `bin/just_plugin.dart` adds commands; `just` runs them with `dart run`, at the version the project resolved, or from a package installed with `dart pub global activate`. The ecosystem's own packages (`PluginTrust.official`) run without asking when they come from a local checkout or github.com/just-unknown-dev, and from pub.dev only under the names the ecosystem publishes there (`PluginTrust.onPubDev`: just_game_engine_cli, published right after 0.1.0, and just_asset_store, right after 0.1.1; a name is added in the release that goes out with its first publication, as until then anyone could take it). Any other asks once in a terminal, and the answer is kept in the project's `just.json`, or in `plugins.json` in your user settings — for a global one, and for every project. `--yes` never allows one.
- **Changes are all or nothing.** Every change to a project is journalled and backed up first; a failure puts every byte back, permissions included (a symbolic link stays a link, and the file it points to is the one written — only inside the project: a link that leads out of it is refused), and a crash is rolled back the next time. One change runs at a time: a project lock says who holds it, and is taken over once its holder stops renewing it, or at once when that holder was a process on this machine, in this system (not WSL beside Windows, not a Flatpak sandbox beside its host), that is no longer running. What a change replaces or removes goes to the trash — `.just_trash/<tool>/` unless the tool keeps its own (the game's commands and the Asset Store use the editor's `.editor_trash/`).
- **Pubspecs keep every other byte.** A tool edits only its own marked block of a pubspec (`ManagedBlock`; every edit names one), never another tool's, and leaves comments, order and line endings as they were.
- **The core names no product.** Two pieces of data are the exception: the ecosystem's own package names (`PluginTrust.official`, the trust policy: which plugins run without asking) and the tool set (`ToolSet.current`: just_core_cli, the plugin of each kind of project, and the kind map). Everything a product needs comes from its plugin.

## Hooks

A manifest's `hooks` name the plugin's commands for six moments. They run under the same trust rule as the plugin's commands (one that isn't trusted is asked about in a terminal, or skipped with a warning — never silently), get `--json` and `--verbose` when the run had them, and with `--json` their own documents go into the run's result under the plugin's name. `upgrade` hooks are the exception: they always get `--json`, because `just` reads what they would move from their document. Every option `just` passes comes before a `--`, and one with a value as a single `--name=value` argument.

| Hook | When | Contract |
|---|---|---|
| `create` | `just create`, in the new project | Fill it in. Gets `--title=…`, `--org=…`, `--platforms=…`, `--template=…`, `--source=…`, `--local=…` (one for each folder) as given, `--yes` only when the user gave it. Must keep just_core_cli and itself in `dev_dependencies`, one line each, so `upgrade` can move them. |
| `check` | `just check` | Exit 0 when all is well. `just check` fails when nothing was checked. |
| `doctor` | `just doctor` | The plugin's own checks. |
| `upgrade` | `just upgrade`, in its transaction | Move the plugin's own packages: one-line constraint bumps in `pubspec.yaml`, no `pub get`, no other file, no lock. `--check` changes nothing; its document lists `packages: {name: {from, to}}`. |
| `migrate` | `just upgrade`, before and after the move | Bring the plugin's files up to date. `--yes` only once the user said yes; without it, ask before rewriting. Its result's `migrated` lists what it rewrote. |
| `link` | `just dev link`, `just dev unlink` | After a link, `<name>=<path>` for every checkout; before an unlink, `--unlink --check` (non-zero keeps the links); after it, `--unlink`. |

**`--check`.** Wherever `just` calls a hook with `--check`, the hook must change nothing and exit non-zero, saying why, when what it would do could not be done. One that can't check exits with a usage error (2, or 64): `just` warns and goes on.

**`just upgrade`** moves the tools; when they stay, it asks each `upgrade` hook with `--check` what it would move, and says "up to date" when nothing would. Before anything changes it asks each `migrate` hook with `--check`. Then, in one transaction: the tools, `pub get`, each `upgrade` hook, `pub get` again when the pubspec changed, each `migrate --check` again with the new packages, `just.json` — any failure rolls it all back. Then the migrations run. Anything after `--` goes to every `migrate` hook: `just upgrade -- --engine-only`.

## Platforms

- **The `just` tool** runs on Windows, macOS and Linux, where Flutter does.
- **The toolkit in `package:just_core_cli/just_core_cli.dart`** runs on every platform Dart does: Windows, macOS, Linux, Android, iOS, and the web, compiled to JavaScript or WebAssembly. On the web that library holds only the toolkit; everywhere else it holds the command framework too.
- `package:just_core_cli/project.dart` and `package:just_core_cli/fetch.dart` work on files and the network, so they need `dart:io`: every platform but the web.

## As a library

- `package:just_core_cli/just_core_cli.dart`, on every platform: JSON fields, names and versions (`JsonFields`, `PackageNames`, `Version`, `VersionConstraint`), `Sha256`, ZIP files read and written in memory (`ZipArchive`, `ZipWriter`, `SafePaths`), pubspec edits that keep every other byte (`PubspecEditor`, `ManagedBlock`, `PubspecConstraints`), templates (`TemplateRenderer`, `ProjectNames`, `GitIgnores`), version sets (`PackageSet`, `ToolSet`), `just.json` (`JustProjectFile`), plugin manifests (`PluginManifest`, and its hook contract), `Finding`, `ExitCodes`, `ProjectPaths`, `CancelToken`, `GitHubRepo`. Off the web it also holds the command framework plugins build on: `JustCommand`, `runJustPlugin`, `Output`, `Launcher`, the plugins and their trust rule, and `runTrustedPlugin` to call another plugin.
- `package:just_core_cli/project.dart`: the project on disk — `JustProject` (with `readProjectFile`/`writeProjectFile` for `just.json`), transactions and the project lock, pub and the Flutter SDK, `DevLinks`, and the toolkit above.
- `package:just_core_cli/fetch.dart`: HTTPS downloads pinned by size and SHA-256, the download cache, and the ZIP toolkit.

The [example](example/just_core_cli_example.dart) is a plugin that adds `just hello`; [just_game_engine_cli](https://pub.dev/packages/just_game_engine_cli) is a complete one.

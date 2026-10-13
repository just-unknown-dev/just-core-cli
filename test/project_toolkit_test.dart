// The project toolkit's smaller parts: paths, atomic writes, per-user
// folders, what pub resolved, the SDK and running pub.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:just_core_cli/project.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('just_toolkit_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String here() => normalPath(Directory.current.absolute.path);

  group('JustProject', () {
    test('resolves . and .. in its root', () {
      for (final spelling in ['.', 'test/..', './test/../.']) {
        final project = JustProject(spelling);
        expect(project.root, here(), reason: spelling);
        expect(project.relativeOf('${here()}/sub/a.txt'), 'sub/a.txt');
        expect(project.pathTo('${here()}/sub'), 'sub');
        expect(project.pathTo('${here()}/../other'), '../other');
      }
    });

    test('paths it is given are resolved too', () {
      final project = JustProject(here());
      expect(project.relativeOf('${here()}/lib/../test/x.dart'), 'test/x.dart');
      expect(project.pathTo('${here()}/test/../..'), '..');
    });

    test('drives and shares', () {
      final project = JustProject(r'C:\games\space\.');
      expect(project.root, 'C:/games/space');
      expect(project.pathTo('C:/games/engine'), '../engine');
      expect(project.pathTo('D:/engine'), 'D:/engine');
      expect(JustProject(r'C:\..\..').root, 'C:/');
      final shared = JustProject(r'\\server\share\games\space');
      expect(shared.root, '//server/share/games/space');
      expect(shared.pathTo('//server/share/engine'), '../../engine');
      expect(shared.pathTo('//other/share/engine'), '//other/share/engine');
    }, skip: Platform.isWindows ? false : 'Windows paths');
  });

  group('writeTextAtomic', () {
    test('leaves no temporary file, whether it works or not', () {
      final file = File('${tmp.path}/a/b.json');
      writeTextAtomic(file, '1');
      writeTextAtomic(file, '2');
      expect(file.readAsStringSync(), '2');
      // A folder where the file should be: the rename fails.
      final blocked = Directory('${tmp.path}/c.json')..createSync();
      expect(
        () => writeTextAtomic(File(blocked.path), 'x'),
        throwsA(isA<FileSystemException>()),
      );
      final names = tmp
          .listSync(recursive: true)
          .map((e) => e.path.replaceAll(r'\', '/').split('/').last);
      expect(names.where((n) => n.endsWith('.saving')), isEmpty);
    });
  });

  group('UserPaths', () {
    test('empty variables count as unset', () {
      if (Platform.isWindows) {
        expect(
          UserPaths.cacheDir(
            'x',
            environment: {'LOCALAPPDATA': '', 'APPDATA': r'C:\Users\u\Roaming'},
          ),
          'C:/Users/u/Roaming/x',
        );
        expect(UserPaths.configDir(environment: {'APPDATA': ' '}), isNull);
      } else if (Platform.isMacOS) {
        expect(UserPaths.configDir(environment: {'HOME': ''}), isNull);
      } else {
        expect(
          UserPaths.cacheDir(
            'x',
            environment: {'XDG_CACHE_HOME': '', 'HOME': '/home/u'},
          ),
          '/home/u/.cache/x',
        );
        expect(
          UserPaths.configDir(
            environment: {'XDG_CONFIG_HOME': 'relative', 'HOME': '/home/u'},
          ),
          '/home/u/.config/just_core_cli',
        );
        expect(UserPaths.configDir(environment: {'HOME': ''}), isNull);
      }
      expect(
        UserPaths.configDir(environment: {'JUST_CORE_CLI_CONFIG_DIR': '/cfg/'}),
        '/cfg',
      );
    });
  });

  group('what pub resolved', () {
    void writeConfig(String root) {
      File('$root/.dart_tool/package_config.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {'name': 'a', 'rootUri': '../pkgs/a', 'packageUri': 'lib/'},
            ],
          }),
        );
      File('$root/.dart_tool/package_graph.json').writeAsStringSync(
        jsonEncode({
          'roots': ['a'],
          'packages': [
            {'name': 'a', 'version': '1.0.0', 'dependencies': []},
          ],
        }),
      );
    }

    test("a workspace member reads the workspace's files", () {
      final root = normalPath(tmp.path);
      writeConfig(root);
      final member = '$root/pkgs/a';
      File('$member/pubspec.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('name: a\nresolution: workspace\n');
      // Before pub wrote the member's pointer: found by looking up.
      expect(PackageConfig.read(member)?.packages['a']?.rootPath, member);
      File('$member/.dart_tool/pub/workspace_ref.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({'workspaceRoot': '../../../..'}));
      expect(PackageConfig.read(member)?.packages['a']?.rootPath, member);
      expect(PackageGraph.read(member)?.versionOf('a'), Version(1, 0, 0));
    });

    test('a package outside a workspace needs its own', () {
      writeConfig(normalPath(tmp.path));
      final alone = '${tmp.path}/pkgs/b';
      File('$alone/pubspec.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('name: b\n');
      expect(PackageConfig.read(alone), isNull);
    });

    test("a package in PUB_CACHE's folder is in pub's cache", () {
      final cache = normalPath('${tmp.path}/my cache');
      final p = ResolvedPackage(
        'a',
        '$cache/hosted/pub.dev/a-1.0.0',
        '$cache/hosted/pub.dev/a-1.0.0/lib',
      );
      expect(p.inPubCache(environment: {'PUB_CACHE': cache}), isTrue);
      expect(p.inPubCache(environment: {}), isFalse);
      expect(
        const ResolvedPackage('b', '/x/.pub-cache/hosted/b', '').isInPubCache,
        isTrue,
      );
    });
  });

  group('SdkLocator', () {
    String launcher(String sdk) =>
        '$sdk/bin/flutter${Platform.isWindows ? '.bat' : ''}';

    String fakeSdk(String name) {
      final sdk = normalPath('${tmp.path}/$name');
      File(launcher(sdk)).createSync(recursive: true);
      Directory('$sdk/bin/internal').createSync(recursive: true);
      return sdk;
    }

    test('finds flutter on the PATH, quoted entries too', () {
      final sdk = fakeSdk('flutter sdk');
      final separator = Platform.isWindows ? ';' : ':';
      final found = SdkLocator.locate(
        tmp.path,
        environment: {'PATH': '/nowhere$separator"$sdk/bin"'},
      );
      expect(normalPath(found!.root), sdk);
    });

    test('a launcher outside an SDK is passed over', () {
      // A version manager's shim: <shims>/flutter, no SDK around it.
      final shim = File(
        '${tmp.path}/a/shims/flutter${Platform.isWindows ? '.bat' : ''}',
      )..createSync(recursive: true);
      final sdk = fakeSdk('sdk');
      final separator = Platform.isWindows ? ';' : ':';
      final found = SdkLocator.locate(
        tmp.path,
        environment: {'PATH': '${shim.parent.path}$separator$sdk/bin'},
      );
      expect(normalPath(found!.root), sdk);
    });

    test('an explicit FLUTTER_ROOT wins over the SDK that last ran pub', () {
      final mine = fakeSdk('mine');
      final last = fakeSdk('last');
      File('${tmp.path}/.dart_tool/package_config.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': <Object>[],
            'flutterRoot': Uri.directory(last).toString(),
          }),
        );
      String? root(Map<String, String> env) {
        final sdk = SdkLocator.locate(tmp.path, environment: env);
        return sdk == null ? null : normalPath(sdk.root);
      }

      expect(root({'FLUTTER_ROOT': mine}), mine);
      expect(root({}), last);
      // One that holds no SDK is passed over.
      expect(root({'FLUTTER_ROOT': '${tmp.path}/none'}), last);
    });

    group('a launcher outside an SDK', () {
      final windows = Platform.isWindows;

      /// A `flutter` in [name] that runs [body]; its folder.
      String shim(String name, String body) {
        final file = File('${tmp.path}/$name/flutter${windows ? '.bat' : ''}')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            windows ? '@echo off\r\n$body\r\n' : '#!/bin/sh\n$body\n',
          );
        if (!windows) Process.runSync('chmod', ['+x', file.path]);
        return normalPath(file.parent.path);
      }

      /// A PATH with [dir] and the system's own programs: no other Flutter.
      Map<String, String> pathWith(String dir) => {
        'PATH': windows
            ? '$dir;${Platform.environment['SystemRoot']}\\System32'
            : '$dir:/bin:/usr/bin',
      };

      test('is asked where its SDK is, once', () async {
        final sdk = fakeSdk('asked');
        final dir = shim(
          'shims',
          windows
              ? 'echo x>> "%~dp0count"\r\necho {"flutterRoot": "$sdk"}'
              : 'echo x >> "\$0.count"\necho \'{"flutterRoot": "$sdk"}\'',
        );
        final env = pathWith(dir);
        expect(
          SdkLocator.locate(tmp.path, environment: env),
          isNull,
          reason: 'locate never starts a program',
        );
        final found = await SdkLocator.find(tmp.path, environment: env);
        expect(normalPath(found!.root), sdk);
        await SdkLocator.find(tmp.path, environment: env);
        expect(
          normalPath(SdkLocator.locate(tmp.path, environment: env)!.root),
          sdk,
          reason: 'its answer is kept',
        );
        final count = File(windows ? '$dir/count' : '$dir/flutter.count');
        expect(
          count.readAsLinesSync().where((l) => l.trim().isNotEmpty),
          hasLength(1),
        );
      });

      test('that takes too long is stopped', () async {
        final dir = shim(
          'slow',
          windows
              ? '"%SystemRoot%\\System32\\ping.exe" -n 30 127.0.0.1 >nul'
              : 'sleep 30',
        );
        final watch = Stopwatch()..start();
        final found = await SdkLocator.find(
          tmp.path,
          environment: pathWith(dir),
          timeout: const Duration(seconds: 1),
        );
        expect(found, isNull);
        expect(watch.elapsed, lessThan(const Duration(seconds: 15)));
      });
    });

    test('follows a link to the launcher', () {
      final sdk = fakeSdk('real');
      final link = Link(launcher('${tmp.path}/brew'));
      try {
        link.parent.createSync(recursive: true);
        link.createSync(launcher(sdk));
      } on FileSystemException {
        markTestSkipped('Making links needs Developer Mode on Windows.');
        return;
      }
      final found = SdkLocator.locate(
        tmp.path,
        environment: {'PATH': '${tmp.path}/brew/bin'},
      );
      expect(found, isNotNull);
      expect(
        normalPath(found!.root).toLowerCase(),
        normalPath(Directory(sdk).resolveSymbolicLinksSync()).toLowerCase(),
      );
    });
  });

  group('ProcessPubRunner', () {
    /// An SDK without its Dart, so pub get goes through [script] as the
    /// flutter launcher.
    FlutterSdk sdkRunning(String folder, String script) {
      final sdk = '${tmp.path}/$folder';
      final file = File('$sdk/bin/flutter${Platform.isWindows ? '.bat' : ''}')
        ..createSync(recursive: true);
      file.writeAsStringSync(script);
      if (!Platform.isWindows) Process.runSync('chmod', ['+x', file.path]);
      return FlutterSdk(sdk);
    }

    test('output that is not UTF-8 is shown, not fatal', () async {
      // Bytes in a console code page (CP932), then " ok".
      final sdk = sdkRunning(
        'sdk',
        Platform.isWindows
            ? '@echo off\r\ntype "%~dp0bytes.bin"\r\nexit /b 3\r\n'
            : '#!/bin/sh\ncat "\$(dirname "\$0")/bytes.bin"\nexit 3\n',
      );
      File(
        '${sdk.root}/bin/bytes.bin',
      ).writeAsBytesSync([0x93, 0x8c, 0x20, 0x6f, 0x6b, 0x0a]);
      final project = Directory('${tmp.path}/game')..createSync();
      final result = await ProcessPubRunner(sdk).get(project.path);
      expect(result.exitCode, 3, reason: result.stderr);
      expect(result.stdout, contains(' ok'), reason: result.stderr);
    });

    test('a launcher cmd.exe would misread is not run', () async {
      final ran = File('${tmp.path}/ran.txt');
      final sdk = sdkRunning(
        'R&D',
        '@echo off\r\necho ran > "${ran.path}"\r\n',
      );
      final project = Directory('${tmp.path}/game')..createSync();
      final result = await ProcessPubRunner(sdk).get(project.path);
      expect(result.ok, isFalse);
      expect(result.stderr, contains('"&"'));
      expect(ran.existsSync(), isFalse);
    }, skip: Platform.isWindows ? false : 'cmd.exe is Windows only');
  });
}

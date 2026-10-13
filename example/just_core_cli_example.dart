// A plugin: a package that adds `just hello` to the tool.
//
// In the package: this as bin/just_plugin.dart, and a just_plugin.json
// beside its pubspec:
//
//     {"schema": 1, "commands": [{"name": "hello", "summary": "Say hello."}]}

import 'dart:io';

import 'package:just_core_cli/just_core_cli.dart';

final class HelloCommand extends JustCommand {
  HelloCommand() {
    argParser.addOption('name', defaultsTo: 'world');
  }

  @override
  String get name => 'hello';

  @override
  String get description => 'Say hello.';

  @override
  Future<int> run() async {
    final who = argResults!.option('name');
    output
      ..result = {'greeted': who}
      ..line('Hello, $who!');
    return 0;
  }
}

Future<void> main(List<String> args) async {
  exitCode = await runJustPlugin(args, [HelloCommand()]);
}

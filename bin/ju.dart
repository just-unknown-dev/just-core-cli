// The `ju` command: `just` under a second name, for people whose `just` on
// PATH is another program.

import 'dart:io';

import 'package:just_core_cli/just_core_cli.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runJust(arguments, invokedAs: 'ju');
}

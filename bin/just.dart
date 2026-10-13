// The `just` command.

import 'dart:io';

import 'package:just_core_cli/just_core_cli.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runJust(arguments);
}

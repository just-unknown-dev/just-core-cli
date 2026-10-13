/// Running a `.bat` program, such as `flutter.bat`, on Windows: it goes
/// through cmd.exe, which reads some characters in its arguments as
/// commands, so arguments holding them are refused rather than passed on.
library;

import 'dart:io';

/// The characters cmd.exe reads in a batch program's arguments as more than
/// text: `&` and `|` start another command, `<` and `>` redirect, `^`
/// escapes, `%` and `!` expand variables, `"` quotes, and a line break ends
/// the command.
const String batchMetacharacters = '&|<>^%!"\r\n';

/// Whether [executable] runs through cmd.exe: a `.bat` or `.cmd` file, on
/// Windows ([isWindows], this platform by default).
bool runsThroughCmd(String executable, {bool? isWindows}) {
  if (!(isWindows ?? Platform.isWindows)) return false;
  final lower = executable.toLowerCase();
  return lower.endsWith('.bat') || lower.endsWith('.cmd');
}

/// Why [executable] can't be run with [arguments] through cmd.exe, or null
/// when it can (or it doesn't go through cmd.exe at all).
///
/// cmd.exe would run what follows an `&` in an argument as a command of its
/// own and expand `%NAME%`, so such arguments are refused. A quoted program
/// path (one with a space) can't be combined with quoted arguments either:
/// cmd.exe strips the outer quotes and splits the path.
String? batchArgumentProblem(
  String executable,
  List<String> arguments, {
  bool? isWindows,
}) {
  if (!runsThroughCmd(executable, isWindows: isWindows)) return null;
  for (final text in [executable, ...arguments]) {
    for (final c in text.split('')) {
      if (batchMetacharacters.contains(c)) {
        final shown = switch (c) {
          '\r' || '\n' => 'a line break',
          _ => '"$c"',
        };
        return 'On Windows, ${_name(executable)} runs through cmd.exe, which '
            'would read $shown in "$text" as part of a command. Rename the '
            'folder or leave the character out.';
      }
    }
  }
  bool quoted(String s) => s.contains(' ') || s.contains('\t');
  if (quoted(executable) && arguments.any(quoted)) {
    return '${_name(executable)} is in a folder whose path has a space '
        '(${executable.replaceAll('/', r'\')}), so cmd.exe can\'t also be '
        'given an argument with a space. Move it to a path without spaces, '
        'as Flutter recommends.';
  }
  return null;
}

String _name(String executable) =>
    executable.replaceAll(r'\', '/').split('/').last;

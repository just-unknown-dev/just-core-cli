/// Starting other programs — `dart run`, `flutter` — with the terminal
/// handed over to them.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../project/windows_batch.dart';
import 'failures.dart';

/// Runs a program with this process's stdin, stdout and stderr, and returns
/// its exit code. Tests replace it to see what would run.
abstract interface class Launcher {
  /// Runs [executable] with [arguments] in [workingDirectory], with
  /// [environment] added to this process's. With [toStderr], what it prints
  /// goes to this process's stderr — so a `--json` run's stdout holds only
  /// its document. With [stdout], what it prints on stdout goes there
  /// instead (decoded as UTF-8), and its stderr to this process's stderr:
  /// to read a plugin's `--json` document. Either way the program gets no
  /// input.
  Future<int> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String> environment = const {},
    bool toStderr = false,
    StringSink? stdout,
  });
}

/// The real [Launcher]: [Process.start] with inherited stdio.
///
/// While the program runs, Ctrl+C is the program's to handle: `just` waits
/// for it to finish and returns its exit code (on macOS and Linux, a
/// program ended by a signal gives 128 + the signal's number, as a shell
/// does). A `.bat` program on Windows (`flutter.bat`) goes through cmd.exe,
/// so an argument cmd.exe would read as a command is refused with a
/// [CommandFailure] instead ([batchArgumentProblem]).
final class ProcessLauncher implements Launcher {
  /// A launcher for real processes.
  const ProcessLauncher();

  @override
  Future<int> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String> environment = const {},
    bool toStderr = false,
    StringSink? stdout,
  }) async {
    final captured = toStderr || stdout != null;
    final problem = batchArgumentProblem(executable, arguments);
    if (problem != null) throw CommandFailure(problem);
    final Process process;
    try {
      process = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        mode: captured
            ? ProcessStartMode.normal
            : ProcessStartMode.inheritStdio,
        // A .bat launcher (flutter.bat) needs the shell on Windows.
        runInShell: runsThroughCmd(executable),
      );
    } on ProcessException catch (e) {
      // Without the VM's "(at process_win.cc:579)".
      final why = e.message.replaceAll(RegExp(r'\s*\(at [^)]*\)\s*$'), '');
      throw CommandFailure(
        'Could not start $executable: ${why.trim()}. Is it installed and on '
        'the PATH?',
      );
    }
    // The terminal's Ctrl+C reaches the program too: let it decide, and
    // report how it ended, rather than leaving it running behind a prompt.
    final interrupts = _ignoreInterrupts();
    try {
      if (captured) {
        // Nothing to answer with: a program that asks gets end of input.
        await process.stdin.close();
        await Future.wait([
          stdout == null
              ? process.stdout.forEach(stderr.add)
              : process.stdout
                    .transform(const Utf8Decoder(allowMalformed: true))
                    .forEach(stdout.write),
          process.stderr.forEach(stderr.add),
        ]);
      }
      return exitCodeOf(await process.exitCode);
    } finally {
      await interrupts?.cancel();
    }
  }

  /// [code] as a shell reports it: a negative code (a POSIX program ended by
  /// signal -[code]) becomes 128 + the signal. Unchanged on Windows.
  static int exitCodeOf(int code, {bool? isWindows}) =>
      code < 0 && !(isWindows ?? Platform.isWindows) ? 128 - code : code;

  static StreamSubscription<ProcessSignal>? _ignoreInterrupts() {
    try {
      return ProcessSignal.sigint.watch().listen(
        (_) {},
        onError: (Object _) {},
      );
    } on Object {
      // Not watchable here: Ctrl+C ends `just` as it would anyway.
      return null;
    }
  }
}

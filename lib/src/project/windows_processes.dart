/// Asking Windows whether a process runs, without starting a program.
library;

import 'dart:ffi';

/// Whether process [id] runs on this Windows machine: whether the system's
/// process list (`K32EnumProcesses`) has it. Every user's processes are in
/// it, so one this user may not open still counts as running. It returns
/// at once — no `tasklist` to wait on. Null when the list can't be had
/// (not Windows, or the call failed).
bool? windowsProcessRuns(int id) {
  final _Kernel32 api;
  try {
    api = _api ??= _Kernel32();
  } on Object {
    return null;
  }
  for (var size = 4096; size <= 1 << 20; size *= 4) {
    // [size] ids, then one more slot for the bytes the list took.
    final ids = api.localAlloc(_zeroInit, (size + 1) * 4);
    if (ids == nullptr) return null;
    try {
      final used = ids + size;
      if (api.enumProcesses(ids, size * 4, used) == 0) return null;
      final count = used.value ~/ 4;
      // A full list may have been cut short: ask again with more room.
      if (count >= size) continue;
      for (var i = 0; i < count; i++) {
        if (ids[i] == id) return true;
      }
      return false;
    } finally {
      api.localFree(ids);
    }
  }
  return null;
}

/// `LMEM_ZEROINIT`: memory from `LocalAlloc` starts as zeros.
const int _zeroInit = 0x40;

_Kernel32? _api;

/// The three kernel32 functions [windowsProcessRuns] needs.
final class _Kernel32 {
  _Kernel32() : this._(DynamicLibrary.open('kernel32.dll'));

  _Kernel32._(DynamicLibrary k32)
    : enumProcesses = k32
          .lookupFunction<
            Int32 Function(Pointer<Uint32>, Uint32, Pointer<Uint32>),
            int Function(Pointer<Uint32>, int, Pointer<Uint32>)
          >('K32EnumProcesses'),
      localAlloc = k32
          .lookupFunction<
            Pointer<Uint32> Function(Uint32, Size),
            Pointer<Uint32> Function(int, int)
          >('LocalAlloc'),
      localFree = k32
          .lookupFunction<
            Pointer<Void> Function(Pointer<Uint32>),
            Pointer<Void> Function(Pointer<Uint32>)
          >('LocalFree');

  final int Function(Pointer<Uint32> ids, int bytes, Pointer<Uint32> used)
  enumProcesses;
  final Pointer<Uint32> Function(int flags, int bytes) localAlloc;
  final Pointer<Void> Function(Pointer<Uint32> memory) localFree;
}

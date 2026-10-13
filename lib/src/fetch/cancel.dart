/// Stopping long work on request, and reporting how far it got.
library;

/// A request to stop a download or an install, checked between steps.
final class CancelToken {
  /// A token that has not been cancelled yet.
  CancelToken();

  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  /// Whether [cancel] was called.
  bool get isCancelled => _cancelled;

  /// Asks the work to stop.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = List.of(_listeners);
    _listeners.clear();
    for (final l in listeners) {
      l();
    }
  }

  /// Calls [listener] when cancelled (at once if already).
  ///
  /// Returns a function that removes [listener] again: call it when the
  /// work it would stop is done, so a token shared by many steps doesn't
  /// keep every finished one alive.
  void Function() onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return _nothing;
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// Throws [CancelledException] if cancelled.
  void check() {
    if (_cancelled) throw const CancelledException();
  }

  static void _nothing() {}
}

/// Work stopped because a [CancelToken] was cancelled.
final class CancelledException implements Exception {
  /// Stopped on request.
  const CancelledException();

  @override
  String toString() => 'Cancelled.';
}

/// Reports bytes received so far, out of [total] when known.
typedef ByteProgress = void Function(int received, int? total);

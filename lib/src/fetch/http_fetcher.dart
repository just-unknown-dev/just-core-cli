/// Fetching over HTTPS: politely, with limits, and offline when it must.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../crypto/sha256.dart';
import '../project/just_project.dart' show writeTextAtomic;
import 'cancel.dart';

/// Something that could not be fetched: the server refused, the network
/// failed, or the download broke a limit.
final class FetchException implements Exception {
  /// [message] about [uri].
  const FetchException(this.message, {this.uri, this.statusCode});

  /// What went wrong, in a sentence.
  final String message;

  /// The address it concerns.
  final Uri? uri;

  /// The HTTP status, when the server answered.
  final int? statusCode;

  @override
  String toString() => uri == null ? message : '$message ($uri)';
}

/// What a server answered.
final class FetchResponse {
  /// A response with [status], [body] and the [etag] it gave, and — for a
  /// part of a file — the [range] it holds.
  const FetchResponse(this.status, this.body, this.etag, {this.range});

  /// The HTTP status: 200; 206 for the part of a file a [ByteRange] asked
  /// for; or 304 for an unchanged cached copy.
  final int status;

  /// The bytes; empty for a 304.
  final Uint8List body;

  /// The `ETag` header, when there was one.
  final String? etag;

  /// For a 206: which bytes of the file [body] holds (both ends included)
  /// and how long the whole file is.
  final ({int start, int end, int total})? range;
}

/// A part of a file to fetch: an HTTP `Range` of bytes, so a tool can read
/// a zip's directory, or one file in it, without downloading all of it.
final class ByteRange {
  /// Bytes [start] to [end], both included.
  ByteRange(int start, int end) : _start = start, _end = end, _suffix = null {
    if (start < 0 || end < start) {
      throw ArgumentError('Not a byte range: $start-$end.');
    }
  }

  /// The last [length] bytes of the file (all of it, when it is shorter).
  ByteRange.suffix(int length) : _start = null, _end = null, _suffix = length {
    if (length < 1) throw ArgumentError('Not a byte range: the last $length.');
  }

  final int? _start;
  final int? _end;
  final int? _suffix;

  /// How many bytes it asks for, at most.
  int get length => _suffix ?? _end! - _start! + 1;

  /// The `Range` header asking for it.
  String get header =>
      _suffix != null ? 'bytes=-$_suffix' : 'bytes=$_start-$_end';

  /// What a `Content-Range` header ([contentRange]) says was sent, when it
  /// is exactly this part of the file — clipped to the file's end, as a
  /// server does; null when it is anything else.
  ({int start, int end, int total})? answeredBy(String? contentRange) {
    final m = RegExp(
      r'^bytes (\d{1,18})-(\d{1,18})/(\d{1,18})$',
    ).firstMatch(contentRange?.trim() ?? '');
    if (m == null) return null;
    final first = int.parse(m[1]!);
    final last = int.parse(m[2]!);
    final total = int.parse(m[3]!);
    if (last < first || last >= total) return null;
    final suffix = _suffix;
    final int wantFirst;
    final int wantLast;
    if (suffix != null) {
      wantFirst = total > suffix ? total - suffix : 0;
      wantLast = total - 1;
    } else {
      wantFirst = _start!;
      wantLast = _end! < total ? _end : total - 1;
    }
    if (first != wantFirst || last != wantLast) return null;
    return (start: first, end: last, total: total);
  }

  @override
  String toString() => header;
}

/// Text fetched through an on-disk copy: fresh when the server answered,
/// the cached copy when it said "unchanged" — or, [offline], when it could
/// not be reached at all or sent something unreadable.
final class CachedText {
  /// [text], [offline] when it is the cached copy after a failure ([error]).
  const CachedText(this.text, {this.offline = false, this.error});

  /// The text.
  final String text;

  /// Whether this is the cached copy because fetching failed, or what was
  /// fetched could not be read.
  final bool offline;

  /// Why fetching failed, when [offline].
  final Object? error;
}

/// Whether [uri] may be fetched: `https:`, or plain `http:` to this machine
/// only.
bool isFetchAllowed(Uri uri) {
  if (uri.scheme == 'https') return true;
  if (uri.scheme != 'http') return false;
  return uri.host == 'localhost' ||
      uri.host == '127.0.0.1' ||
      uri.host == '::1';
}

/// Fetches files over HTTPS.
///
/// - Only `https:` (plain `http:` to this machine, for testing a catalog
///   locally) — for the address asked for and for every redirect; a fetch
///   that began on `https:` never follows a redirect to `http:`.
/// - Up to 5 redirects; 20 s to connect, [timeout] of silence at most,
///   and a deadline for the whole fetch ([deadlineFor]): a server that
///   sends a byte now and then can't keep it going for ever.
///   Credentials and cookies in the headers only go to the address's own
///   origin.
/// - Waits and retries, up to 3 times, when a server says to slow down
///   (429 or 503, honouring `Retry-After`).
/// - Stops on [CancelToken], and refuses a download larger than allowed
///   before and while reading it, without reading the rest.
/// - Every failure is a [FetchException] (or [CancelledException]).
final class HttpFetcher {
  /// A fetcher announcing itself as [userAgent], making connections with
  /// [client] (tests pass a fake), and giving up on a server that stays
  /// silent for [timeout].
  HttpFetcher({
    required this.userAgent,
    HttpClient Function()? client,
    this.timeout = const Duration(seconds: 60),
  }) : _client = client ?? HttpClient.new;

  /// What it tells servers it is.
  final String userAgent;

  /// How long a server may stay silent — before answering, or between two
  /// pieces of a download — before the fetch fails.
  final Duration timeout;

  final HttpClient Function() _client;

  static const int _maxRedirects = 5;
  static const int _retries = 3;

  /// The largest body [get] reads unless told otherwise: 1 GiB. A body is
  /// held in memory, so there is always a limit.
  static const int defaultMaxBytes = 1 << 30;

  /// The largest text [getCached] reads unless told otherwise: 64 MiB.
  static const int defaultMaxTextBytes = 64 << 20;

  /// The slowest a download may average before its deadline passes:
  /// 32 KiB a second, a slow mobile connection.
  static const int minBytesPerSecond = 32 << 10;

  /// How long a fetch of up to [maxBytes] may take in all, retries and
  /// redirects included: two minutes, and as long again as [maxBytes]
  /// takes at [minBytesPerSecond].
  static Duration deadlineFor(int maxBytes) =>
      Duration(seconds: 120 + maxBytes ~/ minBytesPerSecond);

  /// GETs [uri] with [headers]. A 304 (the `If-None-Match` copy is still
  /// good) comes back with an empty body; any other status but 200 throws a
  /// [FetchException], as does a body over [maxBytes] ([defaultMaxBytes]
  /// when null), a redirect away from `https:`, a timeout and a failed
  /// connection.
  ///
  /// With [range], only that part of the file is asked for, and only a 206
  /// holding exactly that part (as its `Content-Range` says) is accepted. A
  /// server that sends the whole file instead (200) is refused before its
  /// body is read — a [FetchException] with status 200, which tells the
  /// caller to download the file in full instead.
  ///
  /// The whole fetch fails once [deadline] passes ([deadlineFor] the
  /// limit, when null).
  Future<FetchResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    ByteProgress? onProgress,
    CancelToken? cancel,
    int? maxBytes,
    ByteRange? range,
    Duration? deadline,
  }) async {
    if (!isFetchAllowed(uri)) {
      throw FetchException('Downloads must use https.', uri: uri);
    }
    final limit = maxBytes ?? defaultMaxBytes;
    final allowed = deadline ?? deadlineFor(range?.length ?? limit);
    final clock = Stopwatch()..start();
    final sent = range == null ? headers : {...headers, 'Range': range.header};
    for (var attempt = 1; ; attempt++) {
      cancel?.check();
      final left = allowed - clock.elapsed;
      if (left <= Duration.zero) throw _late(uri, allowed);
      final (response, retryAfter) = await _attempt(
        uri,
        headers: sent,
        onProgress: onProgress,
        cancel: cancel,
        maxBytes: limit,
        range: range,
        attempt: attempt,
        left: left,
        late: () => _late(uri, allowed),
      );
      if (response != null) return response;
      if (clock.elapsed + retryAfter! >= allowed) throw _late(uri, allowed);
      await _pause(retryAfter, cancel);
    }
  }

  static FetchException _late(Uri uri, Duration allowed) => FetchException(
    'The download took longer than ${_span(allowed)}, so it was stopped.',
    uri: uri,
  );

  static String _span(Duration d) => d.inSeconds < 120
      ? '${d.inSeconds} seconds'
      : '${(d.inSeconds / 60).round()} minutes';

  /// One request, with its redirects: the response, or how long to wait
  /// before asking again.
  Future<(FetchResponse?, Duration?)> _attempt(
    Uri uri, {
    required Map<String, String> headers,
    required ByteProgress? onProgress,
    required CancelToken? cancel,
    required int? maxBytes,
    required ByteRange? range,
    required int attempt,
    required Duration left,
    required FetchException Function() late,
  }) async {
    final client = _client()
      ..connectionTimeout = const Duration(seconds: 20)
      ..userAgent = userAgent;
    HttpClientRequest? current;
    final stopListening = cancel?.onCancel(() {
      current?.abort(const CancelledException());
      client.close(force: true);
    });
    var overdue = false;
    final deadline = Timer(left, () {
      overdue = true;
      current?.abort(late());
      client.close(force: true);
    });
    try {
      final response = await _open(client, uri, headers, (r) => current = r);
      // Bodies that are refused or retried are never read: closing the
      // client below drops the connection, however much was announced.
      final status = response.statusCode;
      if ((status == 429 || status == 503) && attempt <= _retries) {
        final wait = int.tryParse(
          response.headers.value(HttpHeaders.retryAfterHeader)?.trim() ?? '',
        );
        return (null, Duration(seconds: (wait ?? 1 << attempt).clamp(1, 30)));
      }
      if (status == HttpStatus.notModified) {
        return (FetchResponse(status, Uint8List(0), null), null);
      }
      ({int start, int end, int total})? part;
      if (range != null) {
        if (status == HttpStatus.ok) {
          throw FetchException(
            'The server sent the whole file, not the part asked for.',
            uri: uri,
            statusCode: status,
          );
        }
        if (status == HttpStatus.requestedRangeNotSatisfiable) {
          throw FetchException(
            'The part asked for ($range) is not in the file.',
            uri: uri,
            statusCode: status,
          );
        }
        if (status == HttpStatus.partialContent) {
          part = range.answeredBy(
            response.headers.value(HttpHeaders.contentRangeHeader),
          );
          if (part == null) {
            throw FetchException(
              'The server sent another part of the file than the one asked '
              'for ($range).',
              uri: uri,
              statusCode: status,
            );
          }
        }
      }
      if (status != HttpStatus.ok && part == null) {
        throw FetchException(
          switch (status) {
            404 => 'Not found.',
            401 || 403 => 'The server refused the download.',
            _ => 'The server answered $status.',
          },
          uri: uri,
          statusCode: status,
        );
      }
      final total = response.contentLength >= 0 ? response.contentLength : null;
      if (maxBytes != null && total != null && total > maxBytes) {
        throw FetchException('The download is larger than expected.', uri: uri);
      }
      final out = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        cancel?.check();
        out.add(chunk);
        if (maxBytes != null && out.length > maxBytes) {
          throw FetchException(
            'The download is larger than expected.',
            uri: uri,
          );
        }
        onProgress?.call(out.length, total);
      }
      if (part != null && out.length != part.end - part.start + 1) {
        throw FetchException(
          'The server sent ${out.length} bytes for a part of '
          '${part.end - part.start + 1}.',
          uri: uri,
          statusCode: status,
        );
      }
      return (
        FetchResponse(
          status,
          out.takeBytes(),
          response.headers.value(HttpHeaders.etagHeader),
          range: part,
        ),
        null,
      );
    } on Object catch (e) {
      if (e is CancelledException) rethrow;
      if (cancel?.isCancelled ?? false) throw const CancelledException();
      if (overdue) throw late();
      if (e is FetchException) rethrow;
      final message = _failureMessage(e);
      if (message == null) rethrow;
      throw FetchException(message, uri: uri);
    } finally {
      deadline.cancel();
      stopListening?.call();
      client.close(force: true);
    }
  }

  /// Sends the request and follows redirects by hand, so each address is
  /// checked by [isFetchAllowed] before anything is sent to it.
  Future<HttpClientResponse> _open(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
    void Function(HttpClientRequest request) started,
  ) async {
    var url = uri;
    var sameOrigin = true;
    for (var hop = 0; ; hop++) {
      final request = await client.getUrl(url).timeout(timeout);
      started(request);
      request.followRedirects = false;
      headers.forEach((name, value) {
        // As dart:io does: credentials and cookies stay with their origin.
        if (sameOrigin || !_sensitiveHeaders.contains(name.toLowerCase())) {
          request.headers.set(name, value);
        }
      });
      final response = await request.close().timeout(timeout);
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (!_redirectStatuses.contains(response.statusCode) ||
          location == null) {
        return response;
      }
      if (hop >= _maxRedirects) {
        throw FetchException(
          'The server redirected more than $_maxRedirects times.',
          uri: uri,
        );
      }
      final target = Uri.tryParse(location.trim());
      if (target == null) {
        throw FetchException('The server sent a broken redirect.', uri: uri);
      }
      final next = url.resolveUri(target);
      // Plain http only on a fetch that began that way (a catalog served
      // on this machine): from https, never back down — not even to this
      // machine, where a server could point it at local services.
      if (!isFetchAllowed(next) ||
          (next.scheme != 'https' && uri.scheme == 'https')) {
        throw FetchException(
          'The server redirected to a non-https address ($next), so the '
          'download was refused.',
          uri: uri,
        );
      }
      sameOrigin = sameOrigin && _isSameOrigin(next, uri);
      url = next;
      // The redirect's own body is not wanted.
      unawaited(response.listen(null).cancel().catchError((Object _) {}));
    }
  }

  String? _failureMessage(Object e) => switch (e) {
    TimeoutException() => "The server didn't answer for ${_seconds(timeout)}.",
    TlsException() =>
      'The secure connection failed (${_tlsDetail(e)}); a proxy or '
          'antivirus that inspects HTTPS can cause this.',
    SocketException() => _socketMessage(e),
    HttpException() => 'The connection failed: ${e.message}',
    IOException() => 'The download failed: $e',
    _ => null,
  };

  /// Waits [wait], or less when [cancel] is cancelled meanwhile.
  static Future<void> _pause(Duration wait, CancelToken? cancel) async {
    if (cancel == null) return Future<void>.delayed(wait);
    final done = Completer<void>();
    final timer = Timer(wait, done.complete);
    final stopListening = cancel.onCancel(() {
      timer.cancel();
      if (!done.isCompleted) done.complete();
    });
    try {
      await done.future;
    } finally {
      stopListening();
    }
    cancel.check();
  }

  /// The text at [uri], kept in [cache] (with its ETag beside it) so an
  /// unchanged file costs one small request and the last copy still reads
  /// offline. [refresh] asks again even when the copy would do. [decode]
  /// turns the bytes into text — it may take its time (fetching what the
  /// text names, say) — and may throw an [Exception] to refuse them; the
  /// cached copy is then used, as when offline.
  ///
  /// The text may be [maxBytes] long ([defaultMaxTextBytes] when null);
  /// [cancel] stops the request (a cancelled one never falls back on the
  /// cached copy).
  ///
  /// Throws what [get] or [decode] throws when there is no cached copy to
  /// fall back on.
  Future<CachedText> getCached(
    Uri uri, {
    required File? cache,
    required FutureOr<String> Function(Uint8List bytes) decode,
    bool refresh = false,
    int? maxBytes,
    CancelToken? cancel,
  }) async {
    final cached = cache == null ? null : _readCache(cache);
    final etag = refresh ? null : cached?.etag;
    final FetchResponse response;
    try {
      response = await get(
        uri,
        headers: {'If-None-Match': ?etag},
        maxBytes: maxBytes ?? defaultMaxTextBytes,
        cancel: cancel,
      );
    } on Object catch (e) {
      if (e is! FetchException && e is! IOException && e is! TimeoutException) {
        rethrow;
      }
      if (cached != null) {
        return CachedText(cached.text, offline: true, error: e);
      }
      rethrow;
    }
    if (response.status == HttpStatus.notModified && cached != null) {
      return CachedText(cached.text);
    }
    final String text;
    try {
      text = await decode(response.body);
    } on Exception catch (e) {
      // A captive portal's page, or a half-published catalog: the last good
      // copy is better than nothing.
      if (cached != null) {
        return CachedText(cached.text, offline: true, error: e);
      }
      rethrow;
    }
    if (cache != null) _writeCache(cache, text, response.etag);
    return CachedText(text);
  }
}

/// The cached text in [cache], and its ETag when the ETag file was written
/// for this very text; null when there is no readable copy.
({String text, String? etag})? _readCache(File cache) {
  try {
    if (!cache.existsSync()) return null;
    final text = cache.readAsStringSync();
    String? etag;
    final tagFile = _etagFile(cache);
    if (tagFile.existsSync()) {
      final lines = const LineSplitter().convert(tagFile.readAsStringSync());
      if (lines.length == 2 && lines[1] == _fingerprint(text)) {
        etag = lines[0];
      }
    }
    return (text: text, etag: etag);
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

/// Keeps [text] and its [etag] in [cache]. The ETag file names the text it
/// belongs to by SHA-256, so a crash, or another process, between the two
/// writes can only cost a full fetch — never pair new text with an old
/// ETag, which would keep the old text forever.
void _writeCache(File cache, String text, String? etag) {
  final tagFile = _etagFile(cache);
  try {
    writeTextAtomic(cache, text);
    if (etag != null) {
      writeTextAtomic(tagFile, '$etag\n${_fingerprint(text)}');
    } else if (tagFile.existsSync()) {
      tagFile.deleteSync();
    }
  } on FileSystemException {
    // A cache that can't be written costs a full fetch next time; the text
    // in hand is still good.
  }
}

File _etagFile(File cache) => File('${cache.path}.etag');

String _fingerprint(String text) => Sha256.hexOf(utf8.encode(text));

const Set<int> _redirectStatuses = {301, 302, 303, 307, 308};

const Set<String> _sensitiveHeaders = {
  'authorization',
  'www-authenticate',
  'proxy-authorization',
  'proxy-authenticate',
  'cookie',
  'cookie2',
};

bool _isSameOrigin(Uri a, Uri b) =>
    a.scheme == b.scheme &&
    a.host.toLowerCase() == b.host.toLowerCase() &&
    a.port == b.port;

String _seconds(Duration d) =>
    d.inSeconds == 1 ? '1 second' : '${d.inSeconds} seconds';

String _tlsDetail(TlsException e) {
  final os = e.osError?.message ?? '';
  return os.isNotEmpty ? os : e.message;
}

/// What to tell a person when a connection could not be made.
String _socketMessage(SocketException e) {
  final os = e.osError;
  // A sandboxed macOS app may not connect out without the network.client
  // entitlement — a fix the app's project has to make.
  if (Platform.isMacOS && os?.errorCode == 1) {
    return 'macOS blocked the connection. If this runs inside a sandboxed '
        'app, add com.apple.security.network.client to its entitlements '
        '(a Flutter app: macos/Runner/DebugProfile.entitlements) and restart '
        'it.';
  }
  return 'Could not connect (${os?.message ?? e.message}). Check the '
      'internet connection.';
}

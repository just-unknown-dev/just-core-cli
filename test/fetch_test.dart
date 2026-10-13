// HttpFetcher against a local server, pinned downloads, and GitHub release
// addresses.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:just_core_cli/fetch.dart';
import 'package:just_core_cli/project.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late Directory tmp;
  var hits = 0;
  var hugeSent = 0;
  final fetcher = HttpFetcher(userAgent: 'just_core_cli tests');

  setUp(() async {
    hits = 0;
    hugeSent = 0;
    tmp = Directory.systemTemp.createTempSync('just_fetch_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      hits++;
      final r = request.response;
      switch (request.uri.path) {
        case '/index.json':
          if (request.headers.value('if-none-match') == '"v1"') {
            r.statusCode = HttpStatus.notModified;
          } else {
            r.headers.set('etag', '"v1"');
            r.write('{"v": 1}');
          }
        case '/portal':
          r.write('<html>Sign in to the hotel wifi</html>');
        case '/big':
          r.add(List.filled(1000, 7));
        case '/moved':
          r.statusCode = HttpStatus.found;
          r.headers.set('location', '/index.json');
        case '/loop':
          r.statusCode = HttpStatus.found;
          r.headers.set('location', '/loop');
        case '/away':
          // Never contacted: the fetcher must refuse before connecting.
          r.statusCode = HttpStatus.movedPermanently;
          r.headers.set('location', 'http://example.com/catalog.json');
        case '/to-echo':
          r.statusCode = HttpStatus.temporaryRedirect;
          r.headers.set('location', '${request.uri.queryParameters['to']}');
        case '/echo':
          r.write(
            jsonEncode({
              'authorization': request.headers.value('authorization'),
              'x-test': request.headers.value('x-test'),
            }),
          );
        case '/busy':
          r.statusCode = HttpStatus.serviceUnavailable;
          r.headers.set('retry-after', '30');
        case '/silent':
          return; // never answers; tearDown closes it
        case '/huge':
          // Announces 64 MiB and sends it slowly, until the client leaves.
          const total = 64 * 1024 * 1024;
          r.contentLength = total;
          final chunk = Uint8List(1 << 20);
          try {
            while (hugeSent < total) {
              r.add(chunk);
              await r.flush();
              hugeSent += chunk.length;
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
          } on Object {
            return;
          }
        default:
          r.statusCode = HttpStatus.notFound;
      }
      try {
        await r.close();
      } on Object {
        // The client left.
      }
    });
  });

  tearDown(() async {
    await server.close(force: true);
    tmp.deleteSync(recursive: true);
  });

  Uri at(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');
  String text(Uint8List b) => utf8.decode(b);
  String json(Uint8List b) {
    final t = utf8.decode(b);
    if (!t.startsWith('{')) throw FormatException('Not JSON: $t');
    return t;
  }

  test('a cached copy is reused while the server says unchanged', () async {
    final cache = File('${tmp.path}/index.json');
    final first = await fetcher.getCached(
      at('/index.json'),
      cache: cache,
      decode: text,
    );
    expect(first.text, '{"v": 1}');
    final again = await fetcher.getCached(
      at('/index.json'),
      cache: cache,
      decode: text,
    );
    expect(again.text, '{"v": 1}');
    expect(again.offline, isFalse);
    expect(hits, 2);
  });

  test('an ETag written for other text is not sent', () async {
    // Two processes refreshing at once can leave one's text beside the
    // other's ETag. Sending that ETag would get a 304 and keep the wrong
    // text for good; it must cost a full fetch instead.
    final cache = File('${tmp.path}/index.json');
    await fetcher.getCached(at('/index.json'), cache: cache, decode: text);
    cache.writeAsStringSync('stale');
    final got = await fetcher.getCached(
      at('/index.json'),
      cache: cache,
      decode: text,
    );
    expect(got.text, '{"v": 1}');
    expect(cache.readAsStringSync(), '{"v": 1}');
    // An ETag file from before the fingerprint (the ETag alone) is ignored.
    File('${cache.path}.etag').writeAsStringSync('"v1"');
    cache.writeAsStringSync('stale');
    final again = await fetcher.getCached(
      at('/index.json'),
      cache: cache,
      decode: text,
    );
    expect(again.text, '{"v": 1}');
  });

  test('offline, the cached copy is read and says so', () async {
    final cache = File('${tmp.path}/index.json');
    await fetcher.getCached(at('/index.json'), cache: cache, decode: text);
    final gone = at('/index.json');
    await server.close(force: true);
    final offline = await fetcher.getCached(gone, cache: cache, decode: text);
    expect(offline.offline, isTrue);
    expect(offline.text, '{"v": 1}');
    expect(offline.error, isA<FetchException>());
    // Restart something to close in tearDown.
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  test('a body decode refuses falls back to the cached copy', () async {
    final cache = File('${tmp.path}/portal.json');
    writeTextAtomic(cache, '{"good": true}');
    final got = await fetcher.getCached(
      at('/portal'),
      cache: cache,
      decode: json,
    );
    expect(got.text, '{"good": true}');
    expect(got.offline, isTrue);
    expect(got.error, isA<FormatException>());
    // Without a copy, decode's error is the answer.
    expect(
      fetcher.getCached(
        at('/portal'),
        cache: File('${tmp.path}/none.json'),
        decode: json,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('a missing file and an oversized one are refused', () async {
    expect(
      fetcher.get(at('/nope')),
      throwsA(isA<FetchException>().having((e) => e.statusCode, 'status', 404)),
    );
    expect(
      fetcher.get(at('/big'), maxBytes: 10),
      throwsA(isA<FetchException>()),
    );
    expect((await fetcher.get(at('/big'))).body.length, 1000);
  });

  test('an oversized download is refused without reading it', () async {
    // It used to drain the whole announced body before refusing it.
    await expectLater(
      fetcher.get(at('/huge'), maxBytes: 1000),
      throwsA(isA<FetchException>()),
    );
    expect(hugeSent, lessThan(32 * 1024 * 1024));
  });

  test('only https, except to this machine', () {
    expect(isFetchAllowed(Uri.parse('https://example.com/a')), isTrue);
    expect(isFetchAllowed(Uri.parse('http://example.com/a')), isFalse);
    expect(isFetchAllowed(Uri.parse('http://localhost:8080/a')), isTrue);
    expect(isFetchAllowed(Uri.parse('file:///etc/passwd')), isFalse);
    expect(
      fetcher.get(Uri.parse('http://example.com/a')),
      throwsA(isA<FetchException>()),
    );
  });

  group('redirects', () {
    test('are followed, relative ones too', () async {
      final got = await fetcher.get(at('/moved'));
      expect(text(got.body), '{"v": 1}');
      final cached = await fetcher.getCached(
        at('/moved'),
        cache: File('${tmp.path}/moved.json'),
        decode: text,
      );
      expect(cached.text, '{"v": 1}');
    });

    test('to a non-https address are refused, cached or not', () async {
      final refused = throwsA(
        isA<FetchException>().having(
          (e) => e.message,
          'message',
          contains('non-https'),
        ),
      );
      expect(fetcher.get(at('/away')), refused);
      expect(
        fetcher.getCached(at('/away'), cache: null, decode: text),
        refused,
      );
    });

    test('from https never go to http, not even on this machine', () async {
      final asked = <Uri>[];
      final local = at('/index.json');
      final secure = HttpFetcher(
        userAgent: 'just_core_cli tests',
        client: () => _RedirectingClient('$local', asked),
      );
      final start = Uri.parse('https://catalog.example/index.json');
      await expectLater(
        secure.get(start),
        throwsA(
          isA<FetchException>().having(
            (e) => e.message,
            'message',
            contains('non-https'),
          ),
        ),
      );
      expect(asked, [start]);
      expect(hits, 0, reason: 'the local server is never asked');
      // From this machine's plain http, this machine's plain http is fine.
      expect(text((await fetcher.get(at('/moved'))).body), '{"v": 1}');
    });

    test('stop after five', () {
      expect(
        fetcher.get(at('/loop')),
        throwsA(
          isA<FetchException>().having(
            (e) => e.message,
            'message',
            contains('more than 5'),
          ),
        ),
      );
    });

    test('carry credentials only within their origin', () async {
      final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => other.close(force: true));
      other.listen((request) {
        request.response
          ..write(
            jsonEncode({
              'authorization': request.headers.value('authorization'),
              'x-test': request.headers.value('x-test'),
            }),
          )
          ..close();
      });
      const headers = {'Authorization': 'Bearer secret', 'X-Test': 'kept'};
      Future<Map<String, Object?>> via(String to) async {
        final got = await fetcher.get(
          at('/to-echo?to=${Uri.encodeQueryComponent(to)}'),
          headers: headers,
        );
        return jsonDecode(text(got.body)) as Map<String, Object?>;
      }

      expect(await via(at('/echo').toString()), {
        'authorization': 'Bearer secret',
        'x-test': 'kept',
      });
      // Another port is another origin.
      expect(await via('http://127.0.0.1:${other.port}/echo'), {
        'authorization': null,
        'x-test': 'kept',
      });
    });
  });

  group('failures are FetchExceptions', () {
    test('a server that never answers', () async {
      final quick = HttpFetcher(
        userAgent: 'just_core_cli tests',
        timeout: const Duration(seconds: 1),
      );
      await expectLater(
        quick.get(at('/silent')),
        throwsA(
          isA<FetchException>().having(
            (e) => e.message,
            'message',
            contains("didn't answer"),
          ),
        ),
      );
    });

    test('a secure connection that fails', () async {
      // TLS to a plain HTTP port: a HandshakeException underneath.
      await expectLater(
        fetcher.get(Uri.parse('https://127.0.0.1:${server.port}/index.json')),
        throwsA(
          isA<FetchException>().having(
            (e) => e.message,
            'message',
            contains('secure connection'),
          ),
        ),
      );
    });
  });

  group('cancelling', () {
    test('before starting', () {
      final cancel = CancelToken()..cancel();
      expect(
        fetcher.get(at('/big'), cancel: cancel),
        throwsA(isA<CancelledException>()),
      );
    });

    test('while waiting for an answer', () async {
      final cancel = CancelToken();
      Timer(const Duration(milliseconds: 200), cancel.cancel);
      final watch = Stopwatch()..start();
      await expectLater(
        fetcher.get(at('/silent'), cancel: cancel),
        throwsA(isA<CancelledException>()),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test("while waiting out a server's Retry-After", () async {
      final cancel = CancelToken();
      Timer(const Duration(milliseconds: 300), cancel.cancel);
      final watch = Stopwatch()..start();
      await expectLater(
        fetcher.get(at('/busy'), cancel: cancel),
        throwsA(isA<CancelledException>()),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test('a removed listener is not called', () {
      final cancel = CancelToken();
      var called = 0;
      final remove = cancel.onCancel(() => called++);
      cancel.onCancel(() => called += 10);
      remove();
      cancel.cancel();
      expect(called, 10);
      // After cancelling, a listener runs at once.
      cancel.onCancel(() => called += 100);
      expect(called, 110);
    });
  });

  group('pinned downloads', () {
    final bytes = Uint8List.fromList(utf8.encode('archive'));
    final sha = Sha256.hexOf(bytes);

    test('pass when size and SHA-256 match', () {
      checkPinned(bytes, size: bytes.length, sha256: sha, what: 'x 1.0.0');
    });

    test('are refused when either differs', () {
      expect(
        () => checkPinned(bytes, size: 3, sha256: sha, what: 'x 1.0.0'),
        throwsA(isA<DownloadException>()),
      );
      expect(
        () => checkPinned(
          bytes,
          size: bytes.length,
          sha256: '0' * 64,
          what: 'x 1.0.0',
        ),
        throwsA(
          isA<DownloadException>().having(
            (e) => e.message,
            'message',
            contains('SHA-256'),
          ),
        ),
      );
    });

    test('are cached under their SHA-256, and a damaged copy is dropped', () {
      final cache = DownloadCache(tmp.path);
      cache.putArchive(sha, bytes);
      expect(cache.archive(sha), bytes);
      File('${tmp.path}/archives/$sha.zip').writeAsStringSync('tampered');
      expect(cache.archive(sha), isNull);
      expect(File('${tmp.path}/archives/$sha.zip').existsSync(), isFalse);
    });

    test('the cache takes only a SHA-256 as a name', () {
      final cache = DownloadCache('${tmp.path}/cache');
      for (final name in ['../../outside', 'A' * 64, '0' * 63, '']) {
        expect(() => cache.putArchive(name, bytes), throwsArgumentError);
        expect(() => cache.archive(name), throwsArgumentError);
      }
      expect(File('${tmp.path}/outside.zip').existsSync(), isFalse);
    });

    test('several writers of one archive at once all succeed', () async {
      // Two installs (or the editor and the CLI) caching the same version.
      final dir = '${tmp.path}/shared';
      final results = await Future.wait([
        for (var i = 0; i < 3; i++) _cacheInIsolate(dir),
      ]);
      expect(results.expand((p) => p), isEmpty);
    });
  });

  group('GitHubRepo', () {
    test('reads the usual ways of writing a repository', () {
      for (final text in [
        'https://github.com/just-unknown-dev/just-art.git',
        'https://www.github.com/just-unknown-dev/just-art/',
        'HTTPS://GitHub.com/just-unknown-dev/just-art',
        'github.com/just-unknown-dev/just-art',
        'www.github.com/just-unknown-dev/just-art',
        'just-unknown-dev/just-art',
      ]) {
        expect(
          GitHubRepo.tryParse(text),
          const GitHubRepo('just-unknown-dev', 'just-art'),
          reason: text,
        );
      }
    });

    test('refuses other hosts and paths', () {
      for (final text in [
        'https://gitlab.com/a/b',
        'https://github.com/a/b/c',
        'a/../b',
        'a',
        'https://evil.example/a/b',
        // A one-word host is not an owner.
        'https://localhost/foo',
        'http://example/x',
        'https://github.com.evil.example/a/b',
        'www.evil.example/a/b',
      ]) {
        expect(GitHubRepo.tryParse(text), isNull, reason: text);
      }
    });

    test('names release files without the API', () {
      const repo = GitHubRepo('o', 'r');
      expect(
        '${repo.manifest()}',
        'https://github.com/o/r/releases/latest/download/just_release.json',
      );
      expect(
        '${repo.releaseFile('r-1.0.0.zip', tag: 'v1.0.0')}',
        'https://github.com/o/r/releases/download/v1.0.0/r-1.0.0.zip',
      );
      expect(
        '${repo.releaseFile('r.zip', tag: 'v1.0.0+build.2')}',
        'https://github.com/o/r/releases/download/v1.0.0+build.2/r.zip',
      );
    });

    test('refuses a tag or file that would lead out of the repository', () {
      const repo = GitHubRepo('trusted', 'pkg');
      for (final tag in [
        '../../../../evil/x/releases/download/v1',
        '..',
        '.',
        'v1/../../x',
        'v1?x=1',
        '',
      ]) {
        expect(
          () => repo.releaseFile('a.zip', tag: tag),
          throwsArgumentError,
          reason: tag,
        );
        expect(() => repo.manifest(tag: tag), throwsArgumentError);
      }
      for (final file in ['..', '../x.zip', 'a/b.zip', 'a b.zip', '']) {
        expect(
          () => repo.releaseFile(file, tag: 'v1'),
          throwsArgumentError,
          reason: file,
        );
        expect(() => repo.releaseFile(file), throwsArgumentError);
      }
    });
  });
}

/// A client that answers every address with a redirect to [location],
/// noting each address asked for in [asked]: a remote https server, without
/// a certificate.
final class _RedirectingClient implements HttpClient {
  _RedirectingClient(this.location, this.asked);

  final String location;
  final List<Uri> asked;

  @override
  Duration? connectionTimeout;

  @override
  String? userAgent;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    asked.add(url);
    return _Request(location);
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Request implements HttpClientRequest {
  _Request(this.location);

  final String location;

  @override
  bool followRedirects = true;

  @override
  final HttpHeaders headers = _Headers(const {});

  @override
  Future<HttpClientResponse> close() async => _Response(location);

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.location);

  final String location;

  @override
  int get statusCode => HttpStatus.found;

  @override
  int get contentLength => 0;

  @override
  HttpHeaders get headers => _Headers({'location': location});

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => const Stream<List<int>>.empty().listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Headers implements HttpHeaders {
  _Headers(this._values);

  final Map<String, String> _values;

  @override
  String? value(String name) => _values[name.toLowerCase()];

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Puts and reads one archive 25 times in a new isolate, as one of several
/// writers sharing [dir]; what went wrong, if anything.
Future<List<String>> _cacheInIsolate(String dir) => Isolate.run(() {
  final data = Uint8List(1 << 20);
  for (var j = 0; j < data.length; j++) {
    data[j] = (j * 7919) & 0xFF;
  }
  final sha = Sha256.hexOf(data);
  final cache = DownloadCache(dir);
  final problems = <String>[];
  for (var k = 0; k < 25; k++) {
    try {
      cache.putArchive(sha, data);
      final back = cache.archive(sha);
      if (back != null && back.length != data.length) {
        problems.add('short read');
      }
    } on Object catch (e) {
      problems.add('$e');
    }
  }
  return problems;
});

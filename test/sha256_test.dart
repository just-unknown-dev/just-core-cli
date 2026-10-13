// SHA-256 against the FIPS 180-4 / NIST test vectors, and the streaming
// API against one-shot hashing.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_core_cli/project.dart';
import 'package:test/test.dart';

void main() {
  group('known digests', () {
    test('empty input', () {
      expect(
        Sha256.hexOf(const []),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('"abc"', () {
      expect(
        Sha256.hexOf(ascii.encode('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('the two-block NIST message', () {
      expect(
        Sha256.hexOf(
          ascii.encode(
            'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
          ),
        ),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });

    test('the four-block NIST message', () {
      expect(
        Sha256.hexOf(
          ascii.encode(
            'abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn'
            'hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu',
          ),
        ),
        'cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1',
      );
    });

    test('one million "a"s', () {
      expect(
        Sha256.hexOf(Uint8List(1000000)..fillRange(0, 1000000, 0x61)),
        'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
      );
    });
  });

  test('padding edges: 55, 56, 63, 64 and 65 bytes', () {
    // Lengths around the 56-byte padding boundary; Python's hashlib gives
    // these values.
    const expected = {
      55: '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318',
      56: 'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a',
      63: '7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34',
      64: 'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb',
      65: '635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0',
    };
    for (final e in expected.entries) {
      expect(
        Sha256.hexOf(Uint8List(e.key)..fillRange(0, e.key, 0x61)),
        e.value,
        reason: '${e.key} bytes',
      );
    }
  });

  test('pieces of any size give the same digest', () {
    final data = Uint8List.fromList(List.generate(10007, (i) => i * 31 & 0xFF));
    final whole = Sha256.hexOf(data);
    for (final step in [1, 3, 63, 64, 65, 1000]) {
      final hash = Sha256();
      for (var i = 0; i < data.length; i += step) {
        hash.add(
          data.sublist(i, i + step > data.length ? data.length : i + step),
        );
      }
      expect(Sha256.hex(hash.close()), whole, reason: 'step $step');
    }
    // A plain List<int> takes the copying path.
    expect(Sha256.hex((Sha256()..add(data.toList())).close()), whole);
  });

  test('matches certutil on this machine for a random file', () async {
    if (!Platform.isWindows) return;
    final dir = Directory.systemTemp.createTempSync('sha');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/blob.bin')
      ..writeAsBytesSync(List.generate(123457, (i) => (i * 7919) & 0xFF));
    final result = await Process.run('certutil', [
      '-hashfile',
      file.path,
      'SHA256',
    ]);
    if (result.exitCode != 0) return;
    final line = (result.stdout as String)
        .split('\n')
        .map((l) => l.trim().replaceAll(' ', ''))
        .firstWhere((l) => RegExp(r'^[0-9a-f]{64}$').hasMatch(l));
    expect(Sha256.hexOf(file.readAsBytesSync()), line);
  });

  test('a closed hash refuses more', () {
    final hash = Sha256()..close();
    expect(() => hash.add([1]), throwsStateError);
    expect(hash.close, throwsStateError);
  });

  test('isSha256Hex', () {
    expect(isSha256Hex('a' * 64), isTrue);
    expect(isSha256Hex('A' * 64), isFalse);
    expect(isSha256Hex('a' * 63), isFalse);
  });
}

/// SHA-256 (FIPS 180-4), the hash every download is pinned with.
library;

import 'dart:typed_data';

/// A running SHA-256 hash: [add] the data in pieces, then [close].
///
/// ```dart
/// final hash = Sha256()..add(part1)..add(part2);
/// final digest = hash.close(); // 32 bytes
/// ```
///
/// Pure Dart: the same digest on native, web and Wasm.
final class Sha256 {
  /// A hash with nothing added yet.
  Sha256();

  /// The 32-byte digest of [data].
  static Uint8List of(List<int> data) => (Sha256()..add(data)).close();

  /// The digest of [data] as 64 lowercase hex digits.
  static String hexOf(List<int> data) => hex(of(data));

  /// [bytes] as lowercase hex digits, two per byte.
  static String hex(List<int> bytes) {
    final out = StringBuffer();
    for (final b in bytes) {
      out.write(_digits[(b >> 4) & 0xF]);
      out.write(_digits[b & 0xF]);
    }
    return out.toString();
  }

  final Uint32List _h = Uint32List.fromList(const [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);
  final Uint8List _block = Uint8List(64);
  final Uint32List _w = Uint32List(64);
  int _filled = 0;

  // Bytes added so far, kept as two parts so the count stays exact on the
  // web, where integers are doubles.
  int _lengthLow = 0; // below 2^32
  int _lengthHigh = 0; // multiples of 2^32
  bool _closed = false;

  /// Adds [data] to the hash.
  ///
  /// Throws [StateError] after [close].
  void add(List<int> data) {
    if (_closed) throw StateError('The hash is closed.');
    _count(data.length);
    var i = 0;
    final n = data.length;
    if (_filled > 0) {
      while (_filled < 64 && i < n) {
        _block[_filled++] = data[i++];
      }
      if (_filled < 64) return;
      _compress(_block, 0);
      _filled = 0;
    }
    if (data is Uint8List) {
      while (n - i >= 64) {
        _compress(data, i);
        i += 64;
      }
    } else {
      while (n - i >= 64) {
        _block.setRange(0, 64, data, i);
        _compress(_block, 0);
        i += 64;
      }
    }
    while (i < n) {
      _block[_filled++] = data[i++];
    }
  }

  /// The 32-byte digest of everything added. The hash takes no more data.
  Uint8List close() {
    if (_closed) throw StateError('The hash is closed.');
    _closed = true;
    // Bit length, as a 64-bit big-endian number.
    final bitsLow = (_lengthLow * 8) % 0x100000000;
    final bitsHigh =
        (_lengthHigh * 8 + (_lengthLow * 8) ~/ 0x100000000) % 0x100000000;
    _block[_filled++] = 0x80;
    if (_filled > 56) {
      _block.fillRange(_filled, 64, 0);
      _compress(_block, 0);
      _filled = 0;
    }
    _block.fillRange(_filled, 56, 0);
    _putUint32(_block, 56, bitsHigh);
    _putUint32(_block, 60, bitsLow);
    _compress(_block, 0);
    final out = Uint8List(32);
    for (var i = 0; i < 8; i++) {
      _putUint32(out, i * 4, _h[i]);
    }
    return out;
  }

  void _count(int bytes) {
    final low = _lengthLow + bytes;
    _lengthHigh += low ~/ 0x100000000;
    _lengthLow = low % 0x100000000;
  }

  void _compress(List<int> data, int offset) {
    final w = _w;
    for (var t = 0; t < 16; t++) {
      final j = offset + t * 4;
      w[t] =
          ((data[j] & 0xFF) << 24) |
          ((data[j + 1] & 0xFF) << 16) |
          ((data[j + 2] & 0xFF) << 8) |
          (data[j + 3] & 0xFF);
    }
    for (var t = 16; t < 64; t++) {
      final x = w[t - 15];
      final y = w[t - 2];
      final s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >>> 3);
      final s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >>> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & _mask;
    }
    var a = _h[0], b = _h[1], c = _h[2], d = _h[3];
    var e = _h[4], f = _h[5], g = _h[6], h = _h[7];
    for (var t = 0; t < 64; t++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & _mask) & g);
      final t1 = (h + s1 + ch + _k[t] + w[t]) & _mask;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & _mask;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & _mask;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & _mask;
    }
    _h[0] = (_h[0] + a) & _mask;
    _h[1] = (_h[1] + b) & _mask;
    _h[2] = (_h[2] + c) & _mask;
    _h[3] = (_h[3] + d) & _mask;
    _h[4] = (_h[4] + e) & _mask;
    _h[5] = (_h[5] + f) & _mask;
    _h[6] = (_h[6] + g) & _mask;
    _h[7] = (_h[7] + h) & _mask;
  }
}

/// Whether [text] is a SHA-256 digest written as 64 lowercase hex digits.
bool isSha256Hex(String text) => _sha256Hex.hasMatch(text);

final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

const String _digits = '0123456789abcdef';

const int _mask = 0xFFFFFFFF;

int _rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & _mask;

void _putUint32(Uint8List out, int offset, int value) {
  out[offset] = (value >>> 24) & 0xFF;
  out[offset + 1] = (value >>> 16) & 0xFF;
  out[offset + 2] = (value >>> 8) & 0xFF;
  out[offset + 3] = value & 0xFF;
}

const List<int> _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, //
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

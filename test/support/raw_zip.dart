// Builds ZIP archives field by field, so tests can make the broken and
// hostile ones no ordinary tool would write.
import 'dart:convert';
import 'dart:typed_data';

import 'package:just_deflate/just_deflate.dart';

/// One entry for [rawZip]. Every field a hostile archive might lie about
/// can be set.
class RawEntry {
  RawEntry(
    this.name,
    List<int> data, {
    this.method = 8,
    this.flags = 0x0800,
    this.madeBy = 20,
    this.externalAttributes = 0,
    this.crc,
    this.size,
    this.compressedSize,
    this.localName,
    this.offset,
    this.startDisk = 0,
  }) : data = Uint8List.fromList(data);

  /// The name, as bytes are written (UTF-8 of this string).
  final String name;
  final Uint8List data;
  final int method;
  final int flags;
  final int madeBy;
  final int externalAttributes;
  final int? crc;
  final int? size;
  final int? compressedSize;

  /// The name the local header claims, when it should differ.
  final String? localName;

  /// Points the central directory at this offset instead of the real one.
  final int? offset;
  final int startDisk;
}

/// Unix mode bits in the external attributes, as Info-ZIP writes them.
int unixAttributes(int mode) => (mode << 16) & 0xFFFFFFFF;

/// An archive holding [entries]. [count], [cdOffset] and [cdSize] override
/// the end record; [comment] is the archive comment.
Uint8List rawZip(
  List<RawEntry> entries, {
  int? count,
  int? cdOffset,
  int? cdSize,
  int disk = 0,
  String comment = '',
  bool zip64Locator = false,
}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  for (final e in entries) {
    final body = e.method == 8 ? const DeflateCodec().encode(e.data) : e.data;
    final name = utf8.encode(e.name);
    final local = utf8.encode(e.localName ?? e.name);
    final offset = out.length;
    _u32(out, 0x04034b50);
    _u16(out, 20);
    _u16(out, e.flags);
    _u16(out, e.method);
    _u16(out, 0);
    _u16(out, 0x21);
    _u32(out, e.crc ?? crc32(e.data));
    _u32(out, e.compressedSize ?? body.length);
    _u32(out, e.size ?? e.data.length);
    _u16(out, local.length);
    _u16(out, 0);
    out
      ..add(local)
      ..add(body);

    _u32(central, 0x02014b50);
    _u16(central, e.madeBy);
    _u16(central, 20);
    _u16(central, e.flags);
    _u16(central, e.method);
    _u16(central, 0);
    _u16(central, 0x21);
    _u32(central, e.crc ?? crc32(e.data));
    _u32(central, e.compressedSize ?? body.length);
    _u32(central, e.size ?? e.data.length);
    _u16(central, name.length);
    _u16(central, 0);
    _u16(central, 0);
    _u16(central, e.startDisk);
    _u16(central, 0);
    _u32(central, e.externalAttributes);
    _u32(central, e.offset ?? offset);
    central.add(name);
  }
  final cd = central.takeBytes();
  final cdAt = out.length;
  out.add(cd);
  if (zip64Locator) {
    _u32(out, 0x07064b50);
    _u32(out, 0);
    _u32(out, 0);
    _u32(out, 0);
    _u32(out, 1);
  }
  final commentBytes = utf8.encode(comment);
  _u32(out, 0x06054b50);
  _u16(out, disk);
  _u16(out, disk);
  _u16(out, count ?? entries.length);
  _u16(out, count ?? entries.length);
  _u32(out, cdSize ?? cd.length);
  _u32(out, cdOffset ?? cdAt);
  _u16(out, commentBytes.length);
  out.add(commentBytes);
  return out.takeBytes();
}

void _u16(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);

void _u32(BytesBuilder b, int v) =>
    b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

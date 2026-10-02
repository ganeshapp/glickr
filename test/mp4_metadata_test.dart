import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:glickr/core/services/mp4_metadata.dart';

/// An ISO BMFF box: 32-bit size, four-character type, body - or, with [wide],
/// size 1 and a 64-bit size after the type.
Uint8List box(String type, List<List<int>> body, {bool wide = false}) {
  final contents = body.expand((b) => b).toList();
  final size = contents.length + (wide ? 16 : 8);
  final out =
      BytesBuilder()
        ..add((ByteData(4)..setUint32(0, wide ? 1 : size)).buffer.asUint8List())
        ..add(type.codeUnits);
  if (wide) out.add((ByteData(8)..setUint64(0, size)).buffer.asUint8List());
  return (out..add(contents)).toBytes();
}

final ftyp = box('ftyp', ['isom'.codeUnits]);
final mvhd = box('mvhd', [List.filled(100, 0)]);
final gps = box('©xyz', ['+12.9716+077.5946/'.codeUnits]);
final mdat = box('mdat', [List.filled(64, 7)]);

/// [bytes] with the four type bytes of the box at [offset] replaced by `free`.
Uint8List freed(Uint8List bytes, int offset) =>
    Uint8List.fromList(bytes)
      ..setRange(offset + 4, offset + 8, 'free'.codeUnits);

void main() {
  late File file;
  setUp(() async {
    final tmp = await Directory.systemTemp.createTemp('glickr_mp4');
    addTearDown(() => tmp.delete(recursive: true));
    file = File(p.join(tmp.path, 'clip.mp4'));
  });

  test(
    "Android's moov/udta/©xyz becomes free and nothing else moves",
    () async {
      final clip = Uint8List.fromList([
        ...ftyp,
        ...box('moov', [
          mvhd,
          box('udta', [gps]),
        ]),
        ...mdat,
      ]);
      file.writeAsBytesSync(clip);

      expect(await stripMp4Metadata(file), 1);

      final udtaAt = ftyp.length + 8 + mvhd.length;
      expect(file.readAsBytesSync(), freed(clip, udtaAt));
    },
  );

  test("AVFoundation's moov/meta goes too, under a 64-bit moov size", () async {
    final meta = box('meta', [List.filled(40, 1)]);
    final clip = Uint8List.fromList([
      ...ftyp,
      ...mdat,
      ...box('moov', [
        mvhd,
        meta,
        box('udta', [gps]),
      ], wide: true),
    ]);
    file.writeAsBytesSync(clip);

    expect(await stripMp4Metadata(file), 2);

    final metaAt = ftyp.length + mdat.length + 16 + mvhd.length;
    final udtaAt = metaAt + meta.length;
    expect(file.readAsBytesSync(), freed(freed(clip, metaAt), udtaAt));
  });

  test('a clip with nothing to strip is untouched', () async {
    final clip = Uint8List.fromList([
      ...ftyp,
      ...box('moov', [
        mvhd,
        box('trak', [
          box('udta', [gps]),
        ]),
      ]),
      ...mdat,
    ]);
    file.writeAsBytesSync(clip);

    // Track-level user data is out of scope; only moov's own children.
    expect(await stripMp4Metadata(file), 0);
    expect(file.readAsBytesSync(), clip);
  });

  test('doubt means a throw and an unchanged file', () async {
    final truncated = Uint8List.fromList([
      ...ftyp,
      ...box('moov', [
        mvhd,
        box('udta', [gps]),
      ]).sublist(0, 30),
    ]);
    final noFtyp = Uint8List.fromList([
      ...box('moov', [
        mvhd,
        box('udta', [gps]),
      ]),
    ]);
    // A 64-bit moov size that wraps `start + size` negative: the one range
    // check that overflow could slip past, which then seeks before 0.
    final wrapping = Uint8List.fromList([
      ...ftyp,
      ...(ByteData(16)
            ..setUint32(0, 1)
            ..setUint64(8, 0x7FFFFFFFFFFFFFF4))
          .buffer
          .asUint8List(),
    ])..setRange(ftyp.length + 4, ftyp.length + 8, 'moov'.codeUnits);
    for (final clip in [
      truncated,
      noFtyp,
      wrapping,
      Uint8List.fromList([1, 2, 3]),
    ]) {
      file.writeAsBytesSync(clip);
      await expectLater(stripMp4Metadata(file), throwsFormatException);
      expect(file.readAsBytesSync(), clip);
    }
  });
}

import 'dart:io';
import 'dart:typed_data';

/// Removes the metadata video_compress carries over from the source clip.
///
/// Android's muxer rewrites the GPS fix as `moov/udta/©xyz`; AVFoundation
/// copies location and camera keys into `moov/meta` and `moov/udta`. Rather
/// than rebuild the file, every `udta` and `meta` box directly inside `moov`
/// is renamed to `free`, in place: only its four type bytes change, every
/// size and chunk offset in the file stays as it was, and players skip `free`
/// boxes by definition. So this cannot corrupt a clip. The one thing it can do
/// wrong is doubt the file, in which case it throws [FormatException] having
/// written nothing.
///
/// Returns how many boxes were renamed.
Future<int> stripMp4Metadata(File file) async {
  // append: read and write without truncating; every op sets its position.
  final raf = await file.open(mode: FileMode.append);
  try {
    final top = await _boxes(raf, 0, await raf.length());
    if (top.isEmpty || top.first.type != 'ftyp') {
      throw const FormatException('not an MP4: no ftyp box');
    }
    final moov = top.where((b) => b.type == 'moov').toList();
    if (moov.length != 1) {
      throw FormatException('${moov.length} moov boxes');
    }
    var renamed = 0;
    for (final box in await _boxes(raf, moov.single.body, moov.single.end)) {
      if (box.type != 'udta' && box.type != 'meta') continue;
      await raf.setPosition(box.start + 4);
      await raf.writeFrom('free'.codeUnits);
      renamed++;
    }
    return renamed;
  } finally {
    await raf.close();
  }
}

class _Box {
  final String type;
  final int start;

  /// Where the contents begin: 8 bytes in, or 16 after a 64-bit size.
  final int body;
  final int end;
  const _Box(this.type, this.start, this.body, this.end);
}

/// The boxes laid end to end in `[start, end)`: a 32-bit size and a
/// four-character type each, with a 64-bit size following when the 32-bit one
/// is 1, and "to the end" when it is 0.
Future<List<_Box>> _boxes(RandomAccessFile raf, int start, int end) async {
  final boxes = <_Box>[];
  var at = start;
  while (at < end) {
    await raf.setPosition(at);
    final header = await raf.read(16);
    if (header.length < 8) throw const FormatException('truncated box');
    final data = ByteData.sublistView(header);
    var size = data.getUint32(0);
    var body = at + 8;
    if (size == 1) {
      if (header.length < 16) throw const FormatException('truncated box');
      size = data.getUint64(8);
      body = at + 16;
    } else if (size == 0) {
      size = end - at;
    }
    if (size < body - at || at + size > end) {
      throw const FormatException('box size out of range');
    }
    boxes.add(_Box(String.fromCharCodes(header, 4, 8), at, body, at + size));
    at += size;
  }
  return boxes;
}

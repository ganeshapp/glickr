import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glickr/core/utils/album_captions.dart';

void main() {
  group('parsing', () {
    test('reads the bare-string form a human would type', () {
      final captions = AlbumCaptions.parse('trip', '''
{
  "version": 1,
  "album": "trip",
  "pad": 4,
  "next": 3,
  "items": {
    "0001.jpg": "6am start, still dark",
    "0002.jpg": "Puncture #1"
  }
}
''');
      expect(captions.captionFor('0001.jpg'), '6am start, still dark');
      expect(captions.captionFor('0002.jpg'), 'Puncture #1');
      expect(captions.next, 3);
      expect(captions.pad, 4);
    });

    test('reads the object form and its caption key', () {
      final captions = AlbumCaptions.parse(
        'trip',
        '{"items":{"0001.jpg":{"caption":"Summit","taken":"2019-03-02"}}}',
      );
      expect(captions.captionFor('0001.jpg'), 'Summit');
    });

    test('returns empty rather than throwing on mangled JSON', () {
      // Losing captions to a bad hand-edit is acceptable; losing the ability
      // to open the album is not.
      expect(AlbumCaptions.parse('trip', '{not json').items, isEmpty);
      expect(AlbumCaptions.parse('trip', '').items, isEmpty);
      expect(AlbumCaptions.parse('trip', null).items, isEmpty);
      expect(AlbumCaptions.parse('trip', '[]').items, isEmpty);
    });

    test('ignores entries whose value is neither a string nor an object', () {
      final captions = AlbumCaptions.parse(
        'trip',
        '{"items":{"a.jpg":42,"b.jpg":"ok"}}',
      );
      expect(captions.items.containsKey('a.jpg'), isFalse);
      expect(captions.captionFor('b.jpg'), 'ok');
    });
  });

  group('encoding', () {
    test('emits exactly one line per item', () {
      // This is the property git's line-based merge depends on: two devices
      // captioning different photos must not conflict.
      final captions = AlbumCaptions.parse(
        'trip',
        '{"items":{"0002.jpg":{"caption":"b","taken":"x"},"0001.jpg":"a"}}',
      );
      final lines = captions.encode().split('\n');
      final itemLines = lines.where((l) => l.startsWith('    "')).toList();
      expect(itemLines.length, 2);
      for (final line in itemLines) {
        expect(line.contains('\n'), isFalse);
      }
    });

    test('round-trips through a JSON parser', () {
      final captions = AlbumCaptions.empty(
        'trip',
      ).withCaption('0001.jpg', 'hello').withNext(9);
      final decoded = jsonDecode(captions.encode()) as Map<String, dynamic>;
      expect(decoded['album'], 'trip');
      expect(decoded['next'], 9);
      expect((decoded['items'] as Map)['0001.jpg'], 'hello');
    });

    test('sorts keys, so two devices produce byte-identical files', () {
      final captions = AlbumCaptions.empty('trip')
          .withCaption('0003.jpg', 'c')
          .withCaption('0001.jpg', 'a')
          .withCaption('0002.jpg', 'b');
      final body = captions.encode();
      expect(
        body.indexOf('"0001.jpg"') < body.indexOf('"0002.jpg"'),
        isTrue,
      );
      expect(
        body.indexOf('"0002.jpg"') < body.indexOf('"0003.jpg"'),
        isTrue,
      );
    });

    test('preserves top-level keys a human added', () {
      // Someone adds "credits" by hand; the next app write must not eat it.
      final captions = AlbumCaptions.parse(
        'trip',
        '{"credits":"Photos by G","items":{"0001.jpg":"a"}}',
      );
      final decoded =
          jsonDecode(captions.withCaption('0002.jpg', 'b').encode()) as Map;
      expect(decoded['credits'], 'Photos by G');
    });

    test('preserves extra keys inside an object-form entry', () {
      final captions = AlbumCaptions.parse(
        'trip',
        '{"items":{"0001.jpg":{"caption":"old","taken":"2019-03-02"}}}',
      ).withCaption('0001.jpg', 'new');
      final entry =
          (jsonDecode(captions.encode()) as Map)['items']['0001.jpg'] as Map;
      expect(entry['caption'], 'new');
      expect(entry['taken'], '2019-03-02');
    });
  });

  group('caption mutation', () {
    test('clearing a bare-string caption removes the entry entirely', () {
      final captions = AlbumCaptions.empty(
        'trip',
      ).withCaption('0001.jpg', 'a').withCaption('0001.jpg', '');
      expect(captions.items.containsKey('0001.jpg'), isFalse);
    });

    test('clearing an object-form caption keeps its other data', () {
      final captions = AlbumCaptions.parse(
        'trip',
        '{"items":{"0001.jpg":{"caption":"a","taken":"x"}}}',
      ).withCaption('0001.jpg', null);
      expect(captions.captionFor('0001.jpg'), '');
      expect((captions.items['0001.jpg'] as Map)['taken'], 'x');
    });

    test('a whitespace-only caption counts as no caption', () {
      final captions = AlbumCaptions.empty(
        'trip',
      ).withCaption('0001.jpg', '   ');
      expect(captions.items, isEmpty);
    });

    test('trims stored captions', () {
      expect(
        AlbumCaptions.empty('trip').withCaption('a.jpg', '  hi  ').captionFor('a.jpg'),
        'hi',
      );
    });
  });

  group('filename reuse defences', () {
    test('next is monotonic and a deletion never lowers it', () {
      // The core protection: a deleted 0003.jpg must never have its number
      // handed to a later upload, or the new photo inherits a dead caption.
      var captions = AlbumCaptions.empty('trip').withNext(10);
      expect(captions.next, 10);

      captions = captions.withoutFiles({'0003.jpg'});
      expect(captions.next, 10);

      captions = captions.withNext(4);
      expect(captions.next, 10, reason: 'withNext must never lower the mark');
    });

    test('withoutFiles drops the captions of removed files', () {
      final captions = AlbumCaptions.empty('trip')
          .withCaption('0001.jpg', 'a')
          .withCaption('0002.jpg', 'b')
          .withoutFiles({'0001.jpg'});
      expect(captions.items.keys, ['0002.jpg']);
    });

    test('withoutOrphans clears entries whose file no longer exists', () {
      // The backstop for a file deleted through github.com, where glickr never
      // saw the removal.
      final captions = AlbumCaptions.empty('trip')
          .withCaption('0001.jpg', 'a')
          .withCaption('0009.jpg', 'ghost')
          .withoutOrphans({'0001.jpg'});
      expect(captions.items.keys, ['0001.jpg']);
    });

    test('writing to a filename clobbers any stale entry under that key', () {
      final captions = AlbumCaptions.empty(
        'trip',
      ).withCaption('0003.jpg', 'the old photo').withCaption('0003.jpg', 'the new one');
      expect(captions.captionFor('0003.jpg'), 'the new one');
    });
  });

  group('renaming', () {
    test('follows a file to its new name, as a cover swap does', () {
      final captions = AlbumCaptions.empty('trip')
          .withCaption('0004.jpg', 'the good one')
          .renamed('0004.jpg', '0.jpg');
      expect(captions.captionFor('0.jpg'), 'the good one');
      expect(captions.items.containsKey('0004.jpg'), isFalse);
    });

    test('is a no-op for a name that has no entry', () {
      final captions = AlbumCaptions.empty(
        'trip',
      ).withCaption('a.jpg', 'x').renamed('missing.jpg', 'b.jpg');
      expect(captions.items.keys, ['a.jpg']);
    });
  });

  test('isEmpty is true only when there is genuinely nothing to store', () {
    expect(AlbumCaptions.empty('trip').isEmpty, isTrue);
    expect(
      AlbumCaptions.empty('trip').withCaption('a.jpg', 'x').isEmpty,
      isFalse,
    );
    expect(AlbumCaptions.empty('trip').withNext(5).isEmpty, isFalse);
  });
}

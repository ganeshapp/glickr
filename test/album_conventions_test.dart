import 'package:flutter_test/flutter_test.dart';
import 'package:glickr/core/utils/album_conventions.dart';

/// These lock glickr's behaviour to the Jekyll site's `_plugins/albums.rb`.
///
/// The cases below are not invented: they are the folder and file names that
/// actually exist in the album repo today. If one of these ever fails, the app
/// and the website have started disagreeing about what the user's albums look
/// like, which is the worst bug this app can have.
void main() {
  group('albumTitle', () {
    test('matches the site for the real folders in the repo', () {
      expect(albumTitle('cycling_trip'), 'Cycling Trip');
      expect(albumTitle('barcamp-days'), 'Barcamp Days');
      expect(albumTitle('climbing'), 'Climbing');
    });

    test('downcases the tail, exactly as Ruby capitalize does', () {
      // The site renders "Nyc Trip", so the app must too - showing a nicer
      // title than the user will actually get would be a lie.
      expect(albumTitle('NYC_trip'), 'Nyc Trip');
      expect(albumTitle('barcamp-DAYS'), 'Barcamp Days');
    });

    test('collapses repeated and mixed separators', () {
      expect(albumTitle('a__b'), 'A B');
      expect(albumTitle('a-_b'), 'A B');
      expect(albumTitle('_leading'), 'Leading');
    });

    test('handles an empty folder name without throwing', () {
      expect(albumTitle(''), '');
      expect(albumTitle('___'), '');
    });
  });

  group('jekyllSlugify', () {
    test('turns underscores into hyphens', () {
      // The single most consequential line in this file: the folder is
      // cycling_trip but the page is /albums/cycling-trip/. Get it wrong and
      // "View on web" 404s.
      expect(jekyllSlugify('cycling_trip'), 'cycling-trip');
      expect(jekyllSlugify('barcamp-days'), 'barcamp-days');
      expect(jekyllSlugify('climbing'), 'climbing');
    });

    test('downcases and collapses runs of non-alphanumerics', () {
      expect(jekyllSlugify('NYC_trip'), 'nyc-trip');
      expect(jekyllSlugify('a__b--c'), 'a-b-c');
    });

    test('trims leading and trailing hyphens', () {
      expect(jekyllSlugify('_wrapped_'), 'wrapped');
      expect(jekyllSlugify('--x--'), 'x');
    });
  });

  group('folderNameFor', () {
    test('turns a human title into a folder name', () {
      expect(folderNameFor('Cycling Trip'), 'cycling_trip');
      expect(folderNameFor('  Barcamp   Days  '), 'barcamp_days');
    });

    test('round-trips through albumTitle for well-formed titles', () {
      expect(albumTitle(folderNameFor('Cycling Trip')), 'Cycling Trip');
    });

    test('is deliberately lossy for inner caps, and stays consistent', () {
      // Not symmetric, and that is fine as long as the UI shows the derived
      // folder AND title before the user commits.
      expect(folderNameFor('BarCamp Days'), 'barcamp_days');
      expect(albumTitle(folderNameFor('BarCamp Days')), 'Barcamp Days');
    });

    test('strips characters that would break the title derivation', () {
      expect(folderNameFor(r"Ganesh's Trip!"), 'ganeshs_trip');
      expect(folderNameFor('50% off'), '50_off');
    });

    test('never produces leading or trailing separators', () {
      expect(folderNameFor('  -- hi --  '), 'hi');
      expect(folderNameFor('***'), '');
    });
  });

  group('parseSequenceNumber', () {
    test('reads numbers glickr wrote', () {
      expect(parseSequenceNumber('0001.jpg'), 1);
      expect(parseSequenceNumber('0042.mp4'), 42);
      expect(parseSequenceNumber('999.jpg'), 999);
    });

    test('rejects the all-digit legacy names in the real repo', () {
      // Both of these exist in climbing/. A naive int.tryParse would take the
      // next number to 1.5 trillion and generate filenames that break both
      // the pad width and the sort order.
      expect(parseSequenceNumber('1547454978506.jpg'), isNull);
      expect(parseSequenceNumber('1792024187752037.mp4'), isNull);
    });

    test('rejects the cover sentinel', () {
      // 0 is the cover, never a gallery number.
      expect(parseSequenceNumber('0.jpg'), isNull);
      expect(parseSequenceNumber('000.jpg'), isNull);
    });

    test('rejects non-numeric legacy names', () {
      expect(parseSequenceNumber('dscf0336_179086518_o.jpg'), isNull);
      expect(parseSequenceNumber('IMG_20230627_161027.jpg'), isNull);
      expect(parseSequenceNumber('20160625_162806.jpg'), isNull);
      expect(parseSequenceNumber('album.md'), isNull);
      expect(parseSequenceNumber('album.json'), isNull);
    });
  });

  group('nextSequenceNumber', () {
    test('starts at 1 for a fresh album', () {
      expect(nextSequenceNumber(existingNames: const []), 1);
    });

    test('starts at 1 for an album of only legacy names', () {
      // The real cycling_trip folder is entirely legacy names.
      expect(
        nextSequenceNumber(
          existingNames: const [
            'dscf0336_179086518_o.jpg',
            'dscf0327_179131306_o.jpg',
            '0.jpg',
          ],
        ),
        1,
      );
    });

    test('continues past the highest existing number', () {
      expect(
        nextSequenceNumber(existingNames: const ['0001.jpg', '0007.mp4']),
        8,
      );
    });

    test('never reissues a number the high-water mark has passed', () {
      // 0003.jpg was deleted; its slot must not be handed to a new upload,
      // or the new photo inherits the dead one's caption.
      expect(
        nextSequenceNumber(
          existingNames: const ['0001.jpg', '0002.jpg'],
          highWaterMark: 4,
        ),
        4,
      );
    });

    test('respects numbers reserved by a queued batch', () {
      expect(
        nextSequenceNumber(existingNames: const ['0001.jpg'], reservedMax: 12),
        13,
      );
    });

    test('takes the maximum of all three sources', () {
      expect(
        nextSequenceNumber(
          existingNames: const ['0009.jpg'],
          highWaterMark: 5,
          reservedMax: 20,
        ),
        21,
      );
    });
  });

  group('padWidthFor', () {
    test('defaults to 4 for a fresh album', () {
      expect(padWidthFor(const []), kDefaultPadWidth);
    });

    test('defaults to 4 when only legacy names are present', () {
      expect(padWidthFor(const ['dscf0336_o.jpg', '0.jpg']), kDefaultPadWidth);
    });

    test('adopts the width already in use', () {
      // Mixing widths silently reorders an album, because "0001.jpg" sorts
      // before "001.jpg".
      expect(padWidthFor(const ['001.jpg', '002.jpg']), 3);
      expect(padWidthFor(const ['0001.jpg']), 4);
    });

    test('adopts the widest when an album already mixes', () {
      expect(padWidthFor(const ['001.jpg', '0002.jpg']), 4);
    });
  });

  group('sequenceFilename', () {
    test('pads to four digits by default', () {
      expect(sequenceFilename(1, '.jpg'), '0001.jpg');
      expect(sequenceFilename(42, '.mp4'), '0042.mp4');
    });

    test('honours an album that already uses three', () {
      expect(sequenceFilename(7, '.jpg', pad: 3), '007.jpg');
    });

    test('four digits keeps lexicographic order past 999', () {
      // This is the entire reason the default is 4 and not 3: the site sorts
      // filenames as bytes, and "1000.jpg" < "999.jpg" in that order, so at
      // three digits the 1000th photo jumps to the front of the album.
      final threeDigit = ['999.jpg', '1000.jpg']..sort();
      expect(threeDigit, ['1000.jpg', '999.jpg']);

      final fourDigit = [
        sequenceFilename(999, '.jpg'),
        sequenceFilename(1000, '.jpg'),
      ]..sort();
      expect(fourDigit, ['0999.jpg', '1000.jpg']);
    });
  });

  group('coverNameOf', () {
    test('is the first image in sort order', () {
      expect(
        coverNameOf(const ['0003.jpg', '0001.jpg', '0002.jpg']),
        '0001.jpg',
      );
    });

    test('skips a leading video - a cover has to go in an img tag', () {
      expect(
        coverNameOf(const ['0001.mp4', '0002.jpg', '0003.jpg']),
        '0002.jpg',
      );
    });

    test('ignores sidecars', () {
      expect(
        coverNameOf(const ['album.json', 'album.md', '0001.jpg']),
        '0001.jpg',
      );
    });

    test('is null for an album with no images at all', () {
      expect(coverNameOf(const ['0001.mp4']), isNull);
      expect(coverNameOf(const []), isNull);
    });

    test('a legacy 0.jpg is still the cover, because it still sorts first', () {
      // Albums published before the dedicated cover file was dropped keep
      // working untouched - 0 sorts ahead of 0001, so it is simply the first
      // image.
      expect(
        coverNameOf(const ['0001.jpg', '0.jpg', '0002.jpg']),
        '0.jpg',
      );
    });
  });

  group('galleryOrder', () {
    test('sorts images and videos into one list', () {
      expect(
        galleryOrder(const ['0002.mp4', '0001.jpg', '0003.jpg', 'album.md']),
        ['0001.jpg', '0002.mp4', '0003.jpg'],
      );
    });

    test('nothing is excluded - the cover is just the first item', () {
      expect(
        galleryOrder(const ['0002.jpg', '0001.jpg']),
        ['0001.jpg', '0002.jpg'],
      );
    });

    test('a one-photo album shows that photo', () {
      expect(galleryOrder(const ['0001.jpg']), ['0001.jpg']);
    });

    test('drops sidecars and unknown extensions', () {
      expect(
        galleryOrder(const ['album.md', 'album.json', 'notes.txt', '0001.jpg']),
        ['0001.jpg'],
      );
    });

    test('new numbered uploads sort BEFORE existing legacy names', () {
      // Documented, not accidental: this is why adding a photo to a legacy
      // album makes it appear at the front on the website, and why the UI
      // warns about it rather than pretending otherwise.
      expect(
        galleryOrder(const ['dscf0336_o.jpg', '1547454978506.jpg', '0001.jpg']),
        ['0001.jpg', '1547454978506.jpg', 'dscf0336_o.jpg'],
      );
    });
  });

  group('isAlbumMediaPath', () {
    test('accepts exactly two-segment media paths', () {
      expect(isAlbumMediaPath('cycling_trip/0001.jpg'), isTrue);
      expect(isAlbumMediaPath('climbing/1792024187752037.mp4'), isTrue);
    });

    test('rejects nested paths the site cannot see', () {
      // albums.rb does `next unless parts.size == 2`, so anything deeper is
      // invisible on the website. glickr must never create one.
      expect(isAlbumMediaPath('cycling_trip/raw/0001.jpg'), isFalse);
      expect(isAlbumMediaPath('README.md'), isFalse);
    });

    test('rejects sidecars, which are not gallery media', () {
      expect(isAlbumMediaPath('cycling_trip/album.md'), isFalse);
      expect(isAlbumMediaPath('cycling_trip/album.json'), isFalse);
    });
  });
}

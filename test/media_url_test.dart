import 'package:flutter_test/flutter_test.dart';
import 'package:glickr/core/models/app_config.dart';

/// These pin the URLs glickr fetches photos from.
///
/// The default is raw.githubusercontent, not a CDN, and that is a deliberate
/// choice rather than an accident: jsDelivr refuses to serve any GitHub
/// package over 50 MB and applies that ceiling to the WHOLE repository, so an
/// album folder living inside a Jekyll site repo answers 403 for every file
/// and the grid goes silently blank. If these tests start failing, check that
/// before "fixing" them.
void main() {
  AppConfig config({String albumRoot = '', MediaSource? source}) => AppConfig(
    repoOwner: 'ganeshapp',
    repoName: 'ganeshapp.github.io',
    albumRoot: albumRoot,
    mediaSource: source?.name,
  );

  group('AppConfig.mediaUrl', () {
    test('defaults to raw.githubusercontent pinned to the commit sha', () {
      expect(
        config().mediaUrl(
          commitSha: 'a1b2c3',
          folder: 'cycling_trip',
          fileName: '0001.jpg',
        ),
        'https://raw.githubusercontent.com/ganeshapp/ganeshapp.github.io/'
        'a1b2c3/cycling_trip/0001.jpg',
      );
    });

    test('places albums under the album root when one is configured', () {
      expect(
        config(albumRoot: 'assets/albums').mediaUrl(
          commitSha: 'a1b2c3',
          folder: 'cycling_trip',
          fileName: '0001.jpg',
        ),
        'https://raw.githubusercontent.com/ganeshapp/ganeshapp.github.io/'
        'a1b2c3/assets/albums/cycling_trip/0001.jpg',
      );
    });

    test('tolerates a root written with leading or trailing slashes', () {
      expect(
        config(albumRoot: '/assets/albums/').mediaUrl(
          commitSha: 'a1b2c3',
          folder: 'trip',
          fileName: '0.jpg',
        ),
        'https://raw.githubusercontent.com/ganeshapp/ganeshapp.github.io/'
        'a1b2c3/assets/albums/trip/0.jpg',
      );
    });

    test('percent-encodes each path segment on its own', () {
      // The separators the album root brings with it must survive as
      // separators; only what is inside a segment gets escaped.
      expect(
        config(albumRoot: 'assets/albums').mediaUrl(
          commitSha: 'a1b2c3',
          folder: 'summer 2024',
          fileName: 'a&b.jpg',
        ),
        'https://raw.githubusercontent.com/ganeshapp/ganeshapp.github.io/'
        'a1b2c3/assets/albums/summer%202024/a%26b.jpg',
      );
    });

    test('spells the ref with @ when jsDelivr is selected', () {
      // Same file, different grammar: raw separates the ref with a slash,
      // jsDelivr with an @. Getting this wrong 404s every image.
      expect(
        config(albumRoot: 'assets/albums', source: MediaSource.jsdelivr)
            .mediaUrl(
              commitSha: 'a1b2c3',
              folder: 'cycling_trip',
              fileName: '0001.jpg',
            ),
        'https://cdn.jsdelivr.net/gh/ganeshapp/ganeshapp.github.io@a1b2c3/'
        'assets/albums/cycling_trip/0001.jpg',
      );
    });

    test('a record written before the media source existed reads as raw', () {
      // Hive gives a null for a field that was not in the box yet, and the
      // source that must come out of that is the one that works everywhere.
      final legacy = AppConfig(repoOwner: 'o', repoName: 'r');
      expect(legacy.mediaSourceRaw, isNull);
      expect(legacy.mediaSource, MediaSource.raw);
      expect(
        legacy.mediaUrl(commitSha: 's', folder: 'f', fileName: 'n.jpg'),
        'https://raw.githubusercontent.com/o/r/s/f/n.jpg',
      );
    });

    test('copyWith carries the media source through', () {
      final switched = config().copyWith(mediaSource: MediaSource.jsdelivr);
      expect(switched.mediaSource, MediaSource.jsdelivr);
      // ...and an untouched copy keeps it.
      expect(
        switched.copyWith(branch: 'gh-pages').mediaSource,
        MediaSource.jsdelivr,
      );
    });
  });
}

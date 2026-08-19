import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glickr/core/models/app_config.dart';
import 'package:hive/hive.dart';

/// Round-trips [AppConfig] through a real Hive box.
///
/// Every field here is one the user typed or chose. A field that exists on the
/// class but is missing from the TypeAdapter is invisible: it works all
/// session and silently reverts to its default on the next launch, which is
/// about the worst shape a bug can take. The adapter is generated, so this is
/// really a test that it was regenerated.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('glickr_config_test');
    Hive.init(dir.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(AppConfigAdapter());
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await Hive.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<AppConfig> roundTrip(AppConfig config) async {
    var box = await Hive.openBox<AppConfig>('app_config_roundtrip');
    await box.put('current_config', config);
    await box.close();
    box = await Hive.openBox<AppConfig>('app_config_roundtrip');
    return box.get('current_config')!;
  }

  test('survives a restart with every setting intact', () async {
    final saved = await roundTrip(
      AppConfig(
        repoOwner: 'ganeshapp',
        repoName: 'ganeshapp.github.io',
        branch: 'main',
        qualityPreset: 'high',
        siteUrl: 'https://gapp.in',
        albumsPath: 'albums',
        wifiOnlyUploads: true,
        cacheBudgetMb: 500,
        rebuildNoticeSeen: true,
        albumRoot: 'assets/albums',
        mediaSource: MediaSource.jsdelivr.name,
      ),
    );

    expect(saved.repoSlug, 'ganeshapp/ganeshapp.github.io');
    expect(saved.branch, 'main');
    expect(saved.quality, QualityPreset.high);
    expect(saved.siteUrl, 'https://gapp.in');
    expect(saved.albumsPath, 'albums');
    expect(saved.wifiOnlyUploads, isTrue);
    expect(saved.cacheBudgetMb, 500);
    expect(saved.rebuildNoticeSeen, isTrue);
    // Losing this one points every media URL and every album scan at the repo
    // root, which for a site repo means no albums and 404s everywhere.
    expect(saved.albumRoot, 'assets/albums');
    expect(saved.mediaSource, MediaSource.jsdelivr);
  });

  test('an unset media source still reads back as raw', () async {
    final saved = await roundTrip(AppConfig(repoOwner: 'o', repoName: 'r'));
    expect(saved.mediaSourceRaw, isNull);
    expect(saved.mediaSource, MediaSource.raw);
    expect(saved.albumRoot, '');
  });
}

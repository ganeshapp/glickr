import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../platform.dart';

// On a desktop the "gallery" is a folder the user picks, not a photo library
// (a Mac's Photos app is usually empty; Linux has none). Desktop uploads
// photos only, re-encoded in pure Dart; everything that differs is in here.

const _photoExtensions = {'.jpg', '.jpeg', '.png', '.webp'};

/// A picked file standing in for a gallery asset: the id is its absolute path
/// and only id and type mean anything. Never hand one to a photo_manager API -
/// [assetThumbnail] and [assetSourceFile] are the places that would.
AssetEntity fileAsset(String path) =>
    AssetEntity(id: path, typeInt: AssetType.image.index, width: 0, height: 0);

ImageProvider assetThumbnail(AssetEntity asset, int size) =>
    isDesktop
        ? ResizeImage(FileImage(File(asset.id)), width: size)
        : AssetEntityImageProvider(
          asset,
          isOriginal: false,
          thumbnailSize: ThumbnailSize.square(size),
        );

Future<File?> assetSourceFile(AssetEntity asset) async =>
    isDesktop ? File(asset.id) : await asset.originFile;

/// The Linux "gallery": the photos in a folder the user picks, by file name.
/// Null when the dialog is cancelled.
Future<List<AssetEntity>?> pickPhotoFolder() async {
  final dir = await FileSelectorPlatform.instance.getDirectoryPathWithOptions(
    const FileDialogOptions(confirmButtonText: 'Use folder'),
  );
  if (dir == null) return null;
  final paths = [
    for (final f in Directory(dir).listSync().whereType<File>())
      if (_photoExtensions.contains(p.extension(f.path).toLowerCase())) f.path,
  ]..sort();
  return [for (final path in paths) fileAsset(path)];
}

/// JPEG at [target], long edge capped at [maxEdge] (never upscaled), EXIF
/// rotation applied and every other EXIF field (GPS) dropped. Pure Dart on a
/// background isolate: ~1 s per 12 MP photo on an M2; three run in parallel.
Future<File> encodeJpeg(
  String source,
  String target, {
  required int maxEdge,
  required int quality,
}) {
  return Isolate.run(() {
    // package:image's JPEG decoder applies the EXIF orientation itself.
    var image = img.decodeImage(File(source).readAsBytesSync());
    if (image == null) {
      throw const FormatException('Unsupported image - use JPEG, PNG or WebP');
    }
    final scale = maxEdge / math.max(image.width, image.height);
    if (scale < 1) {
      image = img.copyResize(
        image,
        width: (image.width * scale).round(),
        height: (image.height * scale).round(),
        interpolation: img.Interpolation.average,
      );
    }
    // The decoder keeps GPS & co, and encodeJpg would write them back.
    image.exif = img.ExifData();
    return File(target)
      ..writeAsBytesSync(img.encodeJpg(image, quality: quality));
  });
}

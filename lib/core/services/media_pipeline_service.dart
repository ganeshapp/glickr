import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:video_compress/video_compress.dart';

import '../models/app_config.dart';
import '../platform.dart';
import '../utils/album_conventions.dart';
import 'linux_media.dart';

/// Concrete numbers behind Low / Medium / High.
class PresetSpec {
  /// Cap on the image's LONG edge, in pixels.
  final int imageMaxEdge;
  final int jpegQuality;

  /// The video_compress preset. Only the two-argument `Res...Quality` values
  /// are used: the single-argument ones (`MediumQuality` and friends) bound
  /// the SHORT edge only, so a 16:9 clip at "medium" comes out 1136x640 -
  /// more pixels than 720p.
  final VideoQuality videoQuality;
  final String videoLabel;

  /// Rough output rate, MiB per minute, used for the size projection shown
  /// before a transcode starts.
  final double videoMibPerMinute;

  /// Rough output bytes per megapixel of source, for the photo projection.
  final double imageBytesPerPixel;

  const PresetSpec({
    required this.imageMaxEdge,
    required this.jpegQuality,
    required this.videoQuality,
    required this.videoLabel,
    required this.videoMibPerMinute,
    required this.imageBytesPerPixel,
  });
}

/// One processed file, ready to upload.
class ProcessedMedia {
  final File file;
  final int bytes;
  final int sourceBytes;
  final bool isVideo;

  const ProcessedMedia({
    required this.file,
    required this.bytes,
    required this.sourceBytes,
    required this.isVideo,
  });

  double get savedFraction =>
      sourceBytes == 0 ? 0 : 1 - (bytes / sourceBytes).clamp(0.0, 1.0);
}

/// A per-item failure that should not take the rest of the batch down.
class MediaProcessingException implements Exception {
  final String message;
  const MediaProcessingException(this.message);
  @override
  String toString() => message;
}

/// Compresses and converts device media into the two formats the site
/// renders: JPEG and MP4.
class MediaPipelineService {
  /// Hard per-file ceiling.
  ///
  /// GitHub blocks any file over 100 MB outright, and a browser has to download
  /// whatever is on the page in one go - so this is a "will the album actually
  /// be pleasant to open" limit rather than a platform one. 40 MB is roughly
  /// four minutes of video at the High preset, which is already a lot to put on
  /// a web page, and it stays well clear of the base64 inflation on the way up.
  static const int maxFileBytes = 40 * 1024 * 1024;

  /// Budget for the WHOLE repository, because that is what the host measures.
  ///
  /// GitHub Pages documents a 1 GB published-site limit and the same figure as
  /// a recommendation for the source repo, so that is the wall. Warn with real
  /// headroom rather than at the edge: git keeps every version of every photo
  /// forever, and photos are already-compressed binaries that git cannot delta,
  /// so the number only ever goes up - deleting an album does not give the
  /// space back.
  ///
  /// Note for a future move to Cloudflare Pages: it has no aggregate size limit
  /// but caps a deployment at 20,000 files on the free plan (100,000 on paid),
  /// which for a photo site is the ceiling that would bind instead.
  static const int repoCeilingBytes = 1024 * 1024 * 1024;
  static const int repoWarnBytes = 800 * 1024 * 1024;
  static const int repoBlockBytes = 980 * 1024 * 1024;

  /// Three at a time. The native side runs an 8-thread pool so these really do
  /// overlap, but each holds a decoded bitmap, so this is a memory ceiling as
  /// much as a throughput choice.
  static const int photoConcurrency = 3;

  static const Map<QualityPreset, PresetSpec> presets = {
    QualityPreset.low: PresetSpec(
      imageMaxEdge: 1024,
      jpegQuality: 75,
      videoQuality: VideoQuality.Res640x480Quality,
      videoLabel: '640x480',
      videoMibPerMinute: 8.3,
      imageBytesPerPixel: 0.126,
    ),
    QualityPreset.medium: PresetSpec(
      imageMaxEdge: 1600,
      jpegQuality: 85,
      videoQuality: VideoQuality.Res960x540Quality,
      videoLabel: '960x540',
      videoMibPerMinute: 16.9,
      imageBytesPerPixel: 0.145,
    ),
    QualityPreset.high: PresetSpec(
      imageMaxEdge: 1600,
      jpegQuality: 92,
      videoQuality: VideoQuality.Res1280x720Quality,
      videoLabel: '1280x720',
      videoMibPerMinute: 29.1,
      imageBytesPerPixel: 0.19,
    ),
  };

  static PresetSpec specFor(QualityPreset preset) => presets[preset]!;

  /// Containers Android's MediaExtractor cannot demux.
  ///
  /// AVI generally cannot be opened at all, and the codecs usually inside it
  /// (DivX, Xvid, MJPEG) are not decodable either. video_compress reports this
  /// as a bare null, indistinguishable from a user cancel, so it is rejected
  /// up front with a message that says what actually happened.
  static const Set<String> unsupportedVideoExtensions = {'.avi', '.wmv', '.flv'};

  /// Bumped by every [cancelVideo] call; captured by every [processVideo] run.
  ///
  /// Load-bearing in two ways. First, it is the only way to report "you
  /// cancelled" instead of "something went wrong": the plugin calls
  /// `result.success(null)` for BOTH a cancel and a failure, so Dart cannot
  /// tell them apart from the return value.
  ///
  /// Second, a counter rather than a bool because a video run does not become
  /// cancellable at a single instant - it spends seconds pulling the source
  /// out of the gallery before the transcode is ever handed to the plugin. A
  /// bool set during that window is either cleared by the run that is about to
  /// start (the cancel is lost and the whole transcode runs anyway) or left
  /// set afterwards to poison the next, unrelated run. With a counter,
  /// "cancelled" simply means it moved since this run captured it, which needs
  /// no reset and cannot leak across runs.
  int _cancelEpoch = 0;
  bool _videoInFlight = false;

  bool get isCompressingVideo => _videoInFlight;

  /// Compress [asset] to JPEG at [preset], writing to [targetPath].
  ///
  /// [targetPath] must end in .jpg or .jpeg; the plugin validates the
  /// extension and throws otherwise.
  Future<ProcessedMedia> processPhoto({
    required AssetEntity asset,
    required QualityPreset preset,
    required String targetPath,
  }) async {
    final spec = specFor(preset);

    // The ORIGINAL file, not a picker-normalised copy: some pickers strip
    // metadata before the app ever sees it, and once the EXIF orientation tag
    // is gone the compressor cannot bake in the rotation, so portrait photos
    // come out sideways.
    final source = await assetSourceFile(asset);
    if (source == null || !await source.exists()) {
      throw const MediaProcessingException(
        "Couldn't read this photo from your gallery",
      );
    }
    final sourceBytes = await source.length();

    final target = _targetDimensions(
      width: asset.orientatedWidth,
      height: asset.orientatedHeight,
      maxEdge: spec.imageMaxEdge,
    );

    File? out;
    try {
      if (isLinux) {
        out = await encodeJpeg(
          source.path,
          targetPath,
          maxEdge: spec.imageMaxEdge,
          quality: spec.jpegQuality,
        );
      } else {
        final result = await FlutterImageCompress.compressAndGetFile(
          source.absolute.path,
          targetPath,
          // NOT a max-dimension box: the plugin computes
          // scale = max(1, min(w/minWidth, h/minHeight)), which makes both
          // output axes >= what is passed. Passing the same value twice
          // therefore pins the SHORT edge, so a 4032x3024 photo asked for
          // "1600" comes back 2133x1600. An exact target pair is the only way
          // to actually cap the long edge.
          minWidth: target.width,
          minHeight: target.height,
          quality: spec.jpegQuality,
          format: CompressFormat.jpeg,
          // Strip EXIF: GPS coordinates in a public repo are forever, and git
          // history keeps them even after the photo is deleted.
          keepExif: false,
          // Bakes the EXIF rotation into the pixels AND transposes the target
          // dimensions for 90/270 sources. Turning it off is what produces
          // sideways portraits.
          autoCorrectionAngle: true,
          // Decode downsampled. Without it a 48 MP photo is decoded at full
          // ARGB_8888 - 192 MB - and the plugin's OOM recovery path ends in a
          // bare `return` that writes nothing, so Dart receives an EMPTY file
          // rather than an error.
          inSampleSize: _sampleSize(
            math.max(asset.orientatedWidth, asset.orientatedHeight),
            spec.imageMaxEdge,
          ),
          numberOfRetries: 5,
        );
        out = result == null ? null : File(result.path);
      }
    } catch (e) {
      throw MediaProcessingException(_photoErrorMessage(asset, e));
    }

    if (out == null || !await out.exists()) {
      throw MediaProcessingException(_photoErrorMessage(asset, null));
    }
    final bytes = await out.length();
    // Guard the silent-OOM path described above.
    if (bytes == 0) {
      await out.delete().catchError((_) => out!);
      throw const MediaProcessingException(
        'This photo was too large for this device to process',
      );
    }

    return ProcessedMedia(
      file: out,
      bytes: bytes,
      sourceBytes: sourceBytes,
      isVideo: false,
    );
  }

  /// Transcode [asset] to H.264/AAC MP4 at [preset].
  ///
  /// Strictly one at a time: the plugin throws if a second compression starts
  /// while one is running, and hardware encoder sessions are a scarce global
  /// resource regardless.
  Future<ProcessedMedia> processVideo({
    required AssetEntity asset,
    required QualityPreset preset,
    required String targetPath,
    void Function(double progress)? onProgress,
  }) async {
    // Captured before the first await, so everything from here on belongs to
    // this run and any cancel raised after this line applies to it.
    final epoch = _cancelEpoch;
    bool isCancelled() => _cancelEpoch != epoch;

    final spec = specFor(preset);
    final source = await asset.originFile;
    if (source == null || !await source.exists()) {
      throw const MediaProcessingException(
        "Couldn't read this video from your gallery",
      );
    }

    final ext = p.extension(source.path).toLowerCase();
    if (unsupportedVideoExtensions.contains(ext)) {
      throw MediaProcessingException(
        '${ext.substring(1).toUpperCase()} videos cannot be converted on '
        'Android - convert it on a computer first',
      );
    }

    final sourceBytes = await source.length();

    // Reading the source above is the slowest part of this method for a large
    // clip - on scoped storage it copies the whole file out of MediaStore - so
    // it is also the likeliest moment for the user to give up and cancel.
    // Checking here is what stops a cancelled batch from transcoding anyway.
    if (isCancelled()) {
      throw const MediaProcessingException('Cancelled');
    }
    _videoInFlight = true;

    Subscription? subscription;
    if (onProgress != null) {
      subscription = VideoCompress.compressProgress$.subscribe((progress) {
        // The transcoder emits very frequently; the caller throttles.
        onProgress(progress / 100.0);
      });
    }

    try {
      final info = await VideoCompress.compressVideo(
        source.absolute.path,
        quality: spec.videoQuality,
        deleteOrigin: false,
        includeAudio: true,
      );

      if (isCancelled()) {
        throw const MediaProcessingException('Cancelled');
      }
      final compressed = info?.file;
      if (compressed == null) {
        // A bare null. Both onTranscodeFailed and onTranscodeCanceled report
        // success(null), so with the epoch unmoved this is a real failure.
        throw const MediaProcessingException(
          "This video's format couldn't be converted",
        );
      }

      final File moved;
      final int bytes;
      try {
        moved = await compressed.copy(targetPath);
        bytes = await moved.length();
      } on FileSystemException catch (e) {
        // The staging directory can vanish underneath a transcode - cancelling
        // a batch deletes it - and File.copy does not recreate parents. This
        // has to surface as a per-item MediaProcessingException: any other
        // exception type escapes the caller's per-item handler and is treated
        // as a batch-level failure, which re-persists the batch the user just
        // cancelled.
        throw MediaProcessingException(
          kDebugMode
              ? "Couldn't save the converted video ($e)"
              : "Couldn't save the converted video",
        );
      }
      return ProcessedMedia(
        file: moved,
        bytes: bytes,
        sourceBytes: sourceBytes,
        isVideo: true,
      );
    } finally {
      subscription?.unsubscribe();
      _videoInFlight = false;
      // The plugin writes partial output into its own cache directory;
      // leaving it there leaks storage across a long session.
      await VideoCompress.deleteAllCache().catchError((_) => false);
    }
  }

  /// Cancel the video conversion in progress, if any.
  ///
  /// The epoch is bumped UNCONDITIONALLY, even when nothing is in flight yet.
  /// A cancel that arrives while [processVideo] is still reading the source
  /// file has nothing to tell the plugin, but it still has to be remembered -
  /// otherwise the transcode that is about to start runs to completion on a
  /// batch the user already cancelled.
  Future<void> cancelVideo() async {
    _cancelEpoch++;
    if (!_videoInFlight) return;
    await VideoCompress.cancelCompression();
  }

  /// Projected output size for a video of [duration] at [preset].
  int projectedVideoBytes(Duration duration, QualityPreset preset) {
    final minutes = duration.inMilliseconds / 60000.0;
    return (specFor(preset).videoMibPerMinute * minutes * 1024 * 1024).round();
  }

  /// Projected output size for one photo at [preset].
  int projectedPhotoBytes({
    required int width,
    required int height,
    required QualityPreset preset,
  }) {
    final spec = specFor(preset);
    final target = _targetDimensions(
      width: width,
      height: height,
      maxEdge: spec.imageMaxEdge,
    );
    final pixels = target.width * target.height;
    return (pixels * spec.imageBytesPerPixel).round();
  }

  /// Exact output dimensions capping the LONG edge at [maxEdge], never
  /// upscaling.
  static ({int width, int height}) _targetDimensions({
    required int width,
    required int height,
    required int maxEdge,
  }) {
    // Some MediaStore rows report 0x0. Falling back to a square target is
    // safe: it merely overshoots to short-edge = maxEdge rather than
    // producing a broken file.
    if (width <= 0 || height <= 0) {
      return (width: maxEdge, height: maxEdge);
    }
    final longEdge = math.max(width, height);
    if (longEdge <= maxEdge) return (width: width, height: height);
    final scale = longEdge / maxEdge;
    return (
      width: math.max(1, (width / scale).round()),
      height: math.max(1, (height / scale).round()),
    );
  }

  /// Largest power of two that still leaves the long edge at or above
  /// [maxEdge], so the decode is cheap but the final resize is not upscaling.
  static int _sampleSize(int longEdge, int maxEdge) {
    if (longEdge <= 0) return 1;
    var sample = 1;
    while (longEdge ~/ (sample * 2) >= maxEdge) {
      sample *= 2;
      if (sample >= 16) break;
    }
    return sample;
  }

  String _photoErrorMessage(AssetEntity asset, Object? error) {
    final mime = asset.mimeType?.toLowerCase() ?? '';
    if (mime.contains('avif')) {
      return 'AVIF photos need Android 12 or newer';
    }
    if (kDebugMode && error != null) {
      return "Couldn't convert this photo ($error)";
    }
    return "Couldn't convert this photo";
  }
}

/// Human-readable byte count, e.g. "1.4 MB".
String formatBytes(int bytes, {int decimals = 1}) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final fixed = value >= 100 ? 0 : decimals;
  return '${value.toStringAsFixed(fixed)} ${units[unit]}';
}

/// "1:47" for a clip length.
String formatDuration(Duration d) {
  final minutes = d.inMinutes;
  final seconds = d.inSeconds % 60;
  if (minutes >= 60) {
    final hours = d.inHours;
    return '$hours:${(minutes % 60).toString().padLeft(2, '0')}'
        ':${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// The extension glickr will give an asset once converted: everything becomes
/// .jpg or .mp4, matching the two formats the site renders reliably.
String targetExtensionFor(AssetEntity asset) =>
    asset.type == AssetType.video ? '.mp4' : '.jpg';

/// True when the asset is one the pipeline can handle at all.
bool isSupportedAsset(AssetEntity asset) {
  if (asset.type == AssetType.video) {
    final mime = asset.mimeType?.toLowerCase() ?? '';
    return !mime.contains('avi') && !mime.contains('x-msvideo');
  }
  return asset.type == AssetType.image;
}

/// Sanity guard so nothing ever writes a nested path into the repo - the site
/// only renders files exactly one level inside an album folder.
String repoPathFor(String folder, String fileName) {
  assert(!fileName.contains('/'), 'file name must not contain a path');
  assert(!folder.contains('/'), 'album folder must be a single segment');
  return '$folder/$fileName';
}

/// Convenience re-export so callers do not need both imports for one check.
bool isRenderable(String name) => isRenderableName(name);

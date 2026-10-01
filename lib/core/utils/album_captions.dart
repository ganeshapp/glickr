import 'dart:convert';

import 'album_conventions.dart';

/// Reader and writer for an album's `album.json` sidecar.
///
/// The file lives in a git repo that humans also edit, which drives every
/// decision here:
///
///   * ITEMS ARE A MAP KEYED BY FILENAME, not a list. A caption edit then
///     touches exactly one line, so git's line-based merge resolves two
///     devices captioning different photos on its own. A list would reorder
///     and produce whole-file conflicts.
///   * EVERY ENTRY IS EMITTED ON ONE LINE, including the rare object form.
///     That one-line-per-entry property is precisely what the merge above
///     depends on; pretty-printing a nested object would break it.
///   * VALUES ARE POLYMORPHIC. The common case is a bare string, so a human
///     can type `"0003.jpg": "my caption"` and be done. The object form
///     exists only when there is more than a caption to store.
///   * UNKNOWN KEYS ROUND-TRIP. Someone who adds a top-level `"credits"` must
///     not have it silently deleted by the next app write.
///
/// `next` is a monotonic high-water mark that deletion never lowers. It is the
/// primary defence against the hazard the concept notes call out: a deleted
/// `0003.jpg` freeing its slot for a later upload, which would then inherit
/// the dead photo's caption.
class AlbumCaptions {
  static const int currentVersion = 1;

  final String album;
  final int pad;
  final int next;

  /// The one-line album summary for the listing card. Plain text; '' when the
  /// album has none, and then not written at all.
  final String summary;

  final Map<String, Object> items;

  /// Top-level keys glickr does not own, preserved verbatim on write.
  final Map<String, dynamic> extras;

  const AlbumCaptions({
    required this.album,
    this.pad = kDefaultPadWidth,
    this.next = 1,
    this.summary = '',
    this.items = const {},
    this.extras = const {},
  });

  factory AlbumCaptions.empty(String album) => AlbumCaptions(album: album);

  /// Parse [source], falling back to an empty set for anything unreadable.
  ///
  /// Never throws. A hand-mangled `album.json` should cost the user their
  /// captions, not their ability to open the album.
  factory AlbumCaptions.parse(String album, String? source) {
    if (source == null || source.trim().isEmpty) {
      return AlbumCaptions.empty(album);
    }
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map) return AlbumCaptions.empty(album);

      final rawItems = decoded['items'];
      final items = <String, Object>{};
      if (rawItems is Map) {
        rawItems.forEach((key, value) {
          if (key is! String) return;
          if (value is String) {
            items[key] = value;
          } else if (value is Map) {
            items[key] = Map<String, dynamic>.from(value);
          }
        });
      }

      final extras = <String, dynamic>{};
      for (final entry in decoded.entries) {
        final key = entry.key;
        if (key is! String) continue;
        if (_ownedKeys.contains(key)) continue;
        extras[key] = entry.value;
      }

      return AlbumCaptions(
        album: decoded['album'] as String? ?? album,
        pad: _asInt(decoded['pad']) ?? kDefaultPadWidth,
        next: _asInt(decoded['next']) ?? 1,
        summary: switch (decoded['summary']) {
          String s => s.trim(),
          _ => '',
        },
        items: items,
        extras: extras,
      );
    } catch (_) {
      return AlbumCaptions.empty(album);
    }
  }

  static const _ownedKeys = {
    'version',
    'album',
    'pad',
    'next',
    'updated',
    'summary',
    'items',
  };

  /// The caption for [fileName], or '' when it has none.
  String captionFor(String fileName) {
    final value = items[fileName];
    if (value is String) return value;
    if (value is Map) return value['caption'] as String? ?? '';
    return '';
  }

  /// A flat filename to caption map, for merging onto [MediaItem]s.
  Map<String, String> get captionsByName {
    final out = <String, String>{};
    for (final name in items.keys) {
      final caption = captionFor(name);
      if (caption.isNotEmpty) out[name] = caption;
    }
    return out;
  }

  /// Set or clear the caption for [fileName], preserving any extra keys an
  /// object-form entry already carried.
  AlbumCaptions withCaption(String fileName, String? caption) {
    final updated = Map<String, Object>.from(items);
    final existing = updated[fileName];
    final trimmed = caption?.trim() ?? '';

    if (trimmed.isEmpty) {
      if (existing is Map) {
        final rest = Map<String, dynamic>.from(existing)..remove('caption');
        // Keep the entry only if it still carries data somebody added.
        if (rest.isEmpty) {
          updated.remove(fileName);
        } else {
          updated[fileName] = rest;
        }
      } else {
        updated.remove(fileName);
      }
    } else if (existing is Map) {
      updated[fileName] = Map<String, dynamic>.from(existing)
        ..['caption'] = trimmed;
    } else {
      updated[fileName] = trimmed;
    }
    return _copy(items: updated);
  }

  /// Drop the entries for [fileNames].
  ///
  /// Always run in the same commit that removes the files themselves, so
  /// there is no window in which a photo is gone but its caption survives to
  /// be inherited by a future upload.
  AlbumCaptions withoutFiles(Iterable<String> fileNames) {
    final updated = Map<String, Object>.from(items);
    for (final name in fileNames) {
      updated.remove(name);
    }
    return _copy(items: updated);
  }

  /// Rename an entry, following a file that moved (a cover swap, say).
  AlbumCaptions renamed(String from, String to) {
    if (!items.containsKey(from)) return this;
    final updated = Map<String, Object>.from(items);
    updated[to] = updated.remove(from)!;
    return _copy(items: updated);
  }

  /// Drop entries whose file no longer exists in the album.
  ///
  /// The backstop for the cases the monotonic `next` cannot cover: a human
  /// deleting `album.json`, or adding a file through github.com. Do not push a
  /// commit for this on every album open - let it ride along on the next write
  /// glickr makes anyway.
  AlbumCaptions withoutOrphans(Set<String> existingFileNames) {
    final updated = <String, Object>{};
    for (final entry in items.entries) {
      if (existingFileNames.contains(entry.key)) {
        updated[entry.key] = entry.value;
      }
    }
    return _copy(items: updated);
  }

  /// Raise the high-water mark. Never lowers it: that is the whole point.
  AlbumCaptions withNext(int candidate) {
    return candidate > next ? _copy(next: candidate) : this;
  }

  AlbumCaptions withPad(int value) => _copy(pad: value);

  AlbumCaptions withSummary(String value) => _copy(summary: value.trim());

  bool get isEmpty =>
      items.isEmpty && extras.isEmpty && next <= 1 && summary.isEmpty;

  AlbumCaptions _copy({
    int? pad,
    int? next,
    String? summary,
    Map<String, Object>? items,
    Map<String, dynamic>? extras,
  }) {
    return AlbumCaptions(
      album: album,
      pad: pad ?? this.pad,
      next: next ?? this.next,
      summary: summary ?? this.summary,
      items: items ?? this.items,
      extras: extras ?? this.extras,
    );
  }

  /// Serialise, one entry per line, keys in byte order.
  ///
  /// Hand-built rather than `JsonEncoder.withIndent` because the indenting
  /// encoder would spread an object-form value across several lines and
  /// destroy the mergeability the whole format is designed around.
  String encode({DateTime? updatedAt}) {
    final keys = items.keys.toList()..sort();
    final buffer = StringBuffer('{\n');
    buffer.write('  "version": $currentVersion,\n');
    buffer.write('  "album": ${jsonEncode(album)},\n');
    buffer.write('  "pad": $pad,\n');
    buffer.write('  "next": $next,\n');
    buffer.write(
      '  "updated": '
      '${jsonEncode((updatedAt ?? DateTime.now()).toUtc().toIso8601String())},\n',
    );
    if (summary.isNotEmpty) {
      buffer.write('  "summary": ${jsonEncode(summary)},\n');
    }

    for (final entry in extras.entries) {
      buffer.write('  ${jsonEncode(entry.key)}: ${jsonEncode(entry.value)},\n');
    }

    buffer.write('  "items": {\n');
    for (var i = 0; i < keys.length; i++) {
      buffer.write('    ${jsonEncode(keys[i])}: ${jsonEncode(items[keys[i]])}');
      buffer.write(i == keys.length - 1 ? '\n' : ',\n');
    }
    buffer.write('  }\n');
    buffer.write('}\n');
    return buffer.toString();
  }
}

int? _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

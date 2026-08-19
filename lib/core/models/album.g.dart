// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'album.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class AlbumAdapter extends TypeAdapter<Album> {
  @override
  final int typeId = 1;

  @override
  Album read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Album(
      folder: fields[0] as String,
      blurb: fields[1] as String,
      items: (fields[2] as List?)?.cast<MediaItem>(),
    )
      ..treeShaRaw = fields[3] as String?
      ..blurbShaRaw = fields[4] as String?
      ..captionsShaRaw = fields[5] as String?
      ..captionsJsonRaw = fields[6] as String?
      ..nextNumberRaw = fields[7] as int?
      ..lastSyncedRaw = fields[8] as DateTime?;
  }

  @override
  void write(BinaryWriter writer, Album obj) {
    writer
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.folder)
      ..writeByte(1)
      ..write(obj.blurb)
      ..writeByte(2)
      ..write(obj.items)
      ..writeByte(3)
      ..write(obj.treeShaRaw)
      ..writeByte(4)
      ..write(obj.blurbShaRaw)
      ..writeByte(5)
      ..write(obj.captionsShaRaw)
      ..writeByte(6)
      ..write(obj.captionsJsonRaw)
      ..writeByte(7)
      ..write(obj.nextNumberRaw)
      ..writeByte(8)
      ..write(obj.lastSyncedRaw);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AlbumAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

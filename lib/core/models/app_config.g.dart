// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_config.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class AppConfigAdapter extends TypeAdapter<AppConfig> {
  @override
  final int typeId = 0;

  @override
  AppConfig read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AppConfig(
      repoOwner: fields[0] as String,
      repoName: fields[1] as String,
      branch: fields[2] as String,
    )
      ..qualityPresetRaw = fields[3] as String?
      ..siteUrlRaw = fields[4] as String?
      ..albumsPathRaw = fields[5] as String?
      ..mediaBaseRaw = fields[6] as String?
      ..wifiOnlyUploadsRaw = fields[7] as bool?
      ..cacheBudgetMbRaw = fields[8] as int?
      ..rebuildNoticeSeenRaw = fields[9] as bool?
      ..albumRootRaw = fields[10] as String?
      ..mediaSourceRaw = fields[11] as String?;
  }

  @override
  void write(BinaryWriter writer, AppConfig obj) {
    writer
      ..writeByte(12)
      ..writeByte(0)
      ..write(obj.repoOwner)
      ..writeByte(1)
      ..write(obj.repoName)
      ..writeByte(2)
      ..write(obj.branch)
      ..writeByte(3)
      ..write(obj.qualityPresetRaw)
      ..writeByte(4)
      ..write(obj.siteUrlRaw)
      ..writeByte(5)
      ..write(obj.albumsPathRaw)
      ..writeByte(6)
      ..write(obj.mediaBaseRaw)
      ..writeByte(7)
      ..write(obj.wifiOnlyUploadsRaw)
      ..writeByte(8)
      ..write(obj.cacheBudgetMbRaw)
      ..writeByte(9)
      ..write(obj.rebuildNoticeSeenRaw)
      ..writeByte(10)
      ..write(obj.albumRootRaw)
      ..writeByte(11)
      ..write(obj.mediaSourceRaw);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppConfigAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

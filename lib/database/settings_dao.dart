import 'package:sqflite/sqflite.dart';

import 'musi_database.dart';

class SettingsDao {
  Future<Database> get _db async => await MusiDatabase.instance.database;

  Future<void> setSetting(String key, String value) async {
    final db = await _db;
    await db.insert('settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getSetting(String key) async {
    final db = await _db;
    final maps = await db.query('settings', where: 'key = ?', whereArgs: [key]);
    if (maps.isNotEmpty) {
      return maps.first['value'] as String?;
    }
    return null;
  }

  // Convenience helpers
  Future<bool> getOfflineMode() async {
    final val = await getSetting('offline_mode');
    return val == 'true';
  }

  Future<void> setOfflineMode(bool enabled) async {
    await setSetting('offline_mode', enabled ? 'true' : 'false');
  }

  Future<String> getAudioQuality() async {
    final val = await getSetting('audio_quality');
    return val ?? 'High (256 kbps)';
  }

  Future<void> setAudioQuality(String quality) async {
    await setSetting('audio_quality', quality);
  }

  Future<bool> getNormalizeVolume() async {
    final val = await getSetting('normalize_volume');
    return val != 'false'; // defaults to true
  }

  Future<void> setNormalizeVolume(bool enabled) async {
    await setSetting('normalize_volume', enabled ? 'true' : 'false');
  }

  // YouTube enablement
  Future<bool> getYouTubeEnabled() async {
    final val = await getSetting('youtube_enabled');
    return val != 'false'; // defaults to true
  }

  Future<void> setYouTubeEnabled(bool enabled) async {
    await setSetting('youtube_enabled', enabled ? 'true' : 'false');
  }

  // Provider enabled state
  Future<bool> isProviderEnabled(String providerId) async {
    final val = await getSetting('provider_enabled_$providerId');
    return val != 'false'; // defaults to true
  }

  Future<void> setProviderEnabled(String providerId, bool enabled) async {
    await setSetting(
      'provider_enabled_$providerId',
      enabled ? 'true' : 'false',
    );
  }
}

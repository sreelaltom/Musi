import 'package:sqflite/sqflite.dart';

import '../models/music_provider.dart';
import 'musi_database.dart';

class ProviderDao {
  Future<Database> get _db async => await MusiDatabase.instance.database;

  Future<void> upsertProvider(MusicProvider provider) async {
    final db = await _db;
    await db.insert(
      'providers',
      provider.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<MusicProvider>> getAllProviders() async {
    final db = await _db;
    final maps = await db.query('providers');
    return maps.map((m) => MusicProvider.fromMap(m)).toList();
  }

  Future<MusicProvider?> getProvider(String id) async {
    final db = await _db;
    final maps = await db.query('providers', where: 'id = ?', whereArgs: [id]);
    if (maps.isNotEmpty) {
      return MusicProvider.fromMap(maps.first);
    }
    return null;
  }

  Future<void> setProviderEnabled(String id, bool enabled) async {
    final db = await _db;
    await db.update(
      'providers',
      {'enabled': enabled ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> seedDefaultProviders() async {
    final existing = await getAllProviders();
    final existingIds = existing.map((provider) => provider.id).toSet();
    final defaults = [
      const MusicProvider(
        id: 'jamendo',
        name: 'Jamendo',
        description: 'Creative Commons licensed music from independent artists',
        attributionUrl: 'https://www.jamendo.com',
        canStream: true,
        canDownload: true,
        enabled: true,
      ),
      const MusicProvider(
        id: 'mock',
        name: 'Open Licensed Sources',
        description: 'Built-in public domain and Creative Commons test catalog',
        attributionUrl: null,
        canStream: true,
        canDownload: true,
        enabled: true,
      ),
      const MusicProvider(
        id: 'youtube',
        name: 'YouTube',
        description: 'Official YouTube music discovery and visible playback',
        attributionUrl: 'https://www.youtube.com',
        canStream: false,
        canDownload: false,
        enabled: true,
      ),
    ];

    for (final provider in defaults) {
      if (!existingIds.contains(provider.id)) {
        await upsertProvider(provider);
      }
    }
  }
}

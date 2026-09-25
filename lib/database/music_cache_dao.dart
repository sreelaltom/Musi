import 'package:sqflite/sqflite.dart';

import '../models/music_cache_entry.dart';
import 'musi_database.dart';

class MusicCacheDao {
  Future<Database> get _db async => await MusiDatabase.instance.database;

  Future<void> upsertCacheEntry(MusicCacheEntry entry) async {
    final db = await _db;
    await db.insert(
      'music_cache',
      entry.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsertCacheEntries(List<MusicCacheEntry> entries) async {
    if (entries.isEmpty) return;
    final db = await _db;
    final batch = db.batch();
    for (final entry in entries) {
      batch.insert(
        'music_cache',
        entry.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<MusicCacheEntry?> getCacheEntry(
    CachedSourceType sourceType,
    String sourceId,
  ) async {
    final db = await _db;
    final maps = await db.query(
      'music_cache',
      where: 'source_type = ? AND source_id = ?',
      whereArgs: [sourceType.value, sourceId],
    );
    if (maps.isNotEmpty) {
      return MusicCacheEntry.fromMap(maps.first);
    }
    return null;
  }

  Future<List<MusicCacheEntry>> searchCache(String query) async {
    final db = await _db;
    final cleanQuery = query.toLowerCase().trim();
    if (cleanQuery.isEmpty) return [];

    final maps = await db.query(
      'music_cache',
      where:
          'LOWER(title) LIKE ? OR LOWER(artist) LIKE ? OR LOWER(album) LIKE ?',
      whereArgs: ['%$cleanQuery%', '%$cleanQuery%', '%$cleanQuery%'],
      orderBy: 'last_played_at DESC NULLS LAST, cached_at DESC',
      limit: 150,
    );
    return maps.map((m) => MusicCacheEntry.fromMap(m)).toList();
  }

  Future<List<MusicCacheEntry>> getRecentCached({int limit = 20}) async {
    final db = await _db;
    final maps = await db.query(
      'music_cache',
      orderBy: 'last_played_at DESC NULLS LAST, cached_at DESC',
      limit: limit,
    );
    return maps.map((m) => MusicCacheEntry.fromMap(m)).toList();
  }

  Future<void> updateLastPlayed(
    CachedSourceType sourceType,
    String sourceId,
  ) async {
    final db = await _db;
    await db.update(
      'music_cache',
      {'last_played_at': DateTime.now().toIso8601String()},
      where: 'source_type = ? AND source_id = ?',
      whereArgs: [sourceType.value, sourceId],
    );
  }

  Future<int> cleanupStaleCache({
    Duration maxAge = const Duration(days: 30),
  }) async {
    final db = await _db;
    final cutoff = DateTime.now().subtract(maxAge).toIso8601String();
    return await db.delete(
      'music_cache',
      where: 'cached_at < ? AND last_played_at IS NULL',
      whereArgs: [cutoff],
    );
  }

  Future<int> getCacheCount() async {
    final db = await _db;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM music_cache',
    );
    return (result.first['count'] as num?)?.toInt() ?? 0;
  }
}

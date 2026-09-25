import 'package:sqflite/sqflite.dart';

import 'musi_database.dart';

class SearchHistoryDao {
  Future<Database> get _db async => await MusiDatabase.instance.database;

  Future<void> saveSearchQuery(String query) async {
    final cleanQuery = query.trim().toLowerCase();
    if (cleanQuery.isEmpty) return;

    final db = await _db;
    await db.insert('search_history', {
      'query': cleanQuery,
      'searched_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<String>> getRecentSearches({int limit = 10}) async {
    final db = await _db;
    final maps = await db.query(
      'search_history',
      orderBy: 'searched_at DESC',
      limit: limit,
    );
    return maps.map((m) => m['query'] as String).toList();
  }

  Future<void> clearSearchHistory() async {
    final db = await _db;
    await db.delete('search_history');
  }

  Future<int> getSearchCount() async {
    final db = await _db;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM search_history',
    );
    return (result.first['count'] as num?)?.toInt() ?? 0;
  }
}

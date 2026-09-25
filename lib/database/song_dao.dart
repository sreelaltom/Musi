import 'package:sqflite/sqflite.dart';

import '../models/song.dart';
import 'musi_database.dart';

class SongDao {
  Future<Database> get _db async => await MusiDatabase.instance.database;

  // Insert or update song
  Future<void> upsertSong(Song song) async {
    final db = await _db;
    await db.insert(
      'songs',
      song.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // Bulk upsert
  Future<void> upsertSongs(List<Song> songs) async {
    final db = await _db;
    final batch = db.batch();
    for (final song in songs) {
      batch.insert(
        'songs',
        song.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  // Get song by ID
  Future<Song?> getSongById(String id) async {
    final db = await _db;
    final maps = await db.query('songs', where: 'id = ?', whereArgs: [id]);
    if (maps.isNotEmpty) {
      return Song.fromMap(maps.first);
    }
    return null;
  }

  // Like / Unlike operations
  Future<void> setLiked(Song song, bool liked) async {
    final db = await _db;
    await upsertSong(song.copyWith(isLiked: liked));

    if (liked) {
      await db.insert('liked_songs', {
        'song_id': song.id,
        'created_at': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } else {
      await db.delete(
        'liked_songs',
        where: 'song_id = ?',
        whereArgs: [song.id],
      );
    }
  }

  // Get all liked songs
  Future<List<Song>> getLikedSongs() async {
    final db = await _db;
    final maps = await db.rawQuery('''
      SELECT s.* FROM songs s
      INNER JOIN liked_songs ls ON s.id = ls.song_id
      ORDER BY ls.created_at DESC
    ''');
    return maps.map((m) => Song.fromMap(m)).toList();
  }

  // Check if song is liked
  Future<bool> isLiked(String songId) async {
    final db = await _db;
    final maps = await db.query(
      'liked_songs',
      where: 'song_id = ?',
      whereArgs: [songId],
    );
    return maps.isNotEmpty;
  }

  // Recently Played operations (limit to latest 50, newest first)
  Future<void> addRecentlyPlayed(Song song) async {
    final db = await _db;
    await upsertSong(song);

    await db.insert('recently_played', {
      'song_id': song.id,
      'played_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    // Keep only latest 50
    await db.execute('''
      DELETE FROM recently_played 
      WHERE song_id NOT IN (
        SELECT song_id FROM recently_played 
        ORDER BY played_at DESC 
        LIMIT 50
      )
    ''');
  }

  // Get recently played songs
  Future<List<Song>> getRecentlyPlayed() async {
    final db = await _db;
    final maps = await db.rawQuery('''
      SELECT s.* FROM songs s
      INNER JOIN recently_played rp ON s.id = rp.song_id
      ORDER BY rp.played_at DESC
      LIMIT 50
    ''');
    return maps.map((m) => Song.fromMap(m)).toList();
  }

  // Download status operations
  Future<void> setDownloadStatus(
    String songId, {
    required bool isDownloaded,
    String? localPath,
  }) async {
    final db = await _db;
    await db.update(
      'songs',
      {'is_downloaded': isDownloaded ? 1 : 0, 'local_path': localPath},
      where: 'id = ?',
      whereArgs: [songId],
    );
  }

  // Get all downloaded songs
  Future<List<Song>> getDownloadedSongs() async {
    final db = await _db;
    final maps = await db.query(
      'songs',
      where: 'is_downloaded = ?',
      whereArgs: [1],
    );
    return maps.map((m) => Song.fromMap(m)).toList();
  }
}

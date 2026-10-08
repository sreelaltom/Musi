import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../models/artist_mix_recent.dart';
import '../models/song.dart';
import '../models/youtube_music_result.dart';
import 'musi_database.dart';

class ArtistMixRecentDao {
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Future<Database> get _db async => MusiDatabase.instance.database;

  Future<void> save({
    required String artist,
    required List<Song> songs,
    required List<YouTubeMusicResult> videos,
  }) async {
    final cleanArtist = artist.trim();
    if (cleanArtist.isEmpty || (songs.isEmpty && videos.isEmpty)) return;

    final db = await _db;
    await db.insert(
      'recent_artist_mixes',
      ArtistMixRecent.toMap(
        artist: cleanArtist,
        songs: songs,
        videos: videos,
        playedAt: DateTime.now(),
      ),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    revision.value++;
  }

  Future<List<ArtistMixRecent>> getRecent({int limit = 10}) async {
    final db = await _db;
    final rows = await db.query(
      'recent_artist_mixes',
      orderBy: 'played_at DESC',
      limit: limit,
    );
    return rows.map(ArtistMixRecent.fromMap).toList();
  }
}

import 'package:sqflite/sqflite.dart';

import '../models/youtube_music_result.dart';
import 'musi_database.dart';

class YouTubeLikesDao {
  Future<Database> get _db async => await MusiDatabase.instance.database;

  Future<void> likeYouTubeVideo(YouTubeMusicResult video) async {
    final db = await _db;
    await db.insert('liked_youtube', {
      'video_id': video.videoId,
      'title': video.title,
      'channel_title': video.channelTitle,
      'thumbnail_url': video.thumbnailUrl,
      'youtube_url': video.youtubeUrl,
      'created_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> unlikeYouTubeVideo(String videoId) async {
    final db = await _db;
    await db.delete(
      'liked_youtube',
      where: 'video_id = ?',
      whereArgs: [videoId],
    );
  }

  Future<bool> isYouTubeLiked(String videoId) async {
    final db = await _db;
    final maps = await db.query(
      'liked_youtube',
      where: 'video_id = ?',
      whereArgs: [videoId],
    );
    return maps.isNotEmpty;
  }

  Future<List<YouTubeMusicResult>> getLikedYouTubeVideos() async {
    final db = await _db;
    final maps = await db.query('liked_youtube', orderBy: 'created_at DESC');
    return maps
        .map(
          (m) => YouTubeMusicResult(
            videoId: m['video_id'] as String,
            title: m['title'] as String,
            channelTitle: m['channel_title'] as String,
            thumbnailUrl: m['thumbnail_url'] as String? ?? '',
            youtubeUrl: m['youtube_url'] as String,
            sourceType: MusicSourceType.youtube,
          ),
        )
        .toList();
  }

  Future<int> getLikedYouTubeCount() async {
    final db = await _db;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM liked_youtube',
    );
    return (result.first['count'] as num?)?.toInt() ?? 0;
  }
}

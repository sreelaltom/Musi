import 'package:sqflite/sqflite.dart';

import '../models/playlist.dart';
import '../models/song.dart';
import '../models/playlist_item.dart';
import '../models/youtube_music_result.dart';
import '../models/music_cache_entry.dart';
import 'musi_database.dart';
import 'song_dao.dart';
import 'music_cache_dao.dart';

class PlaylistDao {
  Future<Database> get _db async => await MusiDatabase.instance.database;
  final SongDao _songDao = SongDao();
  final MusicCacheDao _cacheDao = MusicCacheDao();

  // Create playlist
  Future<void> createPlaylist(Playlist playlist) async {
    final db = await _db;
    await db.insert(
      'playlists',
      playlist.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // Rename playlist
  Future<void> renamePlaylist(String playlistId, String newName) async {
    final db = await _db;
    await db.update(
      'playlists',
      {'name': newName},
      where: 'id = ?',
      whereArgs: [playlistId],
    );
  }

  // Delete playlist
  Future<void> deletePlaylist(String playlistId) async {
    final db = await _db;
    await db.delete(
      'playlist_items',
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
    );
    await db.delete(
      'playlist_songs',
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
    );
    await db.delete('playlists', where: 'id = ?', whereArgs: [playlistId]);
  }

  // Add authorized song to playlist
  Future<void> addSongToPlaylist(String playlistId, Song song) async {
    final db = await _db;
    await _songDao.upsertSong(song);

    // Get max position
    final maxPosResult = await db.rawQuery(
      'SELECT MAX(position) as max_pos FROM playlist_items WHERE playlist_id = ?',
      [playlistId],
    );
    final currentMax = (maxPosResult.first['max_pos'] as int?) ?? -1;
    final newPos = currentMax + 1;

    final item = PlaylistItem.fromSong(
      playlistId: playlistId,
      song: song,
      position: newPos,
    );

    await db.insert(
      'playlist_items',
      item.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    // Also maintain backward compatibility with playlist_songs
    await db.insert('playlist_songs', {
      'playlist_id': playlistId,
      'song_id': song.id,
      'position': newPos,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  // Add YouTube video to playlist
  Future<void> addYouTubeToPlaylist(
    String playlistId,
    YouTubeMusicResult video,
  ) async {
    final db = await _db;

    // Get max position
    final maxPosResult = await db.rawQuery(
      'SELECT MAX(position) as max_pos FROM playlist_items WHERE playlist_id = ?',
      [playlistId],
    );
    final currentMax = (maxPosResult.first['max_pos'] as int?) ?? -1;
    final newPos = currentMax + 1;

    final item = PlaylistItem.fromYouTube(
      playlistId: playlistId,
      video: video,
      position: newPos,
    );

    await db.insert(
      'playlist_items',
      item.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    // Also cache the YouTube video
    await _cacheDao.upsertCacheEntry(MusicCacheEntry.fromYouTube(video: video));
  }

  // Remove item from playlist
  Future<void> removeItemFromPlaylist(
    String playlistId,
    String sourceId,
    PlaylistItemSourceType sourceType,
  ) async {
    final db = await _db;
    await db.delete(
      'playlist_items',
      where: 'playlist_id = ? AND source_id = ? AND source_type = ?',
      whereArgs: [playlistId, sourceId, sourceType.value],
    );

    // Also clean up old playlist_songs for authorized songs
    if (sourceType == PlaylistItemSourceType.authorized) {
      await db.delete(
        'playlist_songs',
        where: 'playlist_id = ? AND song_id = ?',
        whereArgs: [playlistId, sourceId],
      );
    }
  }

  // Reorder items in playlist
  Future<void> reorderPlaylistItems(
    String playlistId,
    List<String> orderedSourceIds,
    List<PlaylistItemSourceType> orderedSourceTypes,
  ) async {
    final db = await _db;
    final batch = db.batch();
    for (int i = 0; i < orderedSourceIds.length; i++) {
      batch.update(
        'playlist_items',
        {'position': i},
        where: 'playlist_id = ? AND source_id = ? AND source_type = ?',
        whereArgs: [
          playlistId,
          orderedSourceIds[i],
          orderedSourceTypes[i].value,
        ],
      );
    }
    await batch.commit(noResult: true);
  }

  // Get all playlists with items populated (supports both Song and YouTube)
  Future<List<Playlist>> getAllPlaylists() async {
    final db = await _db;
    final playlistMaps = await db.query(
      'playlists',
      orderBy: 'created_at DESC',
    );

    final List<Playlist> playlists = [];
    for (final pMap in playlistMaps) {
      final pId = pMap['id'] as String;

      // Query new playlist_items table
      final itemMaps = await db.rawQuery(
        '''
        SELECT * FROM playlist_items
        WHERE playlist_id = ?
        ORDER BY position ASC
      ''',
        [pId],
      );

      final songs = <Song>[];
      for (final itemMap in itemMaps) {
        final item = PlaylistItem.fromMap(itemMap);
        if (item.isAuthorized && item.songId != null) {
          // Try to get full song from songs table
          final songMaps = await db.query(
            'songs',
            where: 'id = ?',
            whereArgs: [item.songId],
          );
          if (songMaps.isNotEmpty) {
            songs.add(Song.fromMap(songMaps.first));
          } else {
            // Fallback to minimal song from cache/item data
            songs.add(
              Song(
                id: item.sourceId,
                title: item.title,
                artist: item.artistChannel ?? '',
                artworkUrl: item.artworkUrl,
                streamUrl: '',
                duration: 0,
              ),
            );
          }
        }
        // YouTube items are not added to songs list (handled separately)
      }

      playlists.add(Playlist.fromMap(pMap, songs: songs));
    }
    return playlists;
  }

  // Get playlist items with full resolution
  Future<List<PlaylistItem>> getPlaylistItems(String playlistId) async {
    final db = await _db;
    final itemMaps = await db.rawQuery(
      '''
      SELECT * FROM playlist_items
      WHERE playlist_id = ?
      ORDER BY position ASC
    ''',
      [playlistId],
    );
    return itemMaps.map((m) => PlaylistItem.fromMap(m)).toList();
  }

  // Backward compatibility methods for LibraryService
  Future<void> removeSongFromPlaylist(String playlistId, String songId) async {
    final db = await _db;
    await db.delete(
      'playlist_items',
      where: 'playlist_id = ? AND source_id = ? AND source_type = ?',
      whereArgs: [playlistId, songId, PlaylistItemSourceType.authorized.value],
    );
    await db.delete(
      'playlist_songs',
      where: 'playlist_id = ? AND song_id = ?',
      whereArgs: [playlistId, songId],
    );
  }

  Future<void> reorderPlaylistSongs(
    String playlistId,
    List<String> orderedSongIds,
  ) async {
    final db = await _db;
    final batch = db.batch();
    for (int i = 0; i < orderedSongIds.length; i++) {
      batch.update(
        'playlist_items',
        {'position': i},
        where: 'playlist_id = ? AND source_id = ? AND source_type = ?',
        whereArgs: [
          playlistId,
          orderedSongIds[i],
          PlaylistItemSourceType.authorized.value,
        ],
      );
      batch.update(
        'playlist_songs',
        {'position': i},
        where: 'playlist_id = ? AND song_id = ?',
        whereArgs: [playlistId, orderedSongIds[i]],
      );
    }
    await batch.commit(noResult: true);
  }
}

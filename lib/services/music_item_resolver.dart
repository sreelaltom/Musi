import 'package:flutter/foundation.dart';

import '../models/playlist_item.dart';
import '../models/song.dart';
import '../models/youtube_music_result.dart';
import '../models/music_cache_entry.dart';
import '../database/song_dao.dart';
import '../database/music_cache_dao.dart';
import '../database/youtube_likes_dao.dart';
import '../database/playlist_dao.dart';
import 'youtube_audio_service.dart';

enum PlaybackRouteType { playerService, unavailable }

class PlaybackResolution {
  final PlaybackRouteType route;
  final Song? song;
  final String? errorMessage;

  const PlaybackResolution._({
    required this.route,
    this.song,
    this.errorMessage,
  });

  factory PlaybackResolution.forPlayerService(Song song) =>
      PlaybackResolution._(route: PlaybackRouteType.playerService, song: song);

  factory PlaybackResolution.unavailable(String message) =>
      PlaybackResolution._(
        route: PlaybackRouteType.unavailable,
        errorMessage: message,
      );

  bool get isAvailable => route != PlaybackRouteType.unavailable;
}

class MusicItemResolver extends ChangeNotifier {
  static final MusicItemResolver _instance = MusicItemResolver._internal();
  factory MusicItemResolver() => _instance;
  MusicItemResolver._internal();

  final SongDao _songDao = SongDao();
  final MusicCacheDao _cacheDao = MusicCacheDao();
  final YouTubeLikesDao _youtubeLikesDao = YouTubeLikesDao();
  final PlaylistDao _playlistDao = PlaylistDao();

  Future<void> initialize() async {
    // Nothing special needed for initialization
  }

  /// Resolve a playlist item for playback
  Future<PlaybackResolution> resolvePlaylistItem(PlaylistItem item) async {
    if (item.isAuthorized) {
      return _resolveAuthorizedSong(item.sourceId);
    } else {
      return _resolveYouTubeVideo(item.youtubeVideoId ?? item.sourceId);
    }
  }

  /// Resolve an authorized song for playback
  Future<PlaybackResolution> _resolveAuthorizedSong(String songId) async {
    final song = await _songDao.getSongById(songId);
    if (song == null) {
      return PlaybackResolution.unavailable('Song not found in database');
    }

    // Check if local file exists (downloaded)
    if (song.localPath != null && song.localPath!.isNotEmpty) {
      // We could verify file exists here if needed
      await _cacheDao.updateLastPlayed(CachedSourceType.authorized, songId);
      return PlaybackResolution.forPlayerService(song);
    }

    // Check if authorized stream URL exists
    if (song.streamUrl.isNotEmpty && song.canStream) {
      await _cacheDao.updateLastPlayed(CachedSourceType.authorized, songId);
      return PlaybackResolution.forPlayerService(song);
    }

    return PlaybackResolution.unavailable(
      'This song cannot be played. No local file or authorized stream available.',
    );
  }

  /// Resolve a YouTube video for playback
  Future<PlaybackResolution> _resolveYouTubeVideo(String videoId) async {
    if (videoId.isEmpty) {
      return PlaybackResolution.unavailable('Invalid YouTube video ID');
    }

    // Check if cached
    final cached = await _cacheDao.getCacheEntry(
      CachedSourceType.youtube,
      videoId,
    );
    if (cached != null) {
      await _cacheDao.updateLastPlayed(CachedSourceType.youtube, videoId);
    }

    final video = YouTubeMusicResult(
      videoId: videoId,
      title: cached?.title ?? 'Unknown Title',
      channelTitle: cached?.artist ?? 'Unknown Channel',
      thumbnailUrl: cached?.thumbnailUrl ?? '',
      youtubeUrl: 'https://www.youtube.com/watch?v=$videoId',
    );

    // Try resolving to native audio stream for background playback
    try {
      final song = await YouTubeAudioService().resolveToSong(video);
      if (song != null) {
        return PlaybackResolution.forPlayerService(song);
      }
    } catch (_) {}

    return PlaybackResolution.unavailable(
      'Unable to resolve YouTube audio stream. The video may not be playable.',
    );
  }

  /// Resolve a Song object for playback (e.g., from search results)
  Future<PlaybackResolution> resolveSong(Song song) async {
    // First check database for download status
    final dbSong = await _songDao.getSongById(song.id);
    if (dbSong != null) {
      if (dbSong.localPath != null && dbSong.localPath!.isNotEmpty) {
        await _cacheDao.updateLastPlayed(CachedSourceType.authorized, song.id);
        return PlaybackResolution.forPlayerService(dbSong);
      }
      if (dbSong.streamUrl.isNotEmpty && dbSong.canStream) {
        await _cacheDao.updateLastPlayed(CachedSourceType.authorized, song.id);
        return PlaybackResolution.forPlayerService(dbSong);
      }
    }

    // Fall back to passed song object
    if (song.localPath != null && song.localPath!.isNotEmpty) {
      return PlaybackResolution.forPlayerService(song);
    }
    if (song.streamUrl.isNotEmpty && song.canStream) {
      return PlaybackResolution.forPlayerService(song);
    }

    return PlaybackResolution.unavailable(
      'This song cannot be played. No local file or authorized stream available.',
    );
  }

  /// Resolve a YouTubeMusicResult for playback
  Future<PlaybackResolution> resolveYouTubeVideo(
    YouTubeMusicResult video,
  ) async {
    await _cacheDao.updateLastPlayed(CachedSourceType.youtube, video.videoId);
    try {
      final song = await YouTubeAudioService().resolveToSong(video);
      if (song != null) {
        return PlaybackResolution.forPlayerService(song);
      }
     } catch (_) {}
    return PlaybackResolution.unavailable(
      'Unable to resolve YouTube audio stream. The video may not be playable.',
    );
  }

  /// Check if a YouTube video is liked
  Future<bool> isYouTubeLiked(String videoId) async {
    return _youtubeLikesDao.isYouTubeLiked(videoId);
  }

  /// Toggle YouTube like
  Future<void> toggleYouTubeLike(YouTubeMusicResult video) async {
    final liked = await _youtubeLikesDao.isYouTubeLiked(video.videoId);
    if (liked) {
      await _youtubeLikesDao.unlikeYouTubeVideo(video.videoId);
    } else {
      await _youtubeLikesDao.likeYouTubeVideo(video);
    }
    notifyListeners();
  }

  /// Get liked YouTube videos
  Future<List<YouTubeMusicResult>> getLikedYouTubeVideos() async {
    return _youtubeLikesDao.getLikedYouTubeVideos();
  }

  /// Get playlist items for a playlist with full resolution
  Future<List<PlaylistItem>> getPlaylistItems(String playlistId) async {
    return _playlistDao.getPlaylistItems(playlistId);
  }

  /// Resolve the next playable item in a playlist
  Future<PlaybackResolution?> resolveNextPlaylistItem(
    String playlistId,
    int currentIndex,
    List<PlaylistItem> items,
  ) async {
    if (items.isEmpty) return null;

    int nextIndex = currentIndex + 1;
    if (nextIndex >= items.length) {
      return null; // End of playlist
    }

    return resolvePlaylistItem(items[nextIndex]);
  }

  /// Resolve the previous playable item in a playlist
  Future<PlaybackResolution?> resolvePreviousPlaylistItem(
    String playlistId,
    int currentIndex,
    List<PlaylistItem> items,
  ) async {
    if (items.isEmpty) return null;

    int prevIndex = currentIndex - 1;
    if (prevIndex < 0) {
      return null; // Beginning of playlist
    }

    return resolvePlaylistItem(items[prevIndex]);
  }
}

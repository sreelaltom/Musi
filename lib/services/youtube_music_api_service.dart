import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt_exp;
import 'package:yt_flutter_musicapi/yt_flutter_musicapi.dart';

import '../models/youtube_music_result.dart';

/// Token for cancelling in-flight search requests
class CancelableToken {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() {
    _isCancelled = true;
  }
}

/// Service wrapping yt_flutter_musicapi (ytmusicapi + yt-dlp via Chaquopy Python bridge)
/// for YouTube Music search and playback. Android-only.
class YouTubeMusicApiService {
  static final YouTubeMusicApiService _instance =
      YouTubeMusicApiService._internal();
  factory YouTubeMusicApiService() => _instance;
  YouTubeMusicApiService._internal();

  YtFlutterMusicapi? _api;
  bool _isInitialized = false;

  /// Initialize the YouTube Music API (Android-only, requires Chaquopy Python bridge)
  Future<void> initialize() async {
    try {
      _api = YtFlutterMusicapi();
      final response = await _api!.initialize(country: 'US');
      _isInitialized = response.success;
      if (response.success) {
        debugPrint('YouTubeMusicApiService: initialized successfully');
      } else {
        debugPrint(
          'YouTubeMusicApiService: initialization failed: ${response.error}',
        );
      }
    } catch (e) {
      debugPrint('YouTubeMusicApiService: initialization failed: $e');
      _api = null;
      _isInitialized = false;
    }
  }

  bool get isInitialized => _isInitialized;

  /// Search YouTube Music for tracks
  Future<List<YouTubeMusicResult>> searchTracks(
    String query, {
    int limit = 25,
    CancelableToken? cancelable,
  }) async {
    if (_api == null || !_isInitialized) {
      debugPrint('YouTubeMusicApiService: not initialized');
      return [];
    }

    if (cancelable?.isCancelled == true) {
      return [];
    }

    try {
      final response = await _api!.searchMusic(
        query: query,
        limit: limit,
        includeAudioUrl: false,
        includeAlbumArt: true,
      );

      if (cancelable?.isCancelled == true) {
        return [];
      }

      if (!response.success || response.data == null) {
        debugPrint('YouTubeMusicApiService: search failed: ${response.error}');
        return [];
      }

      final List<YouTubeMusicResult> filtered = [];
      for (final item in response.data!) {
        if (cancelable?.isCancelled == true) {
          return [];
        }

        final videoId = item.videoId;
        final title = item.title;
        final artist = item.artists;
        final durationStr = item.duration;
        final thumbnail = item.albumArt;

         if (videoId.isEmpty || title == 'Unknown') continue;

        // Parse duration (format: "MM:SS" or "HH:MM:SS")
        final durationSeconds = _parseDuration(durationStr);
        if (durationSeconds == null) continue;

        filtered.add(
          YouTubeMusicResult(
            videoId: videoId,
            title: title,
            channelTitle: artist,
            thumbnailUrl: thumbnail ?? '',
            youtubeUrl: 'https://www.youtube.com/watch?v=$videoId',
            durationSeconds: durationSeconds,
          ),
        );
      }

      return filtered;
    } catch (e) {
      debugPrint('YouTubeMusicApiService: search failed: $e');
      return [];
    }
  }

  /// Fetch 10 trending/popular music tracks from YouTube for the Homepage.
  /// Dual strategy: tries yt_flutter_musicapi first, falls back to YoutubeExplode pure Dart.
  Future<List<YouTubeMusicResult>> getTrendingHits({int limit = 10}) async {
    // 1. Try Python bridge if initialized
    if (_api != null && _isInitialized) {
      try {
        final results = await searchTracks('Trending Hits', limit: limit);
        if (results.isNotEmpty) {
          return results.take(limit).toList();
        }
      } catch (e) {
        debugPrint(
          'YouTubeMusicApiService: getTrendingHits Python search failed: $e',
        );
      }
    }

    // 2. Pure-Dart YoutubeExplode fallback
    yt_exp.YoutubeExplode? yt;
    try {
      yt = yt_exp.YoutubeExplode();
      final search = await yt.search.search('popular songs lyrical');
      final tracks = <YouTubeMusicResult>[];
      for (final v in search) {
        final secs = v.duration?.inSeconds ?? 0;
        // Filter for individual songs between 1.5 min and 8 min
        if (secs >= 90 && secs <= 480) {
          tracks.add(
            YouTubeMusicResult(
              videoId: v.id.value,
              title: v.title,
              channelTitle: v.author,
              thumbnailUrl: v.thumbnails.mediumResUrl,
              youtubeUrl: 'https://www.youtube.com/watch?v=${v.id.value}',
              durationSeconds: secs,
            ),
          );
          if (tracks.length == limit) break;
        }
      }
      return tracks;
    } catch (e) {
      debugPrint(
        'YouTubeMusicApiService: getTrendingHits YoutubeExplode fallback failed: $e',
      );
      return [];
    } finally {
      yt?.close();
    }
  }

  /// Get stream URL for a YouTube Music video
  Future<String?> getStreamUrl(String videoId) async {
    if (_api == null || !_isInitialized) return null;

    try {
      final response = await _api!.getAudioUrlFast(videoId: videoId);
      if (response.success && response.data != null) {
        return response.data;
      }
      debugPrint(
        'YouTubeMusicApiService: getStreamUrl failed: ${response.error}',
      );
      return null;
    } catch (e) {
      debugPrint('YouTubeMusicApiService: getStreamUrl failed: $e');
      return null;
    }
  }

  /// Get video details by searching for the video
  Future<YouTubeMusicResult?> getVideoDetails(String videoId) async {
    if (_api == null || !_isInitialized) return null;

    try {
      // Search for the video by its ID using a broad query
      // The package doesn't have a direct getVideoDetails endpoint,
      // so we search and find by videoId
      final response = await _api!.searchMusic(
        query: videoId,
        limit: 10,
        includeAudioUrl: false,
        includeAlbumArt: true,
      );

      if (!response.success || response.data == null) {
        debugPrint(
          'YouTubeMusicApiService: getVideoDetails search failed: ${response.error}',
        );
        return null;
      }

      // Find the matching video by ID
      for (final item in response.data!) {
        if (item.videoId == videoId) {
          final title = item.title;
          final artist = item.artists;
          final durationStr = item.duration;
          final thumbnail = item.albumArt;

          final durationSeconds = _parseDuration(durationStr) ?? 0;

          return YouTubeMusicResult(
            videoId: videoId,
            title: title,
            channelTitle: artist,
            thumbnailUrl: thumbnail ?? '',
            youtubeUrl: 'https://www.youtube.com/watch?v=$videoId',
            durationSeconds: durationSeconds,
          );
        }
      }

      // Fallback: return basic info if video not found in search
      return YouTubeMusicResult(
        videoId: videoId,
        title: 'Unknown Title',
        channelTitle: 'Unknown Channel',
        thumbnailUrl: '',
        youtubeUrl: 'https://www.youtube.com/watch?v=$videoId',
        durationSeconds: 0,
      );
    } catch (e) {
      debugPrint('YouTubeMusicApiService: getVideoDetails failed: $e');
      return null;
    }
  }

  /// Parse duration string to seconds
  int? _parseDuration(String? durationStr) {
    if (durationStr == null || durationStr.isEmpty) return null;

    final parts = durationStr.split(':');
    if (parts.length == 2) {
      final minutes = int.tryParse(parts[0]);
      final seconds = int.tryParse(parts[1]);
      if (minutes != null && seconds != null) {
        return minutes * 60 + seconds;
      }
    } else if (parts.length == 3) {
      final hours = int.tryParse(parts[0]);
      final minutes = int.tryParse(parts[1]);
      final seconds = int.tryParse(parts[2]);
      if (hours != null && minutes != null && seconds != null) {
        return hours * 3600 + minutes * 60 + seconds;
      }
    }
    return null;
  }
}

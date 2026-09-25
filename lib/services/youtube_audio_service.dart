import 'dart:async';
import 'dart:io';import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/song.dart';
import '../models/youtube_music_result.dart';
import 'youtube_music_api_service.dart';

/// Service responsible for resolving YouTube audio streams
/// for native background playback via Musi's AudioService and just_audio.
///
/// KEY FIX: Uses requireWatchPage: false to bypass YouTube Watch Page
/// rate-limiting. Without this, every stream resolution hits the YouTube
/// Watch Page which rate-limits aggressively, causing HTTP 403 on CDN URLs.
/// With requireWatchPage: false, all Range headers return HTTP 206.
///
/// MULTI-CLIENT FALLBACK: Tries multiple YouTube API clients in order:
/// androidSdkless → android → ios → mweb
/// This ensures songs not available on one client still play on another.
class YouTubeAudioService {
  static const String youtubeUserAgent =
      'com.google.android.youtube/21.36.40 (Linux; U; Android 11) gzip';

  static final YouTubeAudioService _instance = YouTubeAudioService._internal();
  factory YouTubeAudioService() => _instance;
  YouTubeAudioService._internal();

  final YouTubeMusicApiService _apiService = YouTubeMusicApiService();

  // Shared YoutubeExplode instance — reused across calls to avoid socket leaks
  final YoutubeExplode _yt = YoutubeExplode();

  // In-memory stream URL cache keyed by videoId
  final Map<String, _CachedStream> _streamCache = {};

  // Track in-flight resolve operations to prevent duplicate concurrent requests
  final Map<String, Future<ResolvedAudioStream?>> _inflight = {};

  /// Resolves a playable audio stream for [videoId].
  ///
  /// Deduplicates concurrent calls for the same videoId — if a resolve is
  /// already in progress for a videoId, subsequent callers await the same
  /// Future instead of starting a new network request.
  Future<ResolvedAudioStream?> resolveStream(
    String videoId, {
    bool forceRefresh = false,
  }) async {
    if (videoId.isEmpty) return null;

    // Return cached URL if still fresh (YouTube URLs expire ~6h, cache 90min)
    if (!forceRefresh) {
      final cached = _streamCache[videoId];
      if (cached != null && !cached.isExpired) {
        debugPrint('YouTubeAudioService: Cache hit for $videoId');
        return ResolvedAudioStream(
          url: cached.url,
          totalBytes: cached.totalBytes,
        );
      }
    }

    // Deduplicate in-flight requests for the same videoId
    if (_inflight.containsKey(videoId)) {
      debugPrint('YouTubeAudioService: Awaiting in-flight resolve for $videoId');
      return _inflight[videoId];
    }

    final future = _doResolve(videoId);
    _inflight[videoId] = future;
    try {
      final result = await future;
      return result;
    } finally {
      _inflight.remove(videoId);
    }
  }

  Future<ResolvedAudioStream?> _doResolve(String videoId) async {
    debugPrint(
      'YouTubeAudioService: Resolving stream for $videoId',
    );

     // Strategy 1: YoutubeExplode with requireWatchPage: false
     // Try multiple YouTube API clients in order:
     // android first (matches our YouTube app User-Agent), then fallbacks
     // KEY FIX: requireWatchPage: false avoids YouTube Watch Page rate-limiting.
     final clients = [
       (YoutubeApiClient.android,         'android'),
       (YoutubeApiClient.androidSdkless,  'androidSdkless'),
       (YoutubeApiClient.ios,            'ios'),
       (YoutubeApiClient.mweb,           'mweb'),
     ];

    for (final (client, clientName) in clients) {
      try {
        debugPrint(
          'YouTubeAudioService: Trying client $clientName for $videoId',
        );
        final manifest = await _yt.videos.streamsClient
            .getManifest(
              videoId,
              ytClients: [client],
              requireWatchPage: false, // KEY FIX: avoids Watch Page rate-limit
            )
            .timeout(const Duration(seconds: 20));

        final resolved = _bestStream(manifest, videoId);
        if (resolved != null) {
          debugPrint(
            'YouTubeAudioService: Stream URL resolved (${resolved.url.length} chars) for $videoId',
          );
          debugPrint(
            'YouTubeAudioService: has signature=${resolved.url.contains('sig=') || resolved.url.contains('&s=')} has expire=${resolved.url.contains('expire=') || resolved.url.contains('Expires')}',
          );

          // Validate the stream URL is accessible with our YouTube User-Agent.
          // This catches URLs that YouTube CDN rejects (403) before we pass
          // them to ExoPlayer, filtering unplayable results early.
          final isValid = await _validateStreamUrl(resolved.url);
          if (!isValid) {
            debugPrint(
              'YouTubeAudioService: ⚠️ Stream URL rejected by CDN (403) for $videoId via $clientName',
            );
            continue; // Try next client
          }

          _streamCache[videoId] = _CachedStream(
            resolved.url,
            resolved.totalBytes,
          );
          debugPrint(
            'YouTubeAudioService: ✅ Stream resolved via $clientName for $videoId',
          );
          return resolved;
        }
      } catch (e) {
        debugPrint(
          'YouTubeAudioService: Client $clientName failed for $videoId: $e',
        );
        // Continue to next client
      }
    }

    // Strategy 2: Fallback to YouTubeMusicApiService (yt-dlp Chaquopy bridge)
    try {
      if (_apiService.isInitialized) {
        debugPrint(
          'YouTubeAudioService: Falling back to yt-dlp bridge for $videoId',
        );
        final fastUrl = await _apiService.getStreamUrl(videoId);
        if (fastUrl != null && fastUrl.isNotEmpty) {
          // Validate yt-dlp URL too
          if (await _validateStreamUrl(fastUrl)) {
            _streamCache[videoId] = _CachedStream(fastUrl, 0);
            debugPrint(
              'YouTubeAudioService: ✅ Stream from yt-dlp for $videoId',
            );
            return ResolvedAudioStream(url: fastUrl, totalBytes: 0);
          }
        }
      }
    } catch (e) {
      debugPrint(
        'YouTubeAudioService: yt-dlp bridge failed for $videoId: $e',
      );
    }

    debugPrint('YouTubeAudioService: ❌ All strategies failed for $videoId');
    return null;
  }

  /// Validate that a stream URL is accessible with our YouTube User-Agent.
  /// Makes a HEAD request — if YouTube CDN returns 403, the URL won't
  /// work in ExoPlayer either, so we reject it early and try another client.
  Future<bool> _validateStreamUrl(String url) async {
    final httpClient = HttpClient();
    httpClient.userAgent = youtubeUserAgent;
    try {
      final uri = Uri.parse(url);
      if (uri.host.isEmpty) return false;

      final request = await httpClient.headUrl(uri);
      request.followRedirects = true;
      request.maxRedirects = 3;
      // Request only the first byte to verify accessibility
      request.headers.set('Range', 'bytes=0-0');

      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );

      final isValid = response.statusCode == 200 || response.statusCode == 206;
      if (!isValid) {
        debugPrint(
          'YouTubeAudioService: URL validation failed with status ${response.statusCode}',
        );
      }
      // Drain the response to free resources
      await response.drain();
      return isValid;
    } on SocketException {
      debugPrint('YouTubeAudioService: URL validation network error');
      return false;
    } on HandshakeException {
      debugPrint('YouTubeAudioService: URL validation TLS error');
      return false;
    } on TimeoutException {
      debugPrint('YouTubeAudioService: URL validation timed out');
      return false;
    } catch (e) {
      debugPrint('YouTubeAudioService: URL validation error: $e');
      return false;
    } finally {
      httpClient.close();
    }
  }

  /// Pick the best audio stream from a manifest.
  /// Priority: MP4/AAC (ExoPlayer native) → any audio-only → muxed
  ResolvedAudioStream? _bestStream(StreamManifest manifest, String videoId) {
    // 1. Prefer MP4/AAC (itag 140: 128kbps) — ExoPlayer native support
    final mp4 = manifest.audioOnly
        .where((s) => s.container == StreamContainer.mp4)
        .toList();
    if (mp4.isNotEmpty) {
      final best = mp4.reduce(
        (a, b) => a.bitrate.bitsPerSecond > b.bitrate.bitsPerSecond ? a : b,
      );
      return ResolvedAudioStream(
        url: best.url.toString(),
        totalBytes: best.size.totalBytes,
      );
    }

    // 2. Any audio-only (WebM/Opus — also supported by ExoPlayer)
    final audio = manifest.audioOnly.toList();
    if (audio.isNotEmpty) {
      final best = audio.reduce(
        (a, b) => a.bitrate.bitsPerSecond > b.bitrate.bitsPerSecond ? a : b,
      );
      return ResolvedAudioStream(
        url: best.url.toString(),
        totalBytes: best.size.totalBytes,
      );
    }

    // 3. Muxed stream (audio+video) as last resort
    final muxed = manifest.muxed.toList();
    if (muxed.isNotEmpty) {
      final best = muxed.reduce(
        (a, b) => a.bitrate.bitsPerSecond > b.bitrate.bitsPerSecond ? a : b,
      );
      return ResolvedAudioStream(
        url: best.url.toString(),
        totalBytes: best.size.totalBytes,
      );
    }

    return null;
  }

  /// Convenience method returning just the stream URL string.
  Future<String?> getAudioStreamUrl(
    String videoId, {
    bool forceRefresh = false,
  }) async {
    final resolved = await resolveStream(videoId, forceRefresh: forceRefresh);
    return resolved?.url;
  }

  /// Invalidate stream cache for a videoId (call when playback fails).
  void invalidateCache(String videoId) {
    _streamCache.remove(videoId);
  }

  /// Validate that a video ID can resolve to a playable audio stream.
  /// Uses cached URL if available, otherwise attempts resolution with validation.
  Future<bool> validatePlayable(String videoId) async {
    if (videoId.isEmpty) return false;

    // Check existing cache first (without expiration check for pre-filter)
    final cached = _streamCache[videoId];
    if (cached != null) {
      return true;
    }

    // Try resolving + validating the stream URL
    final resolved = await resolveStream(videoId);
    return resolved != null && resolved.url.isNotEmpty;
  }

  /// Filter a list of YouTube results to only include playable ones.
  /// Validates each video ID concurrently and returns only playable results.
  /// This is used before displaying results to ensure no source errors.
  Future<List<YouTubeMusicResult>> filterPlayable(
    List<YouTubeMusicResult> results,
  ) async {
    if (results.isEmpty) return [];

    final validationResults = await Future.wait(
      results.map((video) async {
        final playable = await validatePlayable(video.videoId);
        return MapEntry(video, playable);
      }),
    );

    final playable = validationResults
        .where((entry) => entry.value)
        .map((entry) => entry.key)
        .toList();

    debugPrint(
      'YouTubeAudioService: filterPlayable: ${playable.length}/${results.length} '
      'results are playable',
    );

    return playable;
  }

  /// Converts a YouTubeMusicResult into a playable Song object.
  Future<Song?> resolveToSong(YouTubeMusicResult video) async {
    final resolved = await resolveStream(video.videoId);
    if (resolved == null || resolved.url.isEmpty) {
      return null;
    }

    return Song(
      id: 'yt_${video.videoId}',
      title: video.title,
      artist: video.channelTitle.isNotEmpty ? video.channelTitle : 'YouTube',
      album: 'YouTube Music',
      artworkUrl: video.thumbnailUrl.isNotEmpty ? video.thumbnailUrl : null,
      streamUrl: resolved.url,
      sourceUrl: video.youtubeUrl,
      duration: video.durationSeconds ?? 0,
      providerId: 'youtube',
      providerName: 'YouTube',
      isDownloaded: false,
    );
  }

  /// Check if a Song is a YouTube-sourced song
  static bool isYouTubeSong(Song song) {
    return song.id.startsWith('yt_') || song.providerId == 'youtube';
  }

  /// Extract video ID from a YouTube Song
  static String? extractVideoId(Song song) {
    if (song.id.startsWith('yt_')) {
      return song.id.substring(3);
    }
    if (song.sourceUrl != null && song.sourceUrl!.contains('v=')) {
      final uri = Uri.tryParse(song.sourceUrl!);
      return uri?.queryParameters['v'];
    }
    return null;
  }

  void dispose() {
    _yt.close();
  }
}

/// Resolved stream: playback URL + total byte size.
class ResolvedAudioStream {
  final String url;
  final int totalBytes;
  const ResolvedAudioStream({required this.url, required this.totalBytes});
}

class _CachedStream {
  final String url;
  final int totalBytes;
  final DateTime createdAt;

  _CachedStream(this.url, this.totalBytes) : createdAt = DateTime.now();

  // Cache for 90 minutes (YouTube URLs expire in ~6h)
  bool get isExpired =>
      DateTime.now().difference(createdAt) > const Duration(minutes: 90);
}

import 'dart:async';
import 'package:flutter/foundation.dart';
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
///
/// VALIDATION REMOVED: HEAD-request pre-validation was causing false
/// rejections (YouTube CDN returns 403 on HEAD even for valid URLs).
/// We let ExoPlayer be the validator — if it 403s, PlayerService catches
/// the error, calls invalidateCache() + resolveStream(forceRefresh: true),
/// and retries with a fresh URL from the next client.
///
/// MULTI-CLIENT FALLBACK: Tries multiple YouTube API clients in order:
/// android → androidSdkless → ios → mweb → androidVr
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

  // Track which client index to try next per videoId (rotates on 403)
  final Map<String, int> _clientIndex = {};

  /// Resolves a playable audio stream for [videoId].
  ///
  /// On forceRefresh: advances to the next client in the cascade so repeated
  /// failures cycle through all clients instead of retrying the same one.
  Future<ResolvedAudioStream?> resolveStream(
    String videoId, {
    bool forceRefresh = false,
  }) async {
    if (videoId.isEmpty) return null;

    // Return cached URL if still fresh (cache 10min — conservative to avoid stale)
    if (!forceRefresh) {
      final cached = _streamCache[videoId];
      if (cached != null && !cached.isExpired) {
        debugPrint('YouTubeAudioService: Cache hit for $videoId');
        return ResolvedAudioStream(
          url: cached.url,
          totalBytes: cached.totalBytes,
          headers: cached.headers,
        );
      }
    }

    // Deduplicate in-flight requests for the same videoId
    if (!forceRefresh && _inflight.containsKey(videoId)) {
      debugPrint('YouTubeAudioService: Awaiting in-flight resolve for $videoId');
      return _inflight[videoId];
    }

    final future = _doResolve(videoId, forceRefresh: forceRefresh);
    _inflight[videoId] = future;
    try {
      final result = await future;
      return result;
    } finally {
      _inflight.remove(videoId);
    }
  }

  /// All supported clients in priority order with their matching request headers.
  /// NOTE: Must be `final` not `const` — YoutubeApiClient is not a const type.
  static final _allClients = [
    (
      YoutubeApiClient.androidSdkless,
      'androidSdkless',
      const {'User-Agent': 'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip'},
    ),
    (
      YoutubeApiClient.android,
      'android',
      const {'User-Agent': 'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip'},
    ),
    (
      YoutubeApiClient.ios,
      'ios',
      const {'User-Agent': 'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)'},
    ),
    (
      YoutubeApiClient.mweb,
      'mweb',
      const {'User-Agent': 'Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36'},
    ),
    (
      YoutubeApiClient.androidVr,
      'androidVr',
      const {'User-Agent': 'Mozilla/5.0 (Linux; Android 10; Quest 2) AppleWebKit/537.36 (KHTML, like Gecko) OculusBrowser/15.0.0.499887770 Safari/537.36'},
    ),
  ];

  Future<ResolvedAudioStream?> _doResolve(
    String videoId, {
    bool forceRefresh = false,
  }) async {
    debugPrint('YouTubeAudioService: Resolving stream for $videoId (forceRefresh=$forceRefresh)');

    if (forceRefresh) {
      // On 403 retry: race yt-dlp vs next YoutubeExplode client in parallel.
      // We need FIRST SUCCESS — not Future.any which fires on the first error too.
      final current = _clientIndex[videoId] ?? 0;
      final nextIdx = (current + 1) % _allClients.length;
      _clientIndex[videoId] = nextIdx;
      final (nextClient, nextClientName, nextHeaders) = _allClients[nextIdx];

      debugPrint('YouTubeAudioService: 403 retry — racing yt-dlp vs $nextClientName for $videoId');

      ResolvedAudioStream? result;
      try {
        // Race two futures but only complete on FIRST SUCCESS (ignore individual errors)
        final completer = Completer<ResolvedAudioStream?>();
        int pending = 2;

        void onResult(ResolvedAudioStream? r, String source) {
          if (r != null && !completer.isCompleted) {
            debugPrint('YouTubeAudioService: $source won race for $videoId');
            completer.complete(r);
          } else {
            pending--;
            if (pending == 0 && !completer.isCompleted) completer.complete(null);
          }
        }

        // yt-dlp: deciphers n-param → URL works for all Range requests
        _apiService.getStreamWithHeaders(videoId).then((data) {
          if (data == null || (data['url'] as String? ?? '').isEmpty) {
            onResult(null, 'yt-dlp');
            return;
          }
          final url = data['url'] as String;
          final rawH = data['headers'];
          Map<String, String> h = {};
          if (rawH is Map) h = rawH.map((k, v) => MapEntry(k.toString(), v.toString()));
          if (!h.containsKey('User-Agent')) {
            h['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
          }
          onResult(ResolvedAudioStream(url: url, totalBytes: 0, headers: h), 'yt-dlp');
        }).catchError((e) {
          debugPrint('YouTubeAudioService: yt-dlp race error: $e');
          onResult(null, 'yt-dlp');
        });

        // Next YoutubeExplode client: fast < 3s
        _yt.videos.streamsClient
            .getManifest(videoId, ytClients: [nextClient], requireWatchPage: false)
            .timeout(const Duration(seconds: 20))
            .then((manifest) {
              final resolved = _bestStream(manifest, videoId);
              if (resolved == null) { onResult(null, nextClientName); return; }
              onResult(
                ResolvedAudioStream(url: resolved.url, totalBytes: resolved.totalBytes, headers: nextHeaders),
                nextClientName,
              );
            }).catchError((e) {
              debugPrint('YouTubeAudioService: $nextClientName race error: $e');
              onResult(null, nextClientName);
            });

        result = await completer.future;
      } catch (e) {
        debugPrint('YouTubeAudioService: race completer error: $e');
        result = null;
      }

      if (result != null) {
        _streamCache[videoId] = _CachedStream(result.url, result.totalBytes, headers: result.headers);
        return result;
      }

      // Both failed — try remaining YoutubeExplode clients sequentially
      debugPrint('YouTubeAudioService: race failed, trying remaining clients for $videoId');
      for (int i = 0; i < _allClients.length; i++) {
        final idx = (nextIdx + 1 + i) % _allClients.length;
        if (idx == nextIdx) continue;
        final (client, clientName, headers) = _allClients[idx];
        try {
          final manifest = await _yt.videos.streamsClient
              .getManifest(videoId, ytClients: [client], requireWatchPage: false)
              .timeout(const Duration(seconds: 20));
          final resolved = _bestStream(manifest, videoId);
          if (resolved == null) continue;
          debugPrint('YouTubeAudioService: ✅ $clientName resolved on fallback for $videoId');
          _clientIndex[videoId] = idx;
          final r = ResolvedAudioStream(url: resolved.url, totalBytes: resolved.totalBytes, headers: headers);
          _streamCache[videoId] = _CachedStream(r.url, r.totalBytes, headers: r.headers);
          return r;
        } catch (e) {
          debugPrint('YouTubeAudioService: $clientName failed: $e');
        }
      }

      debugPrint('YouTubeAudioService: ❌ All retry strategies failed for $videoId');
      return null;
    }

    // ── Fresh resolve (no forceRefresh) ──────────────────────────────────────
    // Use YoutubeExplode cascade for fast start (<3s). If a song consistently
    // 403s mid-stream, the error handler above retries with yt-dlp + next client.
    final startIndex = _clientIndex[videoId] ?? 0;

    for (int i = 0; i < _allClients.length; i++) {
      final idx = (startIndex + i) % _allClients.length;
      final (client, clientName, headers) = _allClients[idx];

      try {
        debugPrint('YouTubeAudioService: Trying client $clientName for $videoId');
        final manifest = await _yt.videos.streamsClient
            .getManifest(videoId, ytClients: [client], requireWatchPage: false)
            .timeout(const Duration(seconds: 20));

        final resolved = _bestStream(manifest, videoId);
        if (resolved == null) continue;

        debugPrint(
          'YouTubeAudioService: ✅ Stream resolved via $clientName for $videoId '
          '(${resolved.url.length} chars)',
        );

        _clientIndex[videoId] = idx;
        _streamCache[videoId] = _CachedStream(
          resolved.url,
          resolved.totalBytes,
          headers: headers,
        );
        return ResolvedAudioStream(
          url: resolved.url,
          totalBytes: resolved.totalBytes,
          headers: headers,
        );
      } catch (e) {
        debugPrint('YouTubeAudioService: Client $clientName failed for $videoId: $e');
      }
    }

    // All YoutubeExplode clients failed — try yt-dlp as last resort
    debugPrint('YouTubeAudioService: All YE clients failed, trying yt-dlp for $videoId');
    try {
      final streamData = await _apiService.getStreamWithHeaders(videoId);
      if (streamData != null) {
        final fastUrl = streamData['url'] as String? ?? '';
        final rawHeaders = streamData['headers'];
        Map<String, String> ytdlpHeaders = {};
        if (rawHeaders is Map) {
          ytdlpHeaders = rawHeaders.map((k, v) => MapEntry(k.toString(), v.toString()));
        }
        if (!ytdlpHeaders.containsKey('User-Agent')) {
          ytdlpHeaders['User-Agent'] =
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
        }
        if (fastUrl.isNotEmpty) {
          _streamCache[videoId] = _CachedStream(fastUrl, 0, headers: ytdlpHeaders);
          debugPrint('YouTubeAudioService: ✅ yt-dlp last-resort resolved for $videoId');
          return ResolvedAudioStream(url: fastUrl, totalBytes: 0, headers: ytdlpHeaders);
        }
      }
    } catch (e) {
      debugPrint('YouTubeAudioService: yt-dlp last-resort failed for $videoId: $e');
    }

    debugPrint('YouTubeAudioService: ❌ All strategies failed for $videoId');
    return null;
  }

  /// Pick the best audio stream from a manifest.
  /// Priority: MP4/AAC (ExoPlayer native) → WebM/Opus → muxed
  ResolvedAudioStream? _bestStream(StreamManifest manifest, String videoId) {
    // 1. Prefer MP4/AAC (itag 140: 128kbps) — ExoPlayer native, most compatible
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
    debugPrint('YouTubeAudioService: Cache invalidated for $videoId');
  }

  /// Converts a YouTubeMusicResult into a playable Song object.
  Future<Song?> resolveToSong(
    YouTubeMusicResult video, {
    bool forceRefresh = false,
  }) async {
    String? streamUrl;
    Map<String, String>? headers;

    // Only use pre-resolved streamUrl if not forcing a fresh refresh
    if (!forceRefresh && video.streamUrl != null && video.streamUrl!.isNotEmpty) {
      streamUrl = video.streamUrl;
      debugPrint('YouTubeAudioService: Using pre-resolved streamUrl for ${video.videoId}');
    } else {
      final resolved = await resolveStream(video.videoId, forceRefresh: forceRefresh);
      streamUrl = resolved?.url;
      headers = resolved?.headers;
    }

    if (streamUrl == null || streamUrl.isEmpty) {
      return null;
    }

    return Song(
      id: 'yt_${video.videoId}',
      title: video.title,
      artist: video.channelTitle.isNotEmpty ? video.channelTitle : 'YouTube',
      album: 'YouTube Music',
      artworkUrl: video.thumbnailUrl.isNotEmpty ? video.thumbnailUrl : null,
      streamUrl: streamUrl,
      sourceUrl: video.youtubeUrl,
      duration: video.durationSeconds ?? 0,
      providerId: 'youtube',
      providerName: 'YouTube',
      isDownloaded: false,
      headers: headers,
    );
  }

  /// Check if a Song is a YouTube-sourced song.
  static bool isYouTubeSong(Song song) {
    return song.id.startsWith('yt_') || song.providerId == 'youtube';
  }

  /// Extract video ID from a YouTube Song.
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

  /// Validate that a video ID is valid.
  Future<bool> validatePlayable(String videoId) async {
    if (videoId.isEmpty) return false;
    return true;
  }

  /// Filter a list of YouTube results to ensure only valid, playable results are displayed.
  Future<List<YouTubeMusicResult>> filterPlayable(
    List<YouTubeMusicResult> results,
  ) async {
    if (results.isEmpty) return [];
    return results.where((v) {
      if (v.videoId.trim().isEmpty) return false;
      if (v.title == 'Unknown' || v.title.trim().isEmpty) return false;
      if (v.durationSeconds != null && v.durationSeconds! <= 0) return false;
      return true;
    }).toList();
  }

  void dispose() {
    _yt.close();
  }
}

/// Resolved stream: playback URL + total byte size + request headers.
class ResolvedAudioStream {
  final String url;
  final int totalBytes;
  final Map<String, String>? headers;
  const ResolvedAudioStream({
    required this.url,
    required this.totalBytes,
    this.headers,
  });
}

class _CachedStream {
  final String url;
  final int totalBytes;
  final Map<String, String>? headers;
  final DateTime createdAt;

  _CachedStream(this.url, this.totalBytes, {this.headers})
      : createdAt = DateTime.now();

  // Cache for 10 minutes — short TTL to prevent stale IP-bound token 403s
  bool get isExpired =>
      DateTime.now().difference(createdAt) > const Duration(minutes: 10);
}

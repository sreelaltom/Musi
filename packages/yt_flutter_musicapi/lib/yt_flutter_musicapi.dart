// lib/yt_flutter_musicapi.dart

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:yt_flutter_musicapi/models/artistAlbums.dart';
import 'package:yt_flutter_musicapi/models/artistsStreamModel.dart';
import 'package:yt_flutter_musicapi/models/audioUrlresultsModel.dart';
import 'package:yt_flutter_musicapi/models/chatModel.dart';
import 'package:yt_flutter_musicapi/models/getRadioModel.dart';
import 'package:yt_flutter_musicapi/models/lyricsModel.dart';
import 'package:yt_flutter_musicapi/models/relatedSongModel.dart';
import 'package:yt_flutter_musicapi/models/searchModel.dart';

import 'package:yt_flutter_musicapi/models/systemStatusModel.dart';

import 'yt_flutter_musicapi_platform_interface.dart';

/// Enum for Audio Quality
enum AudioQuality {
  low('LOW'),
  med('MED'),
  high('HIGH'),
  veryHigh('VERY_HIGH');

  const AudioQuality(this.value);
  final String value;
}

/// Enum for Thumbnail Quality
enum ThumbnailQuality {
  low('LOW'),
  med('MED'),
  high('HIGH'),
  veryHigh('VERY_HIGH');

  const ThumbnailQuality(this.value);
  final String value;
}

class ApiResponse<T> {
  final bool success;
  final String? message;
  final T? data;

  ApiResponse({
    required this.success,
    this.message,
    this.data,
  });

  factory ApiResponse.fromMap(Map<String, dynamic> map) {
    return ApiResponse<T>(
      success: map['success'] ?? false,
      message: map['message'],
      data: map['results'] as T?,
    );
  }
}

/// YouTube Music API Response wrapper
class YTMusicResponse<T> {
  final bool success;
  final T? data;
  final String? message;
  final String? error;
  final int? count;
  final int? processed;
  final int? errorCount;
  final List<Map<String, dynamic>>? errors;

  YTMusicResponse({
    required this.success,
    this.data,
    this.message,
    this.error,
    this.count,
    this.processed,
    this.errorCount,
    this.errors,
  });

  factory YTMusicResponse.fromMap(Map<String, dynamic> map) {
    // Handle batch mode responses that include processing stats
    if (map.containsKey('processed')) {
      return YTMusicResponse<T>(
        success: map['success'] ?? false,
        data: map['data'] as T?,
        message: map['message'],
        error: map['error'],
        count: map['count'] ??
            (map['data'] is List ? (map['data'] as List).length : null),
        processed: map['processed'],
        errorCount: map['error_count'],
        errors: map['errors'] is List
            ? List<Map<String, dynamic>>.from(map['errors'])
            : null,
      );
    }

    // Standard response handling
    return YTMusicResponse<T>(
      success: map['success'] ?? false,
      data: map['data'] as T?,
      message: map['message'],
      error: map['error'],
      count: map['count'] ??
          (map['data'] is List ? (map['data'] as List).length : null),
    );
  }
}

/// Main YtFlutterMusicapi class that provides access to YouTube Music API
class YtFlutterMusicapi {
  static final YtFlutterMusicapi _instance = YtFlutterMusicapi._internal();
  MethodChannel _channel = MethodChannel('yt_flutter_musicapi');

  static bool _isInitialized = false;
  static String? _lastError;

  final Map<String, List<SearchResult>> _searchCache = {};
  final Map<String, DateTime> _cacheTimestamps = {};
  static const _cacheDuration = Duration(minutes: 5);

  // Getters
  static String? get lastError => _lastError;

  factory YtFlutterMusicapi() => _instance;

  YtFlutterMusicapi._internal();

  /// Initializes the YouTube Music API
  Future<YTMusicResponse<void>> initialize({
    String? proxy,
    String country = 'US',
  }) async {
    try {
      final result = (await YtFlutterMusicapiPlatform.instance.initialize(
        proxy: proxy,
        country: country,
      ))
          .cast<String, dynamic>();
      _isInitialized = result['success'] ?? false;

      if (!_isInitialized) {
        throw Exception(result['error'] ?? 'Initialization failed');
      }

      return YTMusicResponse<void>(
        success: true,
        message: result['message'],
      );
    } catch (e) {
      return YTMusicResponse<void>(
        success: false,
        error: e.toString(),
      );
    }
  }

  /// Searches for music on YouTube Music
  Future<YTMusicResponse<List<SearchResult>>> searchMusic({
    required String query,
    int limit = 10,
    ThumbnailQuality thumbQuality = ThumbnailQuality.veryHigh,
    AudioQuality audioQuality = AudioQuality.veryHigh,
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
    bool useCache = true,
  }) async {
    // Check cache first
    if (useCache) {
      final cacheKey =
          '$query:$limit:${thumbQuality.value}:${audioQuality.value}:$includeAudioUrl:$includeAlbumArt';
      final cachedTime = _cacheTimestamps[cacheKey];

      if (cachedTime != null &&
          DateTime.now().difference(cachedTime) < _cacheDuration) {
        final cachedResults = _searchCache[cacheKey];
        if (cachedResults != null) {
          debugPrint(
              '✅ Using cached results for: $query (${cachedResults.length} items)');
          return YTMusicResponse<List<SearchResult>>(
            success: true,
            data: cachedResults,
            count: cachedResults.length,
            message: 'Results from cache',
          );
        }
      }
    }

    // If not in cache, fetch from API
    final response = await _executeApiCall<List<SearchResult>>(
      () async {
        try {
          final dynamic result =
              await YtFlutterMusicapiPlatform.instance.searchMusic(
            query: query,
            limit: limit,
            thumbQuality: thumbQuality.value,
            audioQuality: audioQuality.value,
            includeAudioUrl: includeAudioUrl,
            includeAlbumArt: includeAlbumArt,
          );

          debugPrint('Raw search results: ${result.runtimeType}');

          // Handle case where result might be a Map or already a List
          dynamic resultsData;
          if (result is Map<String, dynamic>) {
            resultsData = result['data'] ?? result['results'] ?? [];
          } else if (result is List) {
            resultsData = result;
          } else {
            throw Exception('Unexpected response type: ${result.runtimeType}');
          }

          // Ensure we have a List
          final List<dynamic> resultsList =
              resultsData is List ? resultsData : [resultsData];

          final List<SearchResult> searchResults = [];
          for (final item in resultsList) {
            try {
              if (item is Map) {
                final itemMap = Map<String, dynamic>.from(item);
                searchResults.add(SearchResult.fromMap(itemMap));
              } else {
                debugPrint('Skipping invalid item (not a Map): $item');
              }
            } catch (e, stackTrace) {
              debugPrint('Error processing item: $e\n$stackTrace\nItem: $item');
            }
          }

          debugPrint(
              'Successfully mapped ${searchResults.length} search results');
          return searchResults;
        } catch (e, stackTrace) {
          debugPrint('Error in searchMusic: $e\n$stackTrace');
          rethrow;
        }
      },
    );

    // Cache successful results
    if (response.success && response.data != null && useCache) {
      final cacheKey =
          '$query:$limit:${thumbQuality.value}:${audioQuality.value}:$includeAudioUrl:$includeAlbumArt';
      _searchCache[cacheKey] = response.data!;
      _cacheTimestamps[cacheKey] = DateTime.now();

      debugPrint('💾 Cached ${response.data!.length} results for: $query');

      // Limit cache size to prevent memory issues
      if (_searchCache.length > 50) {
        final oldestKey = _cacheTimestamps.entries
            .reduce((a, b) => a.value.isBefore(b.value) ? a : b)
            .key;
        _searchCache.remove(oldestKey);
        _cacheTimestamps.remove(oldestKey);
        debugPrint('🗑️ Removed oldest cache entry');
      }
    }

    return response;
  }

  /// Stream search results as they are found (experimental streaming support)
  Stream<SearchResult> streamSearchResults({
    required String query,
    int limit = 10,
    AudioQuality audioQuality = AudioQuality.veryHigh,
    ThumbnailQuality thumbQuality = ThumbnailQuality.veryHigh,
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
    void Function(int processed, int total)? onProgress,
  }) {
    final stream = YtFlutterMusicapiPlatform.instance.streamSearchResults(
      query: query,
      limit: limit,
      audioQuality: audioQuality.value,
      thumbQuality: thumbQuality.value,
      includeAudioUrl: includeAudioUrl,
      includeAlbumArt: includeAlbumArt,
    );

    var processedCount = 0;

    return stream.map((item) {
      processedCount++;
      if (onProgress != null) {
        onProgress(processedCount, limit);
      }
      return SearchResult.fromMap(item);
    });
  }

  /// Gets related songs for a given track
  Future<YTMusicResponse<List<RelatedSong>>> getRelatedSongs({
    required String songName,
    required String artistName,
    int limit = 10,
    ThumbnailQuality thumbQuality = ThumbnailQuality.veryHigh,
    AudioQuality audioQuality = AudioQuality.veryHigh,
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) async {
    return _executeApiCall(() async {
      final response = await YtFlutterMusicapiPlatform.instance.getRelatedSongs(
        songName: songName,
        artistName: artistName,
        limit: limit,
        thumbQuality: thumbQuality.value,
        audioQuality: audioQuality.value,
        includeAudioUrl: includeAudioUrl,
        includeAlbumArt: includeAlbumArt,
      );

      final responseMap = Map<String, dynamic>.from(response);
      final dynamic data = responseMap['data'];
      final List<dynamic> resultsList = data is List ? data : [data];

      return resultsList.map((item) {
        return RelatedSong.fromMap(Map<String, dynamic>.from(item));
      }).toList();
    });
  }

  Stream<RelatedSong> streamRelatedSongs({
    required String songName,
    required String artistName,
    int limit = 10,
    ThumbnailQuality thumbQuality = ThumbnailQuality.veryHigh,
    AudioQuality audioQuality = AudioQuality.veryHigh,
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) {
    return YtFlutterMusicapiPlatform.instance
        .streamRelatedSongs(
          songName: songName,
          artistName: artistName,
          limit: limit,
          thumbQuality: thumbQuality.value,
          audioQuality: audioQuality.value,
          includeAudioUrl: includeAudioUrl,
          includeAlbumArt: includeAlbumArt,
        )
        .map((item) => RelatedSong.fromMap(item));
  }

  Future<YTMusicResponse<List<ArtistSong>>> getArtistSongs({
    required String artistName,
    int limit = 25,
    ThumbnailQuality thumbQuality = ThumbnailQuality.veryHigh,
    AudioQuality audioQuality = AudioQuality.high,
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) async {
    return _executeApiCall(() async {
      final response = await YtFlutterMusicapiPlatform.instance.getArtistSongs(
        artistName: artistName,
        limit: limit,
        thumbQuality: thumbQuality.value,
        audioQuality: audioQuality.value,
        includeAudioUrl: includeAudioUrl,
        includeAlbumArt: includeAlbumArt,
      );

      final responseMap = Map<String, dynamic>.from(response);
      final dynamic data = responseMap['data'];
      final List<dynamic> items = data is List ? data : [data];

      return items.map((item) {
        return ArtistSong.fromMap({
          ...Map<String, dynamic>.from(item),
          'artistName': artistName,
        });
      }).toList();
    });
  }

  /// Get charts data as a batch operation
  Future<YTMusicResponse<List<ChartItem>>> getCharts({
    String country = 'ZZ',
    int limit = 50,
    ThumbnailQuality thumbQuality = ThumbnailQuality.veryHigh,
    AudioQuality audioQuality = AudioQuality.high,
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) async {
    return _executeApiCall(() async {
      final response = await YtFlutterMusicapiPlatform.instance.getCharts(
        country: country,
        limit: limit,
        thumbQuality: thumbQuality.value,
        audioQuality: audioQuality.value,
        includeAudioUrl: includeAudioUrl,
        includeAlbumArt: includeAlbumArt,
      );

      final responseMap = Map<String, dynamic>.from(response);
      final dynamic data = responseMap['data'];
      final List<dynamic> items = data is List ? data : [data];

      return items.map((item) {
        return ChartItem.fromMap(Map<String, dynamic>.from(item));
      }).toList();
    });
  }

  Stream<ArtistSong> streamArtistSongs({
    required String artistName,
    int limit = 25,
    ThumbnailQuality thumbQuality = ThumbnailQuality.veryHigh,
    AudioQuality audioQuality = AudioQuality.high,
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) {
    return YtFlutterMusicapiPlatform.instance
        .streamArtistSongs(
          artistName: artistName,
          limit: limit,
          thumbQuality: thumbQuality.value,
          audioQuality: audioQuality.value,
          includeAudioUrl: includeAudioUrl,
          includeAlbumArt: includeAlbumArt,
        )
        .map((item) => ArtistSong.fromMap(item));
  }

  /// Stream radio tracks based on a video ID
  Stream<RadioTrack> streamRadio({
    required String videoId,
    int limit = 50,
    ThumbnailQuality thumbQuality = ThumbnailQuality.veryHigh,
    AudioQuality audioQuality = AudioQuality.high,
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) {
    return YtFlutterMusicapiPlatform.instance
        .streamRadio(
          videoId: videoId,
          limit: limit,
          thumbQuality: thumbQuality.value,
          audioQuality: audioQuality.value,
          includeAudioUrl: includeAudioUrl,
          includeAlbumArt: includeAlbumArt,
        )
        .map((item) => RadioTrack.fromMap(item));
  }

  /// Stream charts data for a specific country
  Stream<ChartItem> streamCharts({
    String country = 'ZZ', // ZZ = Global, US = United States, etc.
    int limit = 50,
    ThumbnailQuality thumbQuality = ThumbnailQuality.veryHigh,
    AudioQuality audioQuality = AudioQuality.high,
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) {
    return YtFlutterMusicapiPlatform.instance
        .streamCharts(
          country: country,
          limit: limit,
          thumbQuality: thumbQuality.value,
          audioQuality: audioQuality.value,
          includeAudioUrl: includeAudioUrl,
          includeAlbumArt: includeAlbumArt,
        )
        .map((item) => ChartItem.fromMap(item));
  }

  Stream<ArtistAlbum> streamArtistAlbums({
    required String artistName,
    int maxAlbums = 5,
    int maxSongsPerAlbum = 10,
    int maxWorkers = 5,
    ThumbnailQuality thumbQuality = ThumbnailQuality.veryHigh,
    AudioQuality audioQuality = AudioQuality.high,
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) {
    return YtFlutterMusicapiPlatform.instance
        .streamArtistAlbums(
          artistName: artistName,
          maxAlbums: maxAlbums,
          maxSongsPerAlbum: maxSongsPerAlbum,
          maxWorkers: maxWorkers,
          thumbQuality: thumbQuality.value,
          audioQuality: audioQuality.value,
          includeAudioUrl: includeAudioUrl,
          includeAlbumArt: includeAlbumArt,
        )
        .map((item) => ArtistAlbum.fromMap(item));
  }

  /// Stream artist singles/EPs
  Stream<ArtistAlbum> streamArtistSingles({
    required String artistName,
    int maxSingles = 5,
    int maxSongsPerSingle = 10,
    int maxWorkers = 5,
    ThumbnailQuality thumbQuality = ThumbnailQuality.veryHigh,
    AudioQuality audioQuality = AudioQuality.high,
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) {
    return YtFlutterMusicapiPlatform.instance
        .streamArtistSingles(
          artistName: artistName,
          maxSingles: maxSingles,
          maxSongsPerSingle: maxSongsPerSingle,
          maxWorkers: maxWorkers,
          thumbQuality: thumbQuality.value,
          audioQuality: audioQuality.value,
          includeAudioUrl: includeAudioUrl,
          includeAlbumArt: includeAlbumArt,
        )
        .map((item) => ArtistAlbum.fromMap(item));
  }

  /// Fast audio URL fetching - optimized for speed (< 1 second)
  /// Only returns the audio URL, no other metadata
  Future<YTMusicResponse<String>> getAudioUrlFast({
    required String videoId,
  }) async {
    return _executeApiCall<String>(() async {
      try {
        debugPrint('⚡ Fast fetching audio URL for: $videoId');

        final response =
            await YtFlutterMusicapiPlatform.instance.getAudioUrlFast(
          videoId: videoId,
        );

        final responseMap = Map<String, dynamic>.from(response);

        if (responseMap.containsKey('error')) {
          debugPrint('❌ Fast audio fetch failed: ${responseMap['error']}');
          throw PlatformException(
            code: responseMap['errorCode']?.toString() ?? 'AUDIO_URL_ERROR',
            message: responseMap['error']?.toString(),
            details: responseMap,
          );
        }

        final audioUrl = responseMap['audioUrl']?.toString() ?? '';
        debugPrint(
            '✅ Fast audio URL retrieved: ${audioUrl.substring(0, 50)}...');

        return audioUrl;
      } catch (e, stackTrace) {
        debugPrint('Error in getAudioUrlFast: $e\n$stackTrace');
        rethrow;
      }
    });
  }

  /// Fetch multiple audio URLs quickly in parallel
  Future<Map<String, String?>> getAudioUrlsFastBatch({
    required List<String> videoIds,
  }) async {
    debugPrint('⚡ Batch fetching ${videoIds.length} audio URLs');

    final results = <String, String?>{};

    // Process in parallel batches of 5
    const batchSize = 5;
    for (var i = 0; i < videoIds.length; i += batchSize) {
      final batch = videoIds.skip(i).take(batchSize).toList();

      final futures = batch.map((videoId) async {
        try {
          final response = await getAudioUrlFast(videoId: videoId);
          return MapEntry(videoId, response.data);
        } catch (e) {
          debugPrint('Failed to fetch audio for $videoId: $e');
          return MapEntry(videoId, null);
        }
      });

      final batchResults = await Future.wait(futures);
      results.addEntries(batchResults);

      // Small delay between batches to avoid rate limiting
      if (i + batchSize < videoIds.length) {
        await Future.delayed(Duration(milliseconds: 100));
      }
    }

    debugPrint(
        '✅ Batch fetch complete: ${results.values.where((v) => v != null).length}/${videoIds.length} successful');

    return results;
  }

  /// Fetches lyrics for a song from YouTube Music
  ///
  /// [songName] - The name of the song to fetch lyrics for
  /// [artistName] - The name of the artist (helps with more accurate matching)
  ///
  /// Returns a [YTMusicResponse] containing the [Lyrics] if successful
  Future<YTMusicResponse<Lyrics>> fetchLyrics({
    required String songName,
    required String artistName,
  }) async {
    return _executeApiCall<Lyrics>(() async {
      try {
        final response = await YtFlutterMusicapiPlatform.instance.fetchLyrics(
          songName: songName,
          artistName: artistName,
        );

        // Debug: Print raw response structure
        debugPrint('Raw response type: ${response.runtimeType}');
        debugPrint('Raw response: $response');

        // Use recursive casting to handle nested maps properly
        final responseMap = _castToStringDynamicMap(response);

        // Debug: Print casted response structure
        debugPrint('Casted response keys: ${responseMap.keys}');
        debugPrint('Debug info: ${responseMap['debug_info']}');

        // Check for error response first
        if (responseMap.containsKey('error')) {
          throw PlatformException(
            code: responseMap['errorCode']?.toString() ?? 'LYRICS_ERROR',
            message: responseMap['error']?.toString(),
            details: responseMap,
          );
        }

        // Convert the response to our Lyrics model
        final lyricsData = responseMap['data'] ?? responseMap;
        debugPrint('Lyrics data type: ${lyricsData.runtimeType}');
        debugPrint(
            'Lyrics data keys: ${lyricsData is Map ? (lyricsData).keys : 'Not a map'}');

        // Check if lyrics data contains the lyrics list
        if (lyricsData is Map) {
          final lyricsMap = lyricsData;
          final lyricsList = lyricsMap['lyrics'];
          debugPrint('Lyrics list type: ${lyricsList.runtimeType}');
          debugPrint(
              'Lyrics list length: ${lyricsList is List ? lyricsList.length : 'Not a list'}');

          if (lyricsList is List && lyricsList.isNotEmpty) {
            debugPrint('First lyrics item: ${lyricsList.first}');
            debugPrint(
                'First lyrics item type: ${lyricsList.first.runtimeType}');
          }
        }

        final castedLyricsData = _castToStringDynamicMap(lyricsData);
        debugPrint('Final casted lyrics data: $castedLyricsData');

        return Lyrics.fromMap(castedLyricsData);
      } catch (e, stackTrace) {
        debugPrint('Error in fetchLyrics: $e');
        debugPrint('Stack trace: $stackTrace');
        rethrow;
      }
    });
  }

  Future<YTMusicResponse<AudioUrlResult>> getAudioUrlFlexible({
    String? title,
    String? artist,
    String? videoId,
    AudioQuality audioQuality = AudioQuality.high,
  }) async {
    return _executeApiCall<AudioUrlResult>(() async {
      try {
        // Validate input parameters
        if ((videoId?.isEmpty ?? true) &&
            (title?.isEmpty ?? true) &&
            (artist?.isEmpty ?? true)) {
          throw ArgumentError(
              'Either videoId OR (title and/or artist) must be provided');
        }

        final response =
            await YtFlutterMusicapiPlatform.instance.getAudioUrlFlexible(
          title: title,
          artist: artist,
          videoId: videoId,
          audioQuality: audioQuality.value,
        );

        final responseMap = Map<String, dynamic>.from(response);

        // Check for error response
        if (responseMap.containsKey('error')) {
          throw PlatformException(
            code: responseMap['errorCode']?.toString() ?? 'AUDIO_URL_ERROR',
            message: responseMap['error']?.toString(),
            details: responseMap,
          );
        }

        return AudioUrlResult.fromMap(responseMap);
      } catch (e, stackTrace) {
        debugPrint('Error in getAudioUrlFlexible: $e\n$stackTrace');
        rethrow;
      }
    });
  }

  Map<String, dynamic> _castToStringDynamicMap(dynamic value) {
    if (value == null) {
      return <String, dynamic>{};
    }

    if (value is Map<String, dynamic>) {
      // Already the correct type, but recursively cast nested values
      return value.map((key, val) => MapEntry(key, _castDynamicValue(val)));
    }

    if (value is Map) {
      // Convert to Map<String, dynamic> and recursively cast nested values
      return value
          .map((key, val) => MapEntry(key.toString(), _castDynamicValue(val)));
    }

    // If it's not a Map, return empty map (shouldn't happen in normal cases)
    debugPrint('Warning: Expected Map but got ${value.runtimeType}: $value');
    return <String, dynamic>{};
  }

  dynamic _castDynamicValue(dynamic value) {
    if (value == null) {
      return null;
    }

    if (value is List) {
      // Recursively cast list items
      return value.map((item) => _castDynamicValue(item)).toList();
    }

    if (value is Map) {
      // Recursively cast map values
      return value
          .map((key, val) => MapEntry(key.toString(), _castDynamicValue(val)));
    }

    // For primitive types (String, int, double, bool), return as-is
    return value;
  }

  /// Cleans up resources
  Future<YTMusicResponse<void>> dispose() async {
    try {
      final result = await YtFlutterMusicapiPlatform.instance.dispose();
      _isInitialized = false;
      return YTMusicResponse<void>(
        success: result['success'] ?? false,
        message: result['message'],
        error: result['error'],
      );
    } catch (e) {
      return YTMusicResponse<void>(
        success: false,
        error: e.toString(),
      );
    }
  }

  /// Clear search cache
  void clearCache() {
    final count = _searchCache.length;
    _searchCache.clear();
    _cacheTimestamps.clear();
    debugPrint('🗑️ Cleared $count cached search results');
  }

  /// Clear specific cache entry
  void clearCacheForQuery(String query) {
    final keysToRemove =
        _searchCache.keys.where((key) => key.startsWith('$query:')).toList();

    for (final key in keysToRemove) {
      _searchCache.remove(key);
      _cacheTimestamps.remove(key);
    }

    debugPrint('🗑️ Cleared ${keysToRemove.length} cached entries for: $query');
  }

  /// Get cache statistics
  Map<String, dynamic> getCacheStats() {
    return {
      'totalEntries': _searchCache.length,
      'oldestEntry': _cacheTimestamps.values.isEmpty
          ? null
          : _cacheTimestamps.values.reduce((a, b) => a.isBefore(b) ? a : b),
      'newestEntry': _cacheTimestamps.values.isEmpty
          ? null
          : _cacheTimestamps.values.reduce((a, b) => a.isAfter(b) ? a : b),
      'cacheDuration': _cacheDuration.inMinutes,
    };
  }

  Future<ApiResponse<SystemStatus>> checkStatus() async {
    try {
      final result = await _channel.invokeMethod('checkStatus');

      if (result is Map) {
        final responseMap = Map<String, dynamic>.from(result);

        // Log the response for debugging
        print('Status check response: $responseMap');

        // Create SystemStatus from the response
        final systemStatus = SystemStatus.fromMap(responseMap);

        return ApiResponse<SystemStatus>(
          success: systemStatus.success,
          message: systemStatus.message,
          data: systemStatus,
        );
      } else {
        return ApiResponse<SystemStatus>(
          success: false,
          message:
              'Invalid response type: ${result.runtimeType}. Expected Map but got ${result.toString()}',
        );
      }
    } on PlatformException catch (e) {
      return ApiResponse<SystemStatus>(
        success: false,
        message: 'Platform error: ${e.message}',
      );
    } catch (e) {
      return ApiResponse<SystemStatus>(
        success: false,
        message: 'Unexpected error: ${e.toString()}',
      );
    }
  }

  /// Helper method to execute API calls with common error handling
  Future<YTMusicResponse<T>> _executeApiCall<T>(
      Future<T> Function() call) async {
    if (!_isInitialized) {
      return YTMusicResponse<T>(
        success: false,
        error: 'YTMusic API not initialized. Call initialize() first.',
      );
    }

    try {
      final data = await call();
      return YTMusicResponse<T>(
        success: true,
        data: data,
      );
    } catch (e) {
      return YTMusicResponse<T>(
        success: false,
        error: e.toString(),
      );
    }
  }

  bool get isInitialized => _isInitialized;
}

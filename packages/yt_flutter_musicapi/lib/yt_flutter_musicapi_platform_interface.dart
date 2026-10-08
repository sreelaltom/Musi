import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:yt_flutter_musicapi/yt_flutter_musicapi_method_channel.dart';

abstract class YtFlutterMusicapiPlatform extends PlatformInterface {
  YtFlutterMusicapiPlatform() : super(token: _token);

  static final Object _token = Object();
  static YtFlutterMusicapiPlatform _instance = MethodChannelYtFlutterMusicapi();

  static YtFlutterMusicapiPlatform get instance => _instance;

  static set instance(YtFlutterMusicapiPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<Map<String, dynamic>> initialize({
    String? proxy,
    String country = 'IN',
  }) {
    throw UnimplementedError('initialize() has not been implemented.');
  }

  Future<Map<String, dynamic>> searchMusic({
    required String query,
    int limit = 25,
    String thumbQuality = 'VERY_HIGH',
    String audioQuality = 'HIGH',
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) {
    throw UnimplementedError('searchMusic() has not been implemented.');
  }

  Stream<Map<String, dynamic>> streamSearchResults({
    required String query,
    int limit = 50,
    String thumbQuality = 'VERY_HIGH',
    String audioQuality = 'HIGH',
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) {
    throw UnimplementedError('streamSearchResults() has not been implemented.');
  }

  Future<Map<String, dynamic>> getRelatedSongs({
    required String songName,
    required String artistName,
    int limit = 25,
    String thumbQuality = 'VERY_HIGH',
    String audioQuality = 'HIGH',
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) {
    throw UnimplementedError('getRelatedSongs() has not been implemented.');
  }

  /// Get charts data as a batch operation
  Future<Map<String, dynamic>> getCharts({
    required String country,
    required int limit,
    required String thumbQuality,
    required String audioQuality,
    required bool includeAudioUrl,
    required bool includeAlbumArt,
  }) {
    throw UnimplementedError('getCharts() has not been implemented.');
  }

  Stream<Map<String, dynamic>> streamRelatedSongs({
    required String songName,
    required String artistName,
    int limit = 100,
    String thumbQuality = 'VERY_HIGH',
    String audioQuality = 'HIGH',
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) {
    throw UnimplementedError('streamRelatedSongs() has not been implemented.');
  }

  Future<Map<String, dynamic>> getArtistSongs({
    required String artistName,
    int limit = 25,
    String thumbQuality = 'VERY_HIGH',
    String audioQuality = 'HIGH',
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) {
    throw UnimplementedError('getArtistSongs() has not been implemented.');
  }

  Stream<Map<String, dynamic>> streamArtistSongs({
    required String artistName,
    int limit = 80,
    String thumbQuality = 'VERY_HIGH',
    String audioQuality = 'HIGH',
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) {
    throw UnimplementedError('streamArtistSongs() has not been implemented.');
  }

  /// Stream charts data for a specific country
  Stream<Map<String, dynamic>> streamCharts({
    required String country,
    required int limit,
    required String thumbQuality,
    required String audioQuality,
    required bool includeAudioUrl,
    required bool includeAlbumArt,
  }) {
    throw UnimplementedError('streamCharts() has not been implemented.');
  }

  /// Only returns the audio URL using videoId, no other metadata
  ///
  /// Parameters:
  /// - [videoId]: YouTube video ID (required)
  ///
  /// Returns a Map with:
  /// - success: bool - Whether the operation was successful
  /// - audioUrl: String - The direct audio URL (if successful)
  /// - error: String - Error message (if failed)
  /// - videoId: String - The video ID used for the request
  Future<Map<String, dynamic>> getAudioUrlFast({
    required String videoId,
  }) {
    throw UnimplementedError('getAudioUrlFast() has not been implemented.');
  }

  Future<Map<String, dynamic>> fetchLyrics({
    required String songName,
    required String artistName,
  }) {
    throw UnimplementedError('fetchLyrics() has not been implemented.');
  }

  Stream<Map<String, dynamic>> streamRadio({
    required String videoId,
    int limit = 100,
    String thumbQuality = 'VERY_HIGH',
    String audioQuality = 'HIGH',
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) {
    throw UnimplementedError('streamRadio() has not been implemented.');
  }

  Stream<Map<String, dynamic>> streamArtistAlbums({
    required String artistName,
    int maxAlbums = 5,
    int maxSongsPerAlbum = 10,
    int maxWorkers = 5,
    String thumbQuality = 'VERY_HIGH',
    String audioQuality = 'HIGH',
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) {
    throw UnimplementedError('streamArtistAlbums() has not been implemented.');
  }

  Stream<Map<String, dynamic>> streamArtistSingles({
    required String artistName,
    int maxSingles = 5,
    int maxSongsPerSingle = 10,
    int maxWorkers = 5,
    String thumbQuality = 'VERY_HIGH',
    String audioQuality = 'HIGH',
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) {
    throw UnimplementedError('streamArtistSingles() has not been implemented.');
  }

  /// Get audio URL using flexible parameters
  ///
  /// At least one of [title], [artist], or [videoId] must be provided.
  /// If [videoId] is provided, it will be used directly for faster results.
  /// If only [title] and/or [artist] are provided, the method will search
  /// for the song first and then extract the audio URL.
  ///
  /// Parameters:
  /// - [title]: Song title (optional if videoId is provided)
  /// - [artist]: Artist name (optional if videoId is provided)
  /// - [videoId]: YouTube video ID (optional if title/artist provided)
  /// - [audioQuality]: Audio quality level - "LOW", "MED", "HIGH", "VERY_HIGH"
  ///
  /// Returns a Map with:
  /// - success: bool - Whether the operation was successful
  /// - audioUrl: String - The direct audio URL (if successful)
  /// - error: String - Error message (if failed)
  /// - Additional metadata about the request
  Future<Map<String, dynamic>> getAudioUrlFlexible({
    String? title,
    String? artist,
    String? videoId,
    String audioQuality = 'HIGH',
  }) {
    throw UnimplementedError('getAudioUrlFlexible() has not been implemented.');
  }

  Future<Map<String, dynamic>> cancelAllSearches() {
    throw UnimplementedError('cancelAllSearches() has not been implemented.');
  }

  Future<Map<String, dynamic>> dispose() {
    throw UnimplementedError('dispose() has not been implemented.');
  }
}

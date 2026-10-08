// lib/yt_flutter_musicapi_platform_interface.dart

import 'package:flutter/services.dart';
import 'yt_flutter_musicapi_platform_interface.dart';

class MethodChannelYtFlutterMusicapi extends YtFlutterMusicapiPlatform {
  final MethodChannel _methodChannel =
      const MethodChannel('yt_flutter_musicapi');
  final EventChannel _searchEventChannel =
      const EventChannel('yt_flutter_musicapi/searchStream');
  final EventChannel _relatedEventChannel =
      const EventChannel('yt_flutter_musicapi/relatedSongsStream');
  final EventChannel _artistEventChannel =
      const EventChannel('yt_flutter_musicapi/artistSongsStream');
  final EventChannel _radioEventChannel =
      const EventChannel('yt_flutter_musicapi/radioStream');
  final EventChannel _artistAlbumsEventChannel =
      const EventChannel('yt_flutter_musicapi/artistAlbumsStream');
  final EventChannel _artistSinglesEventChannel =
      const EventChannel('yt_flutter_musicapi/artistSinglesStream');
  final EventChannel _chartsStreamChannel =
      EventChannel('yt_flutter_musicapi/chartsStream');
  @override
  Future<Map<String, dynamic>> initialize({
    String? proxy,
    String country = 'US',
  }) async {
    final result = await _methodChannel.invokeMethod('initialize', {
      'proxy': proxy,
      'country': country,
    });
    return Map<String, dynamic>.from(result);
  }

  @override
  Future<Map<String, dynamic>> searchMusic({
    required String query,
    int limit = 10,
    String thumbQuality = 'VERY_HIGH',
    String audioQuality = 'HIGH',
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) async {
    try {
      final result = await _methodChannel.invokeMethod('searchMusic', {
        'query': query,
        'limit': limit,
        'thumbQuality': thumbQuality,
        'audioQuality': audioQuality,
        'includeAudioUrl': includeAudioUrl,
        'includeAlbumArt': includeAlbumArt,
      });
      return Map<String, dynamic>.from(result);
    } on PlatformException catch (e) {
      // Convert platform exceptions to error map
      return {
        'success': false,
        'error': e.message,
        'code': e.code,
      };
    }
  }

  @override
  Future<Map<String, dynamic>> getCharts({
    required String country,
    required int limit,
    required String thumbQuality,
    required String audioQuality,
    required bool includeAudioUrl,
    required bool includeAlbumArt,
  }) async {
    try {
      final result = await _methodChannel
          .invokeMethod<Map<Object?, Object?>>('getCharts', {
        'country': country,
        'limit': limit,
        'thumbQuality': thumbQuality,
        'audioQuality': audioQuality,
        'includeAudioUrl': includeAudioUrl,
        'includeAlbumArt': includeAlbumArt,
      });

      return Map<String, dynamic>.from(result ?? {});
    } on PlatformException catch (e) {
      throw PlatformException(
        code: e.code,
        message: 'Failed to get charts: ${e.message}',
        details: e.details,
      );
    }
  }

  @override
  Stream<Map<String, dynamic>> streamSearchResults({
    required String query,
    int limit = 35,
    String thumbQuality = 'VERY_HIGH',
    String audioQuality = 'HIGH',
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) {
    _methodChannel.invokeMethod('startStreamingSearch', {
      'query': query,
      'limit': limit,
      'thumbQuality': thumbQuality,
      'audioQuality': audioQuality,
      'includeAudioUrl': includeAudioUrl,
      'includeAlbumArt': includeAlbumArt,
    });

    return _searchEventChannel.receiveBroadcastStream({
      'query': query,
      'limit': limit,
      'thumbQuality': thumbQuality,
      'audioQuality': audioQuality,
      'includeAudioUrl': includeAudioUrl,
      'includeAlbumArt': includeAlbumArt,
    }).map((event) => Map<String, dynamic>.from(event));
  }

  @override
  Future<Map<String, dynamic>> getRelatedSongs({
    required String songName,
    required String artistName,
    int limit = 10,
    String thumbQuality = 'VERY_HIGH',
    String audioQuality = 'HIGH',
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) async {
    final result = await _methodChannel.invokeMethod('getRelatedSongs', {
      'songName': songName,
      'artistName': artistName,
      'limit': limit,
      'thumbQuality': thumbQuality,
      'audioQuality': audioQuality,
      'includeAudioUrl': includeAudioUrl,
      'includeAlbumArt': includeAlbumArt,
    });
    return Map<String, dynamic>.from(result);
  }

  @override
  Stream<Map<String, dynamic>> streamRelatedSongs({
    required String songName,
    required String artistName,
    int limit = 65,
    String thumbQuality = 'VERY_HIGH',
    String audioQuality = 'HIGH',
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) {
    _methodChannel.invokeMethod('startStreamingRelated', {
      'songName': songName,
      'artistName': artistName,
      'limit': limit,
      'thumbQuality': thumbQuality,
      'audioQuality': audioQuality,
      'includeAudioUrl': includeAudioUrl,
      'includeAlbumArt': includeAlbumArt,
    });

    return _relatedEventChannel.receiveBroadcastStream({
      'songName': songName,
      'artistName': artistName,
      'limit': limit,
      'thumbQuality': thumbQuality,
      'audioQuality': audioQuality,
      'includeAudioUrl': includeAudioUrl,
      'includeAlbumArt': includeAlbumArt,
    }).map((event) => Map<String, dynamic>.from(event));
  }

  @override
  Future<Map<String, dynamic>> getArtistSongs({
    required String artistName,
    int limit = 10,
    String thumbQuality = 'VERY_HIGH',
    String audioQuality = 'HIGH',
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) async {
    final result = await _methodChannel.invokeMethod('getArtistSongs', {
      'artistName': artistName,
      'limit': limit,
      'thumbQuality': thumbQuality,
      'audioQuality': audioQuality,
      'includeAudioUrl': includeAudioUrl,
      'includeAlbumArt': includeAlbumArt,
    });
    return Map<String, dynamic>.from(result);
  }

  @override
  Stream<Map<String, dynamic>> streamArtistSongs({
    required String artistName,
    int limit = 45,
    String thumbQuality = 'VERY_HIGH',
    String audioQuality = 'HIGH',
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) {
    _methodChannel.invokeMethod('startStreamingArtist', {
      'artistName': artistName,
      'limit': limit,
      'thumbQuality': thumbQuality,
      'audioQuality': audioQuality,
      'includeAudioUrl': includeAudioUrl,
      'includeAlbumArt': includeAlbumArt,
    });

    return _artistEventChannel.receiveBroadcastStream({
      'artistName': artistName,
      'limit': limit,
      'thumbQuality': thumbQuality,
      'audioQuality': audioQuality,
      'includeAudioUrl': includeAudioUrl,
      'includeAlbumArt': includeAlbumArt,
    }).map((event) => Map<String, dynamic>.from(event));
  }

  @override
  Stream<Map<String, dynamic>> streamCharts({
    required String country,
    required int limit,
    required String thumbQuality,
    required String audioQuality,
    required bool includeAudioUrl,
    required bool includeAlbumArt,
  }) {
    // First, trigger the streaming
    _methodChannel.invokeMethod('startStreamingCharts', {
      'country': country,
      'limit': limit,
      'thumbQuality': thumbQuality,
      'audioQuality': audioQuality,
      'includeAudioUrl': includeAudioUrl,
      'includeAlbumArt': includeAlbumArt,
    });

    // Return the event stream
    return _chartsStreamChannel.receiveBroadcastStream({
      'country': country,
      'limit': limit,
      'thumbQuality': thumbQuality,
      'audioQuality': audioQuality,
      'includeAudioUrl': includeAudioUrl,
      'includeAlbumArt': includeAlbumArt,
    }).cast<Map<String, dynamic>>();
  }

  @override
  Stream<Map<String, dynamic>> streamRadio({
    required String videoId,
    int limit = 50,
    String thumbQuality = 'VERY_HIGH',
    String audioQuality = 'HIGH',
    bool includeAudioUrl = true,
    bool includeAlbumArt = true,
  }) {
    _methodChannel.invokeMethod('startStreamingRadio', {
      'videoId': videoId,
      'limit': limit,
      'thumbQuality': thumbQuality,
      'audioQuality': audioQuality,
      'includeAudioUrl': includeAudioUrl,
      'includeAlbumArt': includeAlbumArt,
    });

    return _radioEventChannel.receiveBroadcastStream({
      'videoId': videoId,
      'limit': limit,
      'thumbQuality': thumbQuality,
      'audioQuality': audioQuality,
      'includeAudioUrl': includeAudioUrl,
      'includeAlbumArt': includeAlbumArt,
    }).map((event) => Map<String, dynamic>.from(event));
  }

  @override
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
    // Start the streaming process
    _methodChannel.invokeMethod('startStreamingArtistAlbums', {
      'artistName': artistName,
      'maxAlbums': maxAlbums,
      'maxSongsPerAlbum': maxSongsPerAlbum,
      'maxWorkers': maxWorkers,
      'thumbQuality': thumbQuality,
      'audioQuality': audioQuality,
      'includeAudioUrl': includeAudioUrl,
      'includeAlbumArt': includeAlbumArt,
    });

    return _artistAlbumsEventChannel.receiveBroadcastStream({
      'artistName': artistName,
      'maxAlbums': maxAlbums,
      'maxSongsPerAlbum': maxSongsPerAlbum,
      'maxWorkers': maxWorkers,
      'thumbQuality': thumbQuality,
      'audioQuality': audioQuality,
      'includeAudioUrl': includeAudioUrl,
      'includeAlbumArt': includeAlbumArt,
    }).map((event) => Map<String, dynamic>.from(event));
  }

  @override
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
    // Start the streaming process
    _methodChannel.invokeMethod('startStreamingArtistSingles', {
      'artistName': artistName,
      'maxSingles': maxSingles,
      'maxSongsPerSingle': maxSongsPerSingle,
      'maxWorkers': maxWorkers,
      'thumbQuality': thumbQuality,
      'audioQuality': audioQuality,
      'includeAudioUrl': includeAudioUrl,
      'includeAlbumArt': includeAlbumArt,
    });

    return _artistSinglesEventChannel.receiveBroadcastStream({
      'artistName': artistName,
      'maxSingles': maxSingles,
      'maxSongsPerSingle': maxSongsPerSingle,
      'maxWorkers': maxWorkers,
      'thumbQuality': thumbQuality,
      'audioQuality': audioQuality,
      'includeAudioUrl': includeAudioUrl,
      'includeAlbumArt': includeAlbumArt,
    }).map((event) => Map<String, dynamic>.from(event));
  }

  // @override
  // Stream<Map<String, dynamic>> streamBatchSongs({
  //   required List<Map<String, dynamic>> songs,
  //   int batchSize = 30,
  //   required String thumbQuality,
  //   required String audioQuality,
  // }) {
  //   _methodChannel.invokeMethod('startStreamingBatch', {
  //     'songs': songs,
  //     'batchSize': batchSize,
  //     'thumbQuality': thumbQuality,
  //     'audioQuality': audioQuality,
  //   });

  //   return _batchEventChannel.receiveBroadcastStream({
  //     'songs': songs,
  //     'batchSize': batchSize,
  //     'thumbQuality': thumbQuality,
  //     'audioQuality': audioQuality,
  //   }).map((event) => Map<String, dynamic>.from(event));
  // }

  @override
  Future<Map<String, dynamic>> getAudioUrlFlexible({
    String? title,
    String? artist,
    String? videoId,
    String audioQuality = 'HIGH',
  }) async {
    final result = await _methodChannel.invokeMethod('getAudioUrlFlexible', {
      'title': title,
      'artist': artist,
      'videoId': videoId,
      'audioQuality': audioQuality,
    });
    return Map<String, dynamic>.from(result);
  }

  @override
  Future<Map<String, dynamic>> getAudioUrlFast({
    required String videoId,
  }) async {
    final result = await _methodChannel.invokeMethod<Map<Object?, Object?>>(
      'getAudioUrlFast',
      {'videoId': videoId},
    );
    return Map<String, dynamic>.from(result ?? {});
  }

  @override
  Future<Map<String, dynamic>> fetchLyrics({
    required String songName,
    required String artistName,
  }) async {
    final result = await _methodChannel.invokeMethod('fetchLyrics', {
      'songName': songName,
      'artistName': artistName,
    });
    return Map<String, dynamic>.from(result);
  }

  @override
  Future<Map<String, dynamic>> cancelAllSearches() async {
    final result = await _methodChannel.invokeMethod('cancelAllSearches');
    return Map<String, dynamic>.from(result);
  }

  @override
  Future<Map<String, dynamic>> dispose() async {
    final result = await _methodChannel.invokeMethod('dispose');
    return Map<String, dynamic>.from(result);
  }
}

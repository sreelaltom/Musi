import 'package:dio/dio.dart';

import '../models/song.dart';
import 'music_service.dart';
import 'mock_music_service.dart';

/// RealMusicService using the open Jamendo API for Creative Commons music.
/// Jamendo provides legally permitted, royalty-free audio streams and downloads.
/// It strictly excludes copyrighted commercial scraping or unauthorized DRM extraction.
class JamendoMusicService implements MusicService {
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
    ),
  );

  // Jamendo public educational/demo client ID for CC tracks
  static const String _clientId = 'c0cf8e8e';
  static const String _baseUrl = 'https://api.jamendo.com/v3.0';

  final MockMusicService _fallbackService = MockMusicService();

  @override
  Future<List<Song>> search(String query) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) {
      return getFeaturedSongs();
    }

    try {
      final response = await _dio.get(
        '$_baseUrl/tracks/',
        queryParameters: {
          'client_id': _clientId,
          'format': 'json',
          'limit': 25,
          'namesearch': cleanQuery,
          'include': 'musicinfo',
          'audioformat': 'mp32', // High quality 128-192kbps MP3
        },
      );

      if (response.statusCode == 200 && response.data != null) {
        final results = response.data['results'] as List<dynamic>?;
        if (results != null && results.isNotEmpty) {
          return results.map((track) => _mapJamendoTrackToSong(track)).toList();
        }
      }

      // If no results on Jamendo, search fallback catalog
      return await _fallbackService.search(query);
    } catch (_) {
      // Network or API failure -> seamlessly fall back without crashing
      return await _fallbackService.search(query);
    }
  }

  @override
  Future<Song?> getSongDetails(String id) async {
    if (id.startsWith('mock-')) {
      return await _fallbackService.getSongDetails(id);
    }

    try {
      final response = await _dio.get(
        '$_baseUrl/tracks/',
        queryParameters: {'client_id': _clientId, 'format': 'json', 'id': id},
      );

      if (response.statusCode == 200 && response.data != null) {
        final results = response.data['results'] as List<dynamic>?;
        if (results != null && results.isNotEmpty) {
          return _mapJamendoTrackToSong(results.first);
        }
      }
    } catch (_) {}

    return await _fallbackService.getSongDetails(id);
  }

  @override
  Future<List<Song>> getFeaturedSongs() async {
    try {
      final response = await _dio.get(
        '$_baseUrl/tracks/',
        queryParameters: {
          'client_id': _clientId,
          'format': 'json',
          'limit': 15,
          'order': 'popularity_total',
          'audioformat': 'mp32',
        },
      );

      if (response.statusCode == 200 && response.data != null) {
        final results = response.data['results'] as List<dynamic>?;
        if (results != null && results.isNotEmpty) {
          return results.map((track) => _mapJamendoTrackToSong(track)).toList();
        }
      }
    } catch (_) {}

    return await _fallbackService.getFeaturedSongs();
  }

  @override
  Future<List<Song>> getTrendingSongs() async {
    try {
      final response = await _dio.get(
        '$_baseUrl/tracks/',
        queryParameters: {
          'client_id': _clientId,
          'format': 'json',
          'limit': 15,
          'order': 'popularity_month',
          'audioformat': 'mp32',
        },
      );

      if (response.statusCode == 200 && response.data != null) {
        final results = response.data['results'] as List<dynamic>?;
        if (results != null && results.isNotEmpty) {
          return results.map((track) => _mapJamendoTrackToSong(track)).toList();
        }
      }
    } catch (_) {}

    return await _fallbackService.getTrendingSongs();
  }

  Song _mapJamendoTrackToSong(Map<String, dynamic> track) {
    return Song(
      id:
          track['id']?.toString() ??
          'jamendo_${DateTime.now().millisecondsSinceEpoch}',
      title: track['name']?.toString() ?? 'Untitled Song',
      artist: track['artist_name']?.toString() ?? 'Unknown Artist',
      album: track['album_name']?.toString(),
      artworkUrl:
          track['image']?.toString() ?? track['album_image']?.toString(),
      streamUrl: track['audio']?.toString() ?? '',
      sourceUrl: track['shareurl']?.toString() ?? 'https://www.jamendo.com',
      duration: (track['duration'] as num?)?.toInt() ?? 0,
      isLiked: false,
      isDownloaded: false,
    );
  }
}

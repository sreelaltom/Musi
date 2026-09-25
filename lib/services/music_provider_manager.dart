import 'dart:async';

import 'package:flutter/foundation.dart';

import '../database/provider_dao.dart';
import '../database/settings_dao.dart';
import '../models/music_provider.dart';
import '../models/search_result.dart'
    show SearchResult, SongSearchResult, YouTubeSearchResult;
import '../models/song.dart';
import '../models/youtube_music_result.dart';
import 'jamendo_music_service.dart';
import 'mock_music_service.dart';
import 'music_service.dart';
import 'youtube_audio_service.dart' show YouTubeAudioService;
import 'youtube_music_api_service.dart'
    show CancelableToken, YouTubeMusicApiService;

class MusicProviderManager extends ChangeNotifier {
  static const Duration _providerTimeout = Duration(seconds: 2);
  static final MusicProviderManager _instance =
      MusicProviderManager._internal();

  factory MusicProviderManager() => _instance;

  MusicProviderManager._internal() {
    _registerDefaultProviders();
    _initYouTube();
  }

  final Map<String, MusicService> _providers = {};
  final Map<String, MusicProvider> _providerInfo = {};
  final SettingsDao _settingsDao = SettingsDao();
  final ProviderDao _providerDao = ProviderDao();
  late final YouTubeMusicApiService _youtubeService;
  bool _youtubeEnabled = true;
  bool _isInitialized = false;
  Future<void>? _initialization;

  final JamendoMusicService _jamendoService = JamendoMusicService();
  final MockMusicService _mockService = MockMusicService();

  void _registerDefaultProviders() {
    _providers['jamendo'] = _jamendoService;
    _providerInfo['jamendo'] = const MusicProvider(
      id: 'jamendo',
      name: 'Jamendo',
      description: 'Creative Commons licensed music from independent artists',
      attributionUrl: 'https://www.jamendo.com',
      canStream: true,
      canDownload: true,
      enabled: true,
    );

    _providers['mock'] = _mockService;
    _providerInfo['mock'] = const MusicProvider(
      id: 'mock',
      name: 'Open Licensed Sources',
      description: 'Built-in public domain and Creative Commons test catalog',
      attributionUrl: null,
      canStream: true,
      canDownload: true,
      enabled: true,
    );

    _providerInfo['youtube'] = const MusicProvider(
      id: 'youtube',
      name: 'YouTube',
      description: 'Official YouTube music discovery and visible playback',
      attributionUrl: 'https://www.youtube.com',
      canStream: false,
      canDownload: false,
      enabled: true,
    );
  }

  void _initYouTube() {
    _youtubeService = YouTubeMusicApiService();
    _youtubeService.initialize();
  }

  Map<String, MusicProvider> get providers => Map.unmodifiable(_providerInfo);
  bool get isYouTubeConfigured => true;
  String? get youtubeLastError => null;

  Future<void> initialize() {
    if (_isInitialized) return Future.value();
    _initialization ??= _initialize();
    return _initialization!;
  }

  Future<void> _initialize() async {
    try {
      await _providerDao.seedDefaultProviders();
      final persistedProviders = await _providerDao.getAllProviders();
      final persistedById = {
        for (final provider in persistedProviders) provider.id: provider,
      };

      for (final entry in _providerInfo.entries) {
        final persisted = persistedById[entry.key];
        if (persisted != null) {
          _providerInfo[entry.key] = entry.value.copyWith(
            name: persisted.name,
            description: persisted.description,
            attributionUrl: persisted.attributionUrl,
            canStream: persisted.canStream,
            canDownload: persisted.canDownload,
          );
        }
      }

      final jamendoEnabled = await _settingsDao.isProviderEnabled('jamendo');
      final openLicensedEnabled = await _settingsDao.isProviderEnabled('mock');
      final youtubeEnabled = await _settingsDao.getYouTubeEnabled();
      _setProviderEnabledInMemory('jamendo', jamendoEnabled);
      _setProviderEnabledInMemory('mock', openLicensedEnabled);
      _setProviderEnabledInMemory('youtube', youtubeEnabled);
      _youtubeEnabled = youtubeEnabled;
    } catch (_) {
      debugPrint('Provider settings could not be loaded; defaults were used.');
    } finally {
      _isInitialized = true;
      notifyListeners();
    }
  }

  bool isProviderEnabled(String providerId) {
    return _providerInfo[providerId]?.enabled ?? false;
  }

  bool get isYouTubeEnabled => _youtubeEnabled;

  Future<void> setProviderEnabled(String providerId, bool enabled) async {
    if (providerId == 'youtube') {
      await setYouTubeEnabled(enabled);
      return;
    }
    if (!_providerInfo.containsKey(providerId)) return;

    await initialize();
    _setProviderEnabledInMemory(providerId, enabled);
    notifyListeners();
    try {
      await Future.wait([
        _settingsDao.setProviderEnabled(providerId, enabled),
        _providerDao.setProviderEnabled(providerId, enabled),
      ]);
    } catch (_) {
      debugPrint('Provider settings could not be persisted.');
    }
  }

  Future<void> setYouTubeEnabled(bool enabled) async {
    await initialize();
    _youtubeEnabled = enabled;
    _setProviderEnabledInMemory('youtube', enabled);
    notifyListeners();
    try {
      await Future.wait([
        _settingsDao.setYouTubeEnabled(enabled),
        _providerDao.setProviderEnabled('youtube', enabled),
      ]);
    } catch (_) {
      debugPrint('YouTube provider settings could not be persisted.');
    }
  }

  void _setProviderEnabledInMemory(String providerId, bool enabled) {
    final current = _providerInfo[providerId];
    if (current == null) return;
    _providerInfo[providerId] = current.copyWith(enabled: enabled);
  }

  Future<List<SearchResult>> searchAll(
    String query, {
    CancelableToken? cancelable,
  }) async {
    await initialize();
    debugPrint(
      'MusicProviderManager: searchAll query="$query", isYouTubeEnabled=$isYouTubeEnabled, isYouTubeConfigured=$isYouTubeConfigured',
    );
    if (query.trim().isEmpty) {
      return getFeaturedAll(cancelable: cancelable);
    }

    final futures = <Future<List<SearchResult>>>[];
    for (final entry in _providers.entries) {
      final providerId = entry.key;
      if (!isProviderEnabled(providerId)) continue;
      futures.add(_safeSearchAudio(entry.value, query, providerId));
    }
    if (isYouTubeEnabled) {
      debugPrint('MusicProviderManager: Adding YouTube search to futures');
      futures.add(_safeSearchYouTube(query, cancelable: cancelable));
    } else {
      debugPrint('MusicProviderManager: YouTube disabled - not searching');
    }

    final results = await Future.wait(futures);
    return _deduplicateResults(results.expand((items) => items).toList());
  }

  Future<List<Song>> search(String query) async {
    final results = await searchAll(query);
    return results
        .whereType<SongSearchResult>()
        .map((result) => result.song)
        .toList();
  }

  Future<List<Song>> _withProviderTimeout<T extends List<Song>>(
    Future<T> future,
  ) async {
    try {
      return await future.timeout(_providerTimeout);
    } catch (_) {
      return const [];
    }
  }

  Future<List<SearchResult>> _safeSearchAudio(
    MusicService provider,
    String query,
    String providerId,
  ) async {
    try {
      final songs = await _withProviderTimeout(provider.search(query));
      final providerName = _providerInfo[providerId]?.name ?? providerId;
      return songs
          .map(
            (song) => SongSearchResult(
              _tagSongWithProvider(song, providerId, providerName),
            ),
          )
          .toList();
    } catch (error) {
      debugPrint('Provider search failed: $error');
      return const [];
    }
  }

   Future<List<SearchResult>> _safeSearchYouTube(
    String query, {
    CancelableToken? cancelable,
  }) async {
    debugPrint(
      'MusicProviderManager: _safeSearchYouTube called for query="$query"',
    );
    try {
      final videos = await _youtubeService.searchTracks(
        query,
        limit: 25,
        cancelable: cancelable,
      );
      debugPrint(
        'MusicProviderManager: YouTube search returned ${videos.length} videos for "$query"',
      );
      // Pre-filter to ensure only playable results reach the page
      final youtubeAudioService = YouTubeAudioService();
      final playableVideos = await youtubeAudioService.filterPlayable(videos);
      debugPrint(
        'MusicProviderManager: ${playableVideos.length}/${videos.length} YouTube '
        'results are playable for "$query"',
      );
      return playableVideos.map(YouTubeSearchResult.new).toList();
    } catch (error) {
      debugPrint('YouTube search failed for "$query": $error');
      return const [];
    }
  }

  Song _tagSongWithProvider(Song song, String providerId, String providerName) {
    final providerInfo = _providerInfo[providerId];
    final canStream = providerInfo?.canStream ?? false;
    final canDownload = providerInfo?.canDownload ?? false;
    return song.copyWith(
      providerId: providerId,
      providerName: providerName,
      canStream: canStream && song.streamUrl.isNotEmpty,
      canDownload: canDownload && song.streamUrl.isNotEmpty,
    );
  }

  List<SearchResult> _deduplicateResults(List<SearchResult> results) {
    final seenSongKeys = <String>{};
    final seenVideoIds = <String>{};
    final deduplicated = <SearchResult>[];
    for (final result in results) {
      if (result is SongSearchResult) {
        final song = result.song;
        final key = _normalizeKey(song.title, song.artist, song.album);
        if (seenSongKeys.add(key)) deduplicated.add(result);
      } else if (result is YouTubeSearchResult) {
        if (seenVideoIds.add(result.video.videoId)) deduplicated.add(result);
      }
    }
    return deduplicated;
  }

  String _normalizeKey(String title, String artist, String? album) {
    final normalizedTitle = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .trim();
    final normalizedArtist = artist
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .trim();
    final normalizedAlbum = (album ?? '')
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .trim();
    return '$normalizedTitle|$normalizedArtist|$normalizedAlbum';
  }

  Future<List<Song>> getFeaturedSongs() async {
    await initialize();
    final futures = <Future<List<Song>>>[];
    for (final entry in _providers.entries) {
      if (!isProviderEnabled(entry.key)) continue;
      futures.add(_safeFeaturedSongs(entry.value, entry.key));
    }
    final results = await Future.wait(futures);
    final allSongs = <Song>[];
    for (final songs in results) {
      allSongs.addAll(songs);
    }
    return _deduplicateSongs(allSongs);
  }

  Future<List<SearchResult>> getFeaturedAll({
    CancelableToken? cancelable,
  }) async {
    await initialize();
    final futures = <Future<List<SearchResult>>>[];
    for (final entry in _providers.entries) {
      if (!isProviderEnabled(entry.key)) continue;
      futures.add(_safeFeaturedAudio(entry.value, entry.key));
    }
    if (isYouTubeEnabled) {
      futures.add(_safeFeaturedYouTube(cancelable: cancelable));
    }
    final results = await Future.wait(futures);
    return _deduplicateResults(results.expand((items) => items).toList());
  }

  Future<List<Song>> _safeFeaturedSongs(
    MusicService provider,
    String providerId,
  ) async {
    try {
      final songs = await _withProviderTimeout(provider.getFeaturedSongs());
      final providerName = _providerInfo[providerId]?.name ?? providerId;
      return songs
          .map((song) => _tagSongWithProvider(song, providerId, providerName))
          .toList();
    } catch (error) {
      debugPrint('Provider featured search failed: $error');
      return const [];
    }
  }

  Future<List<SearchResult>> _safeFeaturedAudio(
    MusicService provider,
    String providerId,
  ) async {
    try {
      final songs = await _withProviderTimeout(provider.getFeaturedSongs());
      final providerName = _providerInfo[providerId]?.name ?? providerId;
      return songs
          .map(
            (song) => SongSearchResult(
              _tagSongWithProvider(song, providerId, providerName),
            ),
          )
          .toList();
    } catch (error) {
      debugPrint('Provider featured search failed: $error');
      return const [];
    }
  }

   Future<List<SearchResult>> _safeFeaturedYouTube({
    CancelableToken? cancelable,
  }) async {
    try {
      final videos = await _youtubeService.searchTracks(
        'music',
        limit: 25,
      );
      // Pre-filter to ensure only playable results reach the page
      final playableVideos =
          await YouTubeAudioService().filterPlayable(videos);
      debugPrint(
        'MusicProviderManager: ${playableVideos.length}/${videos.length} '
        'featured YouTube results are playable',
      );
      return playableVideos.map(YouTubeSearchResult.new).toList();
    } catch (error) {
      debugPrint('YouTube featured search failed: $error');
      return const [];
    }
  }

  Future<List<Song>> getTrendingSongs() async {
    await initialize();
    final futures = <Future<List<Song>>>[];
    for (final entry in _providers.entries) {
      if (!isProviderEnabled(entry.key)) continue;
      futures.add(_safeTrending(entry.value, entry.key));
    }
    final results = await Future.wait(futures);
    final allSongs = <Song>[];
    for (final songs in results) {
      allSongs.addAll(songs);
    }
    return _deduplicateSongs(allSongs);
  }

  Future<List<Song>> _safeTrending(
    MusicService provider,
    String providerId,
  ) async {
    try {
      final songs = await _withProviderTimeout(provider.getTrendingSongs());
      final providerName = _providerInfo[providerId]?.name ?? providerId;
      return songs
          .map((song) => _tagSongWithProvider(song, providerId, providerName))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  List<Song> _deduplicateSongs(List<Song> songs) {
    final seen = <String, Song>{};
    for (final song in songs) {
      final key = _normalizeKey(song.title, song.artist, song.album);
      seen.putIfAbsent(key, () => song);
    }
    return seen.values.toList();
  }

  Future<Song?> getSongDetails(String id, String? providerId) async {
    await initialize();
    final targetProviderId = providerId ?? _findProviderForSongId(id);
    if (targetProviderId == null || !_providers.containsKey(targetProviderId)) {
      return null;
    }
    try {
      final song = await _providers[targetProviderId]!.getSongDetails(id);
      if (song == null) return null;
      final providerName =
          _providerInfo[targetProviderId]?.name ?? targetProviderId;
      return _tagSongWithProvider(song, targetProviderId, providerName);
    } catch (_) {
      return null;
    }
  }

  Future<YouTubeMusicResult?> getYouTubeVideoDetails(String videoId) async {
    await initialize();
    if (!isYouTubeEnabled) return null;
    return _youtubeService.getVideoDetails(videoId);
  }

  String? _findProviderForSongId(String id) {
    if (id.startsWith('mock-')) return 'mock';
    if (id.startsWith('jamendo_')) return 'jamendo';
    if (RegExp(r'^\d+$').hasMatch(id)) return 'jamendo';
    return null;
  }

  SourcePlayability validatePlayability(Song song) {
    if (!song.canStream) {
      return SourcePlayability.notPlayableUnknownLicense;
    }
    if (song.streamUrl.isEmpty) {
      return SourcePlayability.notPlayableNoStreamUrl;
    }
    final providerId = song.providerId;
    if (providerId != null && !isProviderEnabled(providerId)) {
      return SourcePlayability.notPlayableProviderDisabled;
    }
    return SourcePlayability.playable;
  }

  bool canDownload(Song song) {
    final providerId = song.providerId ?? '';
    return song.canDownload &&
        song.streamUrl.isNotEmpty &&
        isProviderEnabled(providerId);
  }
}

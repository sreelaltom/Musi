import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../database/settings_dao.dart';
import '../database/music_cache_dao.dart';
import '../database/search_history_dao.dart';
import '../models/music_cache_entry.dart';
import '../models/music_provider.dart' show SourcePlayability;
import '../models/search_result.dart'
    show SearchResult, SongSearchResult, YouTubeSearchResult;
import '../models/song.dart';
import '../models/youtube_music_result.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../services/music_provider_manager.dart' show MusicProviderManager;
import '../services/youtube_music_api_service.dart' show CancelableToken;
import '../theme/app_theme.dart';
import '../widgets/search_bar_widget.dart';
import '../widgets/song_tile.dart';
import '../widgets/youtube_result_tile.dart';
import 'playlist_picker_sheet.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  final MusicProviderManager _providerManager = MusicProviderManager();
  final SettingsDao _settingsDao = SettingsDao();
  final MusicCacheDao _cacheDao = MusicCacheDao();
  final SearchHistoryDao _historyDao = SearchHistoryDao();

  Timer? _debounce;
  CancelableToken? _cancelToken;
  int _requestVersion = 0;
  bool _isApplyingPreset = false;

  List<Song> _playableResults = [];
  List<Song> _nonPlayableResults = [];
  List<YouTubeMusicResult> _youtubeResults = [];
  bool _isLoading = false;
  bool _isOffline = false;
  bool _showingCachedResults = false;
  String? _loadingVideoId;

  final List<String> _genreTags = const [
    'Pop',
    'Rock',
    'Hip-Hop',
    'Electronic',
    'Jazz',
    'Classical',
    'Ambient',
  ];

  @override
  void initState() {
    super.initState();
    _loadInitialResults();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _cancelToken?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialResults() async {
    final version = ++_requestVersion;
    _cancelToken?.cancel();
    _cancelToken = CancelableToken();
    setState(() {
      _isLoading = true;
    });

    try {
      _isOffline = await _settingsDao.getOfflineMode();
      final results = _isOffline
          ? _searchDownloadedSongs('')
          : await _providerManager.searchAll(
              _searchController.text,
              cancelable: _cancelToken,
            );
      if (version == _requestVersion && mounted) {
        _applyResults(results);
        setState(() => _isLoading = false);
      }
    } catch (error) {
      if (version == _requestVersion && mounted) {
        setState(() {
          _playableResults = [];
          _nonPlayableResults = [];
          _youtubeResults = [];
          _isLoading = false;
        });
        debugPrint('Initial search failed: $error');
      }
    }
  }

  void _onSearchChanged(String query) {
    if (_isApplyingPreset) return;
    _requestVersion++;
    _cancelToken?.cancel();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _performSearch(query);
    });
  }

  void _onSearchSubmitted(String query) {
    _debounce?.cancel();
    _performSearch(query);
  }

  void _onClearSearch() {
    _debounce?.cancel();
    _isApplyingPreset = true;
    _searchController.clear();
    _isApplyingPreset = false;
    _performSearch('');
  }

  Future<void> _performSearch(String query) async {
    final version = ++_requestVersion;
    _cancelToken?.cancel();
    _cancelToken = CancelableToken();
    final cleanQuery = query.trim();
    debugPrint(
      'SearchScreen: _performSearch called query="$cleanQuery", version=$version',
    );
    if (mounted) {
      setState(() {
        _isLoading = true;
        _showingCachedResults = false;
        _playableResults = [];
        _nonPlayableResults = [];
        _youtubeResults = [];
      });
    }

    // Save to search history if not empty
    if (cleanQuery.isNotEmpty) {
      await _historyDao.saveSearchQuery(cleanQuery);
    }

    // 1. Check cache first for fast results
    if (cleanQuery.isNotEmpty && !_isOffline) {
      final cachedEntries = await _cacheDao.searchCache(cleanQuery);
      debugPrint(
        'SearchScreen: Cache search for "$cleanQuery" returned ${cachedEntries.length} entries',
      );
      if (cachedEntries.isNotEmpty && mounted) {
        _applyCachedResults(cachedEntries);
        _showingCachedResults = true;
      }
    }

    try {
      _isOffline = await _settingsDao.getOfflineMode();
      debugPrint(
        'SearchScreen: Starting provider search for "$cleanQuery" (offline=$_isOffline)',
      );
      final results = _isOffline
          ? _searchDownloadedSongs(cleanQuery)
          : await _providerManager.searchAll(
              cleanQuery,
              cancelable: _cancelToken,
            );
      debugPrint(
        'SearchScreen: Provider search returned ${results.length} total results for "$cleanQuery"',
      );
      if (version != _requestVersion || !mounted) return;

      // 2. Merge fresh results with cached results
      await _mergeAndApplyResults(results, cleanQuery);
      setState(() => _isLoading = false);
    } catch (error) {
      debugPrint('SearchScreen: Search failed for "$cleanQuery": $error');
      if (mounted && version == _requestVersion) {
        setState(() {
          _playableResults = [];
          _nonPlayableResults = [];
          _youtubeResults = [];
          _isLoading = false;
        });
      }
    }
  }

  void _applyCachedResults(List<MusicCacheEntry> cachedEntries) {
    final playable = <Song>{};
    final nonPlayable = <Song>{};
    final youtube = <YouTubeMusicResult>{};

    for (final entry in cachedEntries) {
      if (entry.isAuthorized) {
        final song = Song(
          id: entry.sourceId,
          title: entry.title,
          artist: entry.artist ?? '',
          album: entry.album,
          artworkUrl: entry.thumbnailUrl,
          streamUrl: entry.sourceUrl ?? '',
          duration: entry.duration,
          providerId: entry.provider,
          providerName: entry.provider,
        );
        // Check if playable
        final playability = _providerManager.validatePlayability(song);
        if (playability == SourcePlayability.playable) {
          playable.add(song);
        } else {
          nonPlayable.add(song);
        }
      } else if (entry.isYouTube) {
        final video = YouTubeMusicResult(
          videoId: entry.youtubeVideoId ?? entry.sourceId,
          title: entry.title,
          channelTitle: entry.artist ?? '',
          thumbnailUrl: entry.thumbnailUrl ?? '',
          youtubeUrl:
              entry.sourceUrl ??
              'https://www.youtube.com/watch?v=${entry.youtubeVideoId ?? entry.sourceId}',
        );
        youtube.add(video);
      }
    }

    setState(() {
      _playableResults = playable.toList();
      _nonPlayableResults = nonPlayable.toList();
      _youtubeResults = youtube.toList();
    });
  }

  Future<void> _mergeAndApplyResults(
    List<SearchResult> freshResults,
    String query,
  ) async {
    // Build maps of existing results to avoid duplicates
    final existingSongKeys = <String>{};
    final existingVideoIds = <String>{};

    for (final song in _playableResults) {
      existingSongKeys.add(_normalizeKey(song.title, song.artist, song.album));
    }
    for (final song in _nonPlayableResults) {
      existingSongKeys.add(_normalizeKey(song.title, song.artist, song.album));
    }
    for (final video in _youtubeResults) {
      existingVideoIds.add(video.videoId);
    }

    // Add fresh results that aren't duplicates
    final newPlayable = <Song>[];
    final newNonPlayable = <Song>[];
    final newYouTube = <YouTubeMusicResult>[];

    for (final result in freshResults) {
      if (result is SongSearchResult) {
        final song = result.song;
        final key = _normalizeKey(song.title, song.artist, song.album);
        if (existingSongKeys.add(key)) {
          final playability = _providerManager.validatePlayability(song);
          if (playability == SourcePlayability.playable) {
            newPlayable.add(song);
          } else {
            newNonPlayable.add(song);
          }
        }
      } else if (result is YouTubeSearchResult) {
        if (existingVideoIds.add(result.video.videoId)) {
          newYouTube.add(result.video);
        }
      }
    }

    // Cache new results
    final cacheEntries = <MusicCacheEntry>[];
    for (final song in newPlayable) {
      cacheEntries.add(
        MusicCacheEntry.fromSong(
          song: song,
          provider: song.providerId ?? 'unknown',
        ),
      );
    }
    for (final song in newNonPlayable) {
      cacheEntries.add(
        MusicCacheEntry.fromSong(
          song: song,
          provider: song.providerId ?? 'unknown',
        ),
      );
    }
    for (final video in newYouTube) {
      cacheEntries.add(MusicCacheEntry.fromYouTube(video: video));
    }

    if (cacheEntries.isNotEmpty) {
      await _cacheDao.upsertCacheEntries(cacheEntries);
    }

    // Apply merged results
    if (newPlayable.isNotEmpty ||
        newNonPlayable.isNotEmpty ||
        newYouTube.isNotEmpty) {
      setState(() {
        _playableResults.addAll(newPlayable);
        _nonPlayableResults.addAll(newNonPlayable);
        _youtubeResults.addAll(newYouTube);
        _showingCachedResults = false;
      });
    }
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

  List<SearchResult> _searchDownloadedSongs(String query) {
    final normalizedQuery = query.toLowerCase();
    final downloadedSongs = LibraryService().downloadedSongs;
    if (normalizedQuery.isEmpty) {
      return downloadedSongs.map(SongSearchResult.new).toList();
    }
    return downloadedSongs
        .where((song) {
          final haystack = '${song.title} ${song.artist} ${song.album ?? ''}'
              .toLowerCase();
          return haystack.contains(normalizedQuery);
        })
        .map(SongSearchResult.new)
        .toList();
  }

  void _applyResults(List<SearchResult> results) {
    final playable = <Song>{};
    final nonPlayable = <Song>{};
    final youtube = <YouTubeMusicResult>{};

    for (final result in results) {
      if (result is SongSearchResult) {
        final song = result.song;
        final playability = _providerManager.validatePlayability(song);
        if (playability == SourcePlayability.playable) {
          playable.add(song);
        } else {
          nonPlayable.add(song);
        }
      } else if (result is YouTubeSearchResult) {
        youtube.add(result.video);
      }
    }

    setState(() {
      _playableResults = playable.toList();
      _nonPlayableResults = nonPlayable.toList();
      _youtubeResults = youtube.toList();
    });

    // Cache the results
    _cacheSearchResults(results);
  }

  Future<void> _cacheSearchResults(List<SearchResult> results) async {
    final cacheEntries = <MusicCacheEntry>[];
    for (final result in results) {
      if (result is SongSearchResult) {
        cacheEntries.add(
          MusicCacheEntry.fromSong(
            song: result.song,
            provider: result.song.providerId ?? 'unknown',
          ),
        );
      } else if (result is YouTubeSearchResult) {
        cacheEntries.add(MusicCacheEntry.fromYouTube(video: result.video));
      }
    }
    if (cacheEntries.isNotEmpty) {
      await _cacheDao.upsertCacheEntries(cacheEntries);
    }
  }

  void _selectGenre(String genre) {
    _searchController.text = genre;
    _performSearch(genre);
  }

  Future<void> _openUrl(String? rawUrl) async {
    if (rawUrl == null || rawUrl.trim().isEmpty || !mounted) return;
    final uri = Uri.parse(rawUrl.trim());
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      try {
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.inAppWebView);
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not open the source page.'),
              backgroundColor: AppTheme.surfaceCard,
            ),
          );
        }
      }
    }
  }

  Future<void> _playYouTubeAudio(YouTubeMusicResult video) async {
    final playerService = PlayerService();
    if (_isPlayingVideo(video.videoId)) {
      await playerService.togglePlayPause();
      if (mounted) setState(() {});
      return;
    }

    setState(() {
      _loadingVideoId = video.videoId;
    });

    try {
      await playerService.playYouTubeAudio(
        video,
        contextQueue: _youtubeResults,
        onError: (err) {
          if (mounted) {
           ScaffoldMessenger.of(context).showSnackBar(
               SnackBar(
                 content: Text(err),
                 backgroundColor: AppTheme.surfaceCard,
               ),
             );
          }
        },
      );
    } finally {
      if (mounted) {
        setState(() {
          _loadingVideoId = null;
        });
      }
    }
  }

  bool _isPlayingVideo(String videoId) {
    final playerService = PlayerService();
    if (!playerService.isPlaying) return false;
    final currentSong = playerService.currentSong;
    if (currentSong != null && currentSong.id == 'yt_$videoId') {
      return true;
    }
    final currentYt = playerService.currentYouTubeVideo;
    if (currentYt != null && currentYt.videoId == videoId) {
      return true;
    }
    return false;
  }

  void _toggleYouTubeLike(YouTubeMusicResult video) async {
    final libraryService = LibraryService();
    await libraryService.toggleYouTubeLike(video);
    if (mounted) setState(() {});
  }

  void _skipYouTubeVideo(YouTubeMusicResult video) {
    // Remove from current search results
    setState(() {
      _youtubeResults.removeWhere((v) => v.videoId == video.videoId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Search',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        children: [
          if (_isOffline) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppTheme.primary.withValues(alpha: 0.35),
                ),
              ),
              child: const Text(
                'Offline Mode: showing downloaded Musi tracks only',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppTheme.primaryLight,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          MusiSearchBar(
            controller: _searchController,
            hintText: 'Search songs, artists, genres...',
            onChanged: _onSearchChanged,
            onSubmitted: _onSearchSubmitted,
            onClear: _onClearSearch,
          ),
          const SizedBox(height: 12),
          _buildGenreTags(),
          const SizedBox(height: 16),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            ..._buildResults(),
          const SizedBox(height: 110),
        ],
      ),
    );
  }

  Widget _buildGenreTags() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _genreTags.map((tag) {
        return InkWell(
          onTap: () => _selectGenre(tag),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppTheme.surfaceCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppTheme.primary.withValues(alpha: 0.25),
              ),
            ),
            child: Text(
              tag,
              style: const TextStyle(
                color: AppTheme.primaryLight,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  List<Widget> _buildResults() {
    final children = <Widget>[];
    final hasResults =
        _playableResults.isNotEmpty ||
        _nonPlayableResults.isNotEmpty ||
        _youtubeResults.isNotEmpty;

    if (!hasResults) {
      children.add(_buildEmptyState());
      return children;
    }

    if (_showingCachedResults) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
          child: Text(
            'Showing cached results — fetching latest...',
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
          ),
        ),
      );
    }

    if (_playableResults.isNotEmpty) {
      children.add(
        _buildSectionHeader('PLAYABLE IN MUSI', _playableResults.length),
      );
      children.addAll(
        _playableResults.map(
          (song) => SongTile(song: song, queueContext: _playableResults),
        ),
      );
    } else if (_nonPlayableResults.isNotEmpty || _youtubeResults.isNotEmpty) {
      children.add(_buildSectionHeader('PLAYABLE IN MUSI', 0));
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
          child: Text(
            'No authorized source found. Try YouTube results below.',
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
          ),
        ),
      );
    }

    if (_nonPlayableResults.isNotEmpty) {
      children.add(
        _buildSectionHeader(
          'OTHER AUTHORIZED SOURCES',
          _nonPlayableResults.length,
        ),
      );
      children.addAll(_nonPlayableResults.map(_buildNonPlayableTile));
    }

    if (_youtubeResults.isNotEmpty) {
      children.add(
        _buildSectionHeader('YOUTUBE MUSIC', _youtubeResults.length),
      );
      children.add(
        ListenableBuilder(
          listenable: Listenable.merge([PlayerService(), LibraryService()]),
          builder: (context, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: _youtubeResults
                  .map((video) => _buildYouTubeTile(video))
                  .toList(),
            );
          },
        ),
      );
    }

    return children;
  }

  Widget _buildNonPlayableTile(Song song) {
    final playability = _providerManager.validatePlayability(song);
    final providerName = song.providerName ?? 'Authorized source';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: AppTheme.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: song.sourceUrl != null ? () => _openUrl(song.sourceUrl) : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  color: AppTheme.textMuted,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '$providerName • ${_getPlayabilityLabel(playability)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (song.sourceUrl != null)
                  const Icon(
                    Icons.open_in_new_rounded,
                    color: AppTheme.accent,
                    size: 18,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildYouTubeTile(YouTubeMusicResult video) {
    final libraryService = LibraryService();
    final isLiked = libraryService.likedYouTubeVideos.any(
      (v) => v.videoId == video.videoId,
    );
    final isPlaying = _isPlayingVideo(video.videoId);
    final isLoading = _loadingVideoId == video.videoId;

    return YouTubeResultTile(
      video: video,
      onTap: () => _playYouTubeAudio(video),
      onPlay: () => _playYouTubeAudio(video),
      onLike: () => _toggleYouTubeLike(video),
      onAddToPlaylist: () =>
          PlaylistPickerSheet.show(context, video, libraryService),
      onSkip: () => _skipYouTubeVideo(video),
      isLiked: isLiked,
      isPlaying: isPlaying,
      isLoading: isLoading,
    );
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Column(
        children: [
          Icon(
            _isOffline ? Icons.folder_off_rounded : Icons.search_off_rounded,
            size: 52,
            color: AppTheme.textMuted,
          ),
          const SizedBox(height: 16),
          Text(
            _isOffline
                ? 'No downloaded songs match your search'
                : 'No results found',
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _isOffline
                ? 'Download Musi tracks while online to listen offline.'
                : 'Try a different artist, title, or genre.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, int count) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: AppTheme.primaryLight,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.1,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              count.toString(),
              style: const TextStyle(
                color: AppTheme.primaryLight,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _getPlayabilityLabel(SourcePlayability playability) {
    switch (playability) {
      case SourcePlayability.notPlayableUnknownLicense:
        return 'License unavailable';
      case SourcePlayability.notPlayableNoStreamUrl:
        return 'No stream URL';
      case SourcePlayability.notPlayableProviderDisabled:
        return 'Provider disabled';
      case SourcePlayability.notPlayableOfflineMode:
        return 'Offline mode';
      case SourcePlayability.playable:
        return 'Playable';
    }
  }
}

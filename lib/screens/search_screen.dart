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

  /// Recent list shown when the search field is empty — the user's most
  /// recently searched or played songs (max 25, newest first), rendered with
  /// the same tiles as Home so only the content differs, not the design.
  List<YouTubeMusicResult> _recentYouTube = [];
  List<Song> _recentSongs = [];
  bool _isLoadingRecents = false;
  String? _trackedSongId;

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
    // Seed from what is already playing, otherwise the first position tick
    // looks like a new track and re-runs the recents query that
    // _loadInitialResults has just done.
    _trackedSongId = PlayerService().currentSong?.id;
    _loadInitialResults();
    // Keep the recent list fresh when a song is played from anywhere (Home,
    // Library, a playlist). IndexedStack keeps this screen alive, so initState
    // alone would never fire again.
    PlayerService().addListener(_onPlaybackChanged);
  }

  @override
  void dispose() {
    PlayerService().removeListener(_onPlaybackChanged);
    _debounce?.cancel();
    _cancelToken?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onPlaybackChanged() {
    final songId = PlayerService().currentSong?.id;
    if (songId == _trackedSongId) return;
    _trackedSongId = songId;
    // A play just happened, so the played song belongs at the top of recents.
    if (_isShowingRecents) _loadRecents();
  }

  /// True when the user has not typed a query, i.e. the page should present
  /// their recent songs rather than search results.
  bool get _isShowingRecents => _searchController.text.trim().isEmpty;

  Future<void> _loadInitialResults() async {
    final version = ++_requestVersion;
    _cancelToken?.cancel();
    _cancelToken = CancelableToken();

    // With no query the page shows the user's recent songs, not generic
    // recommendations — the only functional difference from the Home page.
    if (_isShowingRecents) {
      await _loadRecents();
      return;
    }

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
        setState(() {
          _isLoading = false;
          _showingCachedResults = false;
        });
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

  /// Load the 25 most recently searched or played songs, newest first.
  ///
  /// Read straight from the shared music cache, so it picks up songs played
  /// from any screen as well as anything returned by a search.
  Future<void> _loadRecents() async {
    if (mounted) setState(() => _isLoadingRecents = true);
    try {
      final entries = await _cacheDao.getRecentlySearchedOrPlayed(limit: 25);

      final youtube = <YouTubeMusicResult>[];
      final songs = <Song>[];
      for (final entry in entries) {
        if (entry.isYouTube) {
          final id = entry.youtubeVideoId ?? entry.sourceId;
          if (id.isEmpty) continue;
          youtube.add(
            YouTubeMusicResult(
              videoId: id,
              title: entry.title,
              channelTitle: entry.artist ?? '',
              thumbnailUrl: entry.thumbnailUrl ?? '',
              youtubeUrl:
                  entry.sourceUrl ?? 'https://www.youtube.com/watch?v=$id',
              durationSeconds: entry.duration > 0 ? entry.duration : null,
            ),
          );
        } else if (entry.isAuthorized) {
          songs.add(
            Song(
              id: entry.sourceId,
              title: entry.title,
              artist: entry.artist ?? '',
              album: entry.album,
              artworkUrl: entry.thumbnailUrl,
              streamUrl: entry.sourceUrl ?? '',
              duration: entry.duration,
              providerId: entry.provider,
              providerName: entry.provider,
            ),
          );
        }
      }

      if (!mounted) return;
      setState(() {
        _recentYouTube = youtube;
        _recentSongs = songs;
        _isLoadingRecents = false;
        _playableResults = [];
        _nonPlayableResults = [];
        _youtubeResults = [];
      });
      debugPrint(
        'SearchScreen: loaded ${youtube.length + songs.length} recent songs',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingRecents = false;
        _recentYouTube = [];
        _recentSongs = [];
      });
      debugPrint('SearchScreen: could not load recent songs: $e');
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

    // An emptied search box goes back to the recent list, not to blank search
    // results for an empty query.
    if (cleanQuery.isEmpty) {
      setState(() {
        _isLoading = false;
        _showingCachedResults = false;
        _playableResults = [];
        _nonPlayableResults = [];
        _youtubeResults = [];
      });
      await _loadRecents();
      return;
    }

    if (mounted) {
      setState(() {
        _isLoading = true;
        _showingCachedResults = false;
        _playableResults = [];
        _nonPlayableResults = [];
        _youtubeResults = [];
      });
    }

    // Save to search history
    await _historyDao.saveSearchQuery(cleanQuery);

    // 1. Check cache first for fast results
    if (!_isOffline) {
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
          durationSeconds: entry.duration > 0 ? entry.duration : null,
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
        // Queue against whichever list the user is looking at, so next/previous
        // walks the recent list instead of stale search results.
        contextQueue: _isShowingRecents ? _recentYouTube : _youtubeResults,
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
    // Remove from the list the user is currently looking at
    setState(() {
      if (_isShowingRecents) {
        _recentYouTube.removeWhere((v) => v.videoId == video.videoId);
      } else {
        _youtubeResults.removeWhere((v) => v.videoId == video.videoId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Same title treatment as the Home page, so switching tabs does not feel
      // like switching apps.
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppTheme.primary, AppTheme.accent],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.search_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'Search',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 24,
                color: Colors.white,
                letterSpacing: -0.5,
              ),
            ),
          ],
        ),
      ),
      // Vertical-only padding with per-section horizontal padding, matching
      // Home exactly instead of applying one blanket inset.
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (_isOffline) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
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
            ),
            const SizedBox(height: 12),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: MusiSearchBar(
              controller: _searchController,
              hintText: 'Search songs, artists, genres...',
              onChanged: _onSearchChanged,
              onSubmitted: _onSearchSubmitted,
              onClear: _onClearSearch,
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _buildGenreTags(),
          ),
          const SizedBox(height: 16),
          // Recents replace search results whenever the field is empty.
          if (_isShowingRecents)
            ..._buildRecents()
          // Show results as soon as any exist rather than hiding them behind the
          // spinner for the whole network round-trip.
          else if (_isLoading &&
              _playableResults.isEmpty &&
              _nonPlayableResults.isEmpty &&
              _youtubeResults.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            ..._buildResults(),
          // Clearance for the mini player overlaying the bottom of the page.
          const SizedBox(height: 100),
        ],
      ),
    );
  }

  /// The recent list, built from the same tiles as Home so only the content
  /// differs from the Home page, not the design.
  List<Widget> _buildRecents() {
    if (_isLoadingRecents && _recentYouTube.isEmpty && _recentSongs.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 32),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }

    final total = _recentYouTube.length + _recentSongs.length;
    if (total == 0) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              const SizedBox(height: 24),
              Icon(Icons.history_rounded, size: 52, color: AppTheme.textMuted),
              const SizedBox(height: 16),
              const Text(
                'No recent songs',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Songs you search for or play will appear here.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ];
    }

    return [
      _buildRecentHeader(total),
      if (_recentSongs.isNotEmpty) ...[
        _buildSectionHeader('Playable in Musi', _recentSongs.length),
        ..._recentSongs.map(
          (song) => SongTile(song: song, queueContext: _recentSongs),
        ),
      ],
      if (_recentYouTube.isNotEmpty) ...[
        _buildSectionHeader('YouTube Music', _recentYouTube.length),
        ListenableBuilder(
          listenable: Listenable.merge([PlayerService(), LibraryService()]),
          builder: (context, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: _recentYouTube.map(_buildYouTubeTile).toList(),
            );
          },
        ),
      ],
    ];
  }

  /// Header row mirroring Home's "Recently Played" title plus Play All action.
  Widget _buildRecentHeader(int total) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'Recent',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
          if (total > 1)
            TextButton(
              onPressed: _playAllRecents,
              child: const Text(
                'Play All',
                style: TextStyle(
                  color: AppTheme.primaryLight,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Queue the recent list in its newest-first order and start with the top
  /// entry, mirroring Home's Play All.
  Future<void> _playAllRecents() async {
    final playerService = PlayerService();
    final queue = _recentYouTube;
    if (queue.isEmpty) return;

    try {
      await playerService.playYouTubeAudio(
        queue.first,
        contextQueue: queue,
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
    } catch (e) {
      debugPrint('SearchScreen: Play All on recents failed: $e');
    }
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Text(
            'Showing cached results — fetching latest...',
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
          ),
        ),
      );
    }

    if (_playableResults.isNotEmpty) {
      children.addAll(
        _playableResults.map(
          (song) => SongTile(song: song, queueContext: _playableResults),
        ),
      );
    } else if (_nonPlayableResults.isNotEmpty || _youtubeResults.isNotEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
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
          'Other authorized sources',
          _nonPlayableResults.length,
        ),
      );
      children.addAll(_nonPlayableResults.map(_buildNonPlayableTile));
    }

    if (_youtubeResults.isNotEmpty) {
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

  /// Section header in the Home page's style: bold 18px primary-colour title
  /// with an optional count badge, instead of the old uppercase letter-spaced
  /// label.
  Widget _buildSectionHeader(String title, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
          if (count > 0)
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

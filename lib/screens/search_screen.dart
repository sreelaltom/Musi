import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../database/settings_dao.dart';
import '../database/music_cache_dao.dart';
import '../database/search_history_dao.dart';
import '../database/artist_mix_recent_dao.dart';
import '../models/artist_mix_recent.dart';
import '../models/playlist_item.dart';
import '../models/music_cache_entry.dart';
import '../models/music_provider.dart' show SourcePlayability;
import '../models/search_result.dart'
    show SearchResult, SongSearchResult, YouTubeSearchResult;
import '../models/song.dart';
import '../models/youtube_music_result.dart';
import '../services/library_service.dart';
import '../services/download_service.dart';
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
  final ArtistMixRecentDao _artistMixRecentDao = ArtistMixRecentDao();

  Timer? _debounce;
  CancelableToken? _cancelToken;
  int _requestVersion = 0;
  bool _isApplyingPreset = false;

  List<Song> _playableResults = [];
  List<Song> _nonPlayableResults = [];
  List<YouTubeMusicResult> _youtubeResults = [];
  _ArtistMix? _buildArtistMix() {
    final query = _artistNormalize(_searchController.text);
    if (query.isEmpty) return null;

    final songs = _playableResults;
    String? artist;
    // Prefer an exact artist match, then an artist name that contains the
    // query (for channel suffixes), then infer the artist from a song match.
    for (final song in songs) {
      final candidate = _artistNormalize(song.artist);
      if (candidate.isNotEmpty && candidate == query) {
        artist = song.artist;
        break;
      }
    }
    final artistMatches = songs
        .where((song) => _artistNormalize(song.artist).contains(query))
        .map((song) => song.artist)
        .toList();
    if (artist == null && artistMatches.isNotEmpty) {
      artist = artistMatches.first;
    }
    if (artist == null) {
      for (final song in [...songs, ..._nonPlayableResults]) {
        final title = _artistNormalize(song.title);
        if (title.contains(query) || query.contains(title)) {
          if (song.artist.trim().isNotEmpty) {
            artist = song.artist;
            break;
          }
        }
      }
    }

    if (artist != null) {
      final normalizedArtist = _artistNormalize(artist);
      final artistSongs = songs
          .where((song) => _artistNormalize(song.artist) == normalizedArtist)
          .take(15)
          .toList();
      if (artistSongs.isNotEmpty) {
        final artistVideos = _youtubeResults
            .where((video) => _isArtistRelatedVideo(video, normalizedArtist))
            .take(15 - artistSongs.length)
            .toList();
        return _ArtistMix(artist, songs: artistSongs, videos: artistVideos);
      }
    }

    // YouTube channel names act as the artist identity when the provider has
    // no authorized audio tracks for this query.
    String? matchedChannel;
    for (final video in _youtubeResults) {
      final candidate = _artistNormalize(video.channelTitle);
      if (candidate == query || candidate.contains(query)) {
        matchedChannel = video.channelTitle.trim();
        break;
      }
    }
    if (matchedChannel == null) {
      for (final video in _youtubeResults) {
        if (_artistNormalize(video.title).contains(query) &&
            video.channelTitle.trim().isNotEmpty) {
          matchedChannel = video.channelTitle.trim();
          break;
        }
      }
    }
    if (matchedChannel == null) return null;
    // Use the identified channel/artist for the mix and its follow-up searches.
    // The original query can be a song title, which otherwise searches for
    // "<song title> songs" and leaves the collection with only one track.
    final artistName = matchedChannel;
    final artistKey = _artistNormalize(artistName);
    final videos = _youtubeResults
        .where(
          (video) =>
              _isArtistRelatedVideo(video, artistKey, fromArtistSearch: true),
        )
        .take(15)
        .toList();
    return videos.isEmpty ? null : _ArtistMix(artistName, videos: videos);
  }

  String _artistNormalize(String value) => _normalizeArtistName(value);

  bool _isLoading = false;
  bool _isOffline = false;
  bool _showingCachedResults = false;
  String? _loadingVideoId;

  /// Recent list shown when the search field is empty — the user's most
  /// recently searched or played songs (max 25, newest first), rendered with
  /// the same tiles as Home so only the content differs, not the design.
  List<YouTubeMusicResult> _recentYouTube = [];
  List<Song> _recentSongs = [];
  List<ArtistMixRecent> _recentArtistMixes = [];
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
    ArtistMixRecentDao.revision.addListener(_onRecentMixesChanged);
  }

  @override
  void dispose() {
    PlayerService().removeListener(_onPlaybackChanged);
    ArtistMixRecentDao.revision.removeListener(_onRecentMixesChanged);
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

  void _onRecentMixesChanged() {
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
      final results = await Future.wait([
        _cacheDao.getRecentlySearchedOrPlayed(limit: 25),
        _artistMixRecentDao.getRecent(limit: 10),
      ]);
      final entries = results[0] as List<MusicCacheEntry>;
      final mixes = results[1] as List<ArtistMixRecent>;

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
        _recentArtistMixes = mixes;
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
        _recentArtistMixes = [];
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
    final pageContent = _isShowingRecents
        ? _buildRecents()
        : _isLoading &&
              _playableResults.isEmpty &&
              _nonPlayableResults.isEmpty &&
              _youtubeResults.isEmpty
        ? const <Widget>[
            Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            ),
          ]
        : _buildResults();

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
      // Slivers instantiate result tiles on demand, keeping long result lists
      // responsive while scrolling and while playback state changes.
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
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
                ],
              ),
            ),
          ),
          SliverList(delegate: SliverChildListDelegate(pageContent)),
          // Clearance for the mini player overlaying the bottom of the page.
          const SliverToBoxAdapter(child: SizedBox(height: 120)),
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

    final total =
        _recentArtistMixes.length + _recentYouTube.length + _recentSongs.length;
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
                'Songs you search for or play and artist mixes you listen to will appear here.',
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
      if (_recentArtistMixes.isNotEmpty) ...[
        _buildSectionHeader('Artist mixes', _recentArtistMixes.length),
        ..._recentArtistMixes.map(_buildRecentArtistMixTile),
      ],
      if (_recentSongs.isNotEmpty) ...[
        _buildSectionHeader('Playable in Musi', _recentSongs.length),
        ..._recentSongs.map(
          (song) => SongTile(song: song, queueContext: _recentSongs),
        ),
      ],
      if (_recentYouTube.isNotEmpty) ...[
        _buildSectionHeader('YouTube Music', _recentYouTube.length),
        ..._recentYouTube.map(_buildYouTubeTile),
      ],
    ];
  }

  Widget _buildRecentArtistMixTile(ArtistMixRecent recent) {
    final mix = _ArtistMix(
      recent.artist,
      songs: recent.songs,
      videos: recent.videos,
    );
    final artwork = recent.songs.isNotEmpty
        ? recent.songs.first.artworkUrl
        : recent.videos.first.thumbnailUrl;
    final count = recent.songs.length + recent.videos.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Material(
        color: AppTheme.surfaceCard,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  _ArtistMixScreen(mix: mix, allowOnlineExpansion: !_isOffline),
            ),
          ),
          child: ListTile(
            leading: artwork == null || artwork.isEmpty
                ? const CircleAvatar(child: Icon(Icons.queue_music_rounded))
                : ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.network(
                      artwork,
                      width: 52,
                      height: 52,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox(
                        width: 52,
                        height: 52,
                        child: Icon(Icons.queue_music_rounded),
                      ),
                    ),
                  ),
            title: Text(
              'More from ${recent.artist}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text('$count tracks • Artist mix'),
            trailing: const Icon(Icons.chevron_right_rounded),
          ),
        ),
      ),
    );
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
          if (_recentYouTube.length > 1)
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

    final artistMix = _buildArtistMix();
    if (artistMix != null) {
      children.add(_buildArtistMixCard(artistMix));
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
      children.addAll(_youtubeResults.map(_buildYouTubeTile));
    }

    return children;
  }

  Widget _buildArtistMixCard(_ArtistMix mix) {
    final artwork = mix.songs.isNotEmpty
        ? mix.songs.first.artworkUrl
        : mix.videos.first.thumbnailUrl;
    final count = mix.songs.length + mix.videos.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 14),
      child: Material(
        color: AppTheme.surfaceCard,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  _ArtistMixScreen(mix: mix, allowOnlineExpansion: !_isOffline),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(
                    width: 64,
                    height: 64,
                    child: artwork == null || artwork.isEmpty
                        ? Container(
                            color: AppTheme.surfaceLight,
                            child: const Icon(Icons.person_rounded, size: 32),
                          )
                        : Image.network(
                            artwork,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(
                              color: AppTheme.surfaceLight,
                              child: const Icon(Icons.person_rounded, size: 32),
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'ARTIST MIX',
                        style: TextStyle(
                          color: AppTheme.accent,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'More from ${mix.artist}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        count < 10
                            ? '$count tracks • Tap to find more'
                            : '$count tracks • Play as a collection',
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton.filled(
                  tooltip: 'Play artist mix',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _ArtistMixScreen(
                        mix: mix,
                        allowOnlineExpansion: !_isOffline,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.play_arrow_rounded),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
    return ListenableBuilder(
      listenable: Listenable.merge([
        PlayerService(),
        LibraryService(),
        DownloadService(),
      ]),
      builder: (context, _) {
        final libraryService = LibraryService();
        final downloadService = DownloadService();
        final song = _songForYouTubeVideo(video);
        final isLiked = libraryService.likedYouTubeVideos.any(
          (v) => v.videoId == video.videoId,
        );
        return YouTubeResultTile(
          video: video,
          onTap: () => _playYouTubeAudio(video),
          onPlay: () => _playYouTubeAudio(video),
          onLike: () => _toggleYouTubeLike(video),
          onAddToPlaylist: () =>
              PlaylistPickerSheet.show(context, video, libraryService),
          onSkip: () => _skipYouTubeVideo(video),
          isLiked: isLiked,
          isPlaying: _isPlayingVideo(video.videoId),
          isLoading: _loadingVideoId == video.videoId,
          isDownloaded: libraryService.isDownloaded(song.id),
          isDownloading: downloadService.isDownloading(song.id),
          downloadProgress: downloadService.getProgress(song.id),
          onDownload: () =>
              libraryService.toggleDownload(song, onError: _showDownloadError),
          onCancelDownload: () => downloadService.cancelDownload(song.id),
          onDeleteDownload: () =>
              libraryService.toggleDownload(song, onError: _showDownloadError),
        );
      },
    );
  }

  Song _songForYouTubeVideo(YouTubeMusicResult video) => Song(
    id: 'yt_${video.videoId}',
    title: video.title,
    artist: video.channelTitle,
    album: 'YouTube Music',
    artworkUrl: video.thumbnailUrl,
    streamUrl: video.streamUrl ?? '',
    sourceUrl: video.youtubeUrl,
    duration: video.durationSeconds ?? 0,
    providerId: 'youtube',
    providerName: 'YouTube',
  );

  void _showDownloadError(String error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error), backgroundColor: AppTheme.surfaceCard),
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

String _normalizeArtistName(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim()
    .replaceAll(RegExp(r'\b([a-z])\s+([a-z])\b'), r'$1$2');

bool _isArtistRelatedVideo(
  YouTubeMusicResult video,
  String artistKey, {
  bool fromArtistSearch = false,
}) {
  final title = _normalizeArtistName(video.title);
  final channel = _normalizeArtistName(video.channelTitle);
  final description = _normalizeArtistName(video.description ?? '');
  final appearsRelated =
      channel.contains(artistKey) ||
      title.contains(artistKey) ||
      description.contains(artistKey);
  if (!appearsRelated && !fromArtistSearch) return false;
  final textToScreen = '$title $description';
  if (const [
    'surah',
    'recitation',
    'interview',
    'trailer',
    'teaser',
    'news',
    'dialog',
    // Some search results misspell "dialogue" as "dialotrap".
    'dialo',
    'scene',
    'reaction',
    'review',
    'speech',
    'conversation',
  ].any(textToScreen.contains)) {
    return false;
  }
  if (textToScreen.contains('full movie')) return false;
  final duration = video.durationSeconds;
  // Search metadata often omits duration. Keep those artist-search matches;
  // reject known very short clips and unusually long uploads only.
  final musicLength = duration == null || (duration >= 75 && duration <= 1800);
  return musicLength && (appearsRelated || fromArtistSearch);
}

class _ArtistMix {
  final String artist;
  final List<Song> songs;
  final List<YouTubeMusicResult> videos;

  _ArtistMix(this.artist, {this.songs = const [], this.videos = const []});

  Future<void> play(PlayerService player, {bool shuffle = false}) async {
    if (videos.isEmpty) {
      if (shuffle) {
        await player.shuffleAndPlay(List<Song>.from(songs));
      } else {
        await player.setQueue(List<Song>.from(songs));
      }
      return;
    }
    if (songs.isEmpty) {
      final queue = List<YouTubeMusicResult>.from(videos);
      if (shuffle) queue.shuffle();
      await player.playYouTubeAudio(queue.first, contextQueue: queue);
      return;
    }

    final queue = <PlaylistItem>[
      ...songs.asMap().entries.map(
        (entry) => PlaylistItem.fromSong(
          playlistId: 'artist-mix',
          song: entry.value,
          position: entry.key,
        ),
      ),
      ...videos.asMap().entries.map(
        (entry) => PlaylistItem.fromYouTube(
          playlistId: 'artist-mix',
          video: entry.value,
          position: songs.length + entry.key,
        ),
      ),
    ];
    if (queue.isEmpty) return;
    if (shuffle) {
      await player.shuffleAndPlayPlaylist(queue);
    } else {
      await player.setMixedQueue(queue);
    }
  }
}

class _ArtistMixScreen extends StatefulWidget {
  final _ArtistMix mix;
  final bool allowOnlineExpansion;

  const _ArtistMixScreen({
    required this.mix,
    required this.allowOnlineExpansion,
  });

  @override
  State<_ArtistMixScreen> createState() => _ArtistMixScreenState();
}

class _ArtistMixScreenState extends State<_ArtistMixScreen> {
  late _ArtistMix _mix;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _mix = widget.mix;
    _loadMoreArtistTracks();
  }

  Future<void> _loadMoreArtistTracks() async {
    if (!widget.allowOnlineExpansion) return;
    final currentCount = _mix.songs.length + _mix.videos.length;
    if (currentCount >= 10) return;
    setState(() => _loadingMore = true);
    try {
      final manager = MusicProviderManager();
      final queryVariants = [
        '${_mix.artist} songs',
        '${_mix.artist} top songs',
      ];
      final resultBatches = await Future.wait(
        queryVariants.map((query) => manager.searchAll(query)),
      );
      final results = resultBatches.expand((batch) => batch);
      final songs = List<Song>.from(_mix.songs);
      final videos = List<YouTubeMusicResult>.from(_mix.videos);
      final songKeys = songs
          .map(
            (song) =>
                '${song.title.toLowerCase()}|${song.artist.toLowerCase()}',
          )
          .toSet();
      final videoIds = videos.map((video) => video.videoId).toSet();
      final normalizedArtist = _normalizeArtistName(_mix.artist);

      for (final result in results) {
        if (result is SongSearchResult &&
            _normalizeArtistName(result.song.artist)
                .contains(normalizedArtist) &&
            MusicProviderManager().validatePlayability(result.song) ==
                SourcePlayability.playable) {
          final key =
              '${result.song.title.toLowerCase()}|${result.song.artist.toLowerCase()}';
          if (songKeys.add(key) && songs.length + videos.length < 15) {
            songs.add(result.song);
          }
        } else if (result is YouTubeSearchResult &&
            _isArtistRelatedVideo(
              result.video,
              normalizedArtist,
              fromArtistSearch: true,
            ) &&
            videoIds.add(result.video.videoId) &&
            songs.length + videos.length < 15) {
          videos.add(result.video);
        }
      }
      if (mounted) {
        setState(
          () => _mix = _ArtistMix(_mix.artist, songs: songs, videos: videos),
        );
      }
    } catch (error) {
      debugPrint('Artist mix search failed: $error');
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = PlayerService();
    final library = LibraryService();
    final mix = _mix;
    final count = mix.songs.length + mix.videos.length;

    return Scaffold(
      appBar: AppBar(title: Text(mix.artist)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF35230A), AppTheme.surfaceCard],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'ARTIST MIX',
                  style: TextStyle(
                    color: AppTheme.accent,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  mix.artist,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _loadingMore
                      ? '$count tracks • finding more songs…'
                      : '$count tracks',
                  style: const TextStyle(color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: () => _playMix(mix),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Play'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _playMix(mix, shuffle: true),
                      icon: const Icon(Icons.shuffle_rounded),
                      label: const Text('Shuffle'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 20, 4, 8),
            child: Text(
              'Songs',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ...mix.songs.map(
            (song) => SongTile(song: song, queueContext: mix.songs),
          ),
          ...mix.videos.map(
            (video) => ListenableBuilder(
              listenable: player,
              builder: (context, _) {
                final isCurrentTrack =
                    player.currentYouTubeVideo?.videoId == video.videoId;
                return YouTubeResultTile(
                  video: video,
                  isLiked: library.likedYouTubeVideos.any(
                    (item) => item.videoId == video.videoId,
                  ),
                  isPlaying: isCurrentTrack && player.isPlaying,
                  isLoading: isCurrentTrack && player.isBuffering,
                  onTap: () =>
                      player.playYouTubeAudio(video, contextQueue: mix.videos),
                  onLike: () => library.toggleYouTubeLike(video),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _playMix(_ArtistMix mix, {bool shuffle = false}) async {
    await mix.play(PlayerService(), shuffle: shuffle);
    await ArtistMixRecentDao().save(
      artist: mix.artist,
      songs: mix.songs,
      videos: mix.videos,
    );
  }
}

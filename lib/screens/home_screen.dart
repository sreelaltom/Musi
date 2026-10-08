import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/song.dart';
import '../models/playlist_item.dart';
import '../models/youtube_music_result.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../services/youtube_audio_service.dart';
import '../services/youtube_music_api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/playlist_tile.dart';
import '../widgets/song_tile.dart';
import '../widgets/youtube_result_tile.dart';
import 'playlist_picker_sheet.dart';
import 'playlist_screen.dart';
import 'player_screen.dart';
import 'settings_screen.dart';

@visibleForTesting
String greetingForHour(int hour) {
  if (hour < 0 || hour > 23) {
    throw RangeError.range(hour, 0, 23, 'hour');
  }
  if (hour == 0) return 'Good midnight';
  if (hour >= 5 && hour < 12) return 'Good morning';
  if (hour == 12) return 'Good noon';
  if (hour >= 13 && hour < 17) return 'Good afternoon';
  if (hour >= 17 && hour < 21) return 'Good evening';
  return 'Good night';
}

@visibleForTesting
IconData greetingIconForHour(int hour) {
  if (hour == 0) return Icons.auto_awesome_rounded;
  if (hour >= 5 && hour < 17) return Icons.wb_sunny_rounded;
  if (hour >= 17 && hour < 21) return Icons.wb_twilight_rounded;
  return Icons.nightlight_round;
}

class HomeScreen extends StatefulWidget {
  final VoidCallback onSearchTap;
  final void Function(int tabIndex) onNavigateToLibrary;

  const HomeScreen({
    super.key,
    required this.onSearchTap,
    required this.onNavigateToLibrary,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final YouTubeMusicApiService _ytService = YouTubeMusicApiService();
  final LibraryService _libraryService = LibraryService();
  final PlayerService _playerService = PlayerService();

  List<YouTubeMusicResult> _trendingTracks = [];
  bool _isLoadingTrending = true;
  String? _trendingError;
  String? _loadingVideoId;

  /// Newest releases, sourced from a date-sorted query rather than a fixed list.
  List<YouTubeMusicResult> _newReleases = [];
  bool _isLoadingNewReleases = true;
  String? _newReleasesError;
  String? _loadingReleaseId;
  final Set<String> _checkedRecentTitleIds = {};
  late final AnimationController _timeOfDayAnimation;
  @override
  void initState() {
    super.initState();
    _timeOfDayAnimation = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
      lowerBound: 0,
      upperBound: 1,
    )..repeat(reverse: true);
    unawaited(_repairUnknownRecentTitles());
    _refreshHomeSections();
  }

  @override
  void dispose() {
    _timeOfDayAnimation.dispose();
    super.dispose();
  }

  /// Reload every network-backed discovery section, for pull-to-refresh.
  Future<void> _refreshHomeSections() async {
    await Future.wait([_loadTrendingTracks(), _loadNewReleases()]);
    unawaited(_repairUnknownRecentTitles());
  }

  Future<void> _repairUnknownRecentTitles() async {
    await _libraryService.init();
    final recentSongs = List<Song>.from(_libraryService.recentlyPlayed);
    final currentSong = _playerService.currentSong;
    if (currentSong != null &&
        !recentSongs.any((song) => song.id == currentSong.id)) {
      recentSongs.insert(0, currentSong);
    }
    final candidates = recentSongs
        .where(
          (song) =>
              !YouTubeMusicResult.isUsableTitle(song.title) ||
              !YouTubeMusicResult.isUsableTitle(song.artist),
        )
        .take(5);
    for (final song in candidates) {
      final videoId = YouTubeAudioService.extractVideoId(song);
      if (videoId == null || _checkedRecentTitleIds.contains(videoId)) continue;
      _checkedRecentTitleIds.add(videoId);

      final details = await _ytService.getVideoDetails(videoId);
      if (!mounted || details == null || !details.hasUsableTitle) {
        _checkedRecentTitleIds.remove(videoId);
        continue;
      }

      final recoveredArtist =
          YouTubeMusicResult.isUsableTitle(details.channelTitle)
          ? details.channelTitle
          : 'YouTube';
      final updatedSong = song.copyWith(
        title: details.title,
        artist: recoveredArtist,
        artworkUrl: details.thumbnailUrl.isNotEmpty
            ? details.thumbnailUrl
            : song.artworkUrl,
        duration:
            details.durationSeconds != null && details.durationSeconds! > 0
            ? details.durationSeconds
            : song.duration,
      );
      await _libraryService.updateRecentlyPlayedMetadata(updatedSong);
      _playerService.updateCurrentSongMetadata(updatedSong);
    }
  }

  Future<void> _loadTrendingTracks() async {
    setState(() {
      _isLoadingTrending = true;
      _trendingError = null;
    });

    try {
      final results = await _ytService.getTrendingHits(limit: 10);
      // Pre-filter to ensure only playable tracks are displayed
      final playableResults = await YouTubeAudioService().filterPlayable(
        results,
      );
      if (mounted) {
        setState(() {
          _trendingTracks = playableResults;
          _isLoadingTrending = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingTrending = false;
          _trendingError = 'Unable to load trending songs';
        });
      }
    }
  }

  /// Fetch the newest releases. Sorted by upload date upstream, so re-running
  /// this always reflects current releases rather than returning a stale list.
  Future<void> _loadNewReleases() async {
    if (mounted) {
      setState(() {
        _isLoadingNewReleases = true;
        _newReleasesError = null;
      });
    }

    try {
      final results = await _ytService.getNewReleases(limit: 5);
      final playableResults = await YouTubeAudioService().filterPlayable(
        results,
      );
      if (mounted) {
        setState(() {
          _newReleases = playableResults;
          _newReleasesError = playableResults.isEmpty
              ? 'No new releases found'
              : null;
          _isLoadingNewReleases = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingNewReleases = false;
          _newReleasesError = 'Unable to load new releases';
        });
      }
    }
  }

  /// Play [video] as part of [queue], the list it was tapped in, so
  /// next/previous walks that list instead of the other home section.
  Future<void> _playYouTubeAudio(
    YouTubeMusicResult video,
    List<YouTubeMusicResult> queue, {
    bool isNewRelease = false,
  }) async {
    final currentSong = _playerService.currentSong;
    final isCurrent =
        currentSong != null && currentSong.id == 'yt_${video.videoId}';

    if (isCurrent) {
      await _playerService.togglePlayPause();
      return;
    }

    // Tracked separately so the tile being tapped shows its own spinner.
    if (isNewRelease) {
      setState(() => _loadingReleaseId = video.videoId);
    } else {
      setState(() => _loadingVideoId = video.videoId);
    }

    try {
      await _playerService.playYouTubeAudio(
        video,
        contextQueue: queue,
        onError: (err) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(err),
              backgroundColor: AppTheme.error,
              behavior: SnackBarBehavior.floating,
            ),
          );
        },
      );
    } finally {
      if (mounted) {
        // Clear only the spinner this call set. Clearing both would let a
        // Trending tap cancel a Latest Releases tap that is still resolving.
        setState(() {
          if (isNewRelease) {
            _loadingReleaseId = null;
          } else {
            _loadingVideoId = null;
          }
        });
      }
    }
  }

  void _playAllTrending() {
    if (_trendingTracks.isNotEmpty) {
      _playYouTubeAudio(_trendingTracks.first, _trendingTracks);
    }
  }

  void _playAllNewReleases() {
    if (_newReleases.isNotEmpty) {
      _playYouTubeAudio(_newReleases.first, _newReleases, isNewRelease: true);
    }
  }

  String get _greeting {
    return greetingForHour(DateTime.now().hour);
  }

  IconData get _greetingIcon {
    return greetingIconForHour(DateTime.now().hour);
  }

  List<PlaylistItem> _recentQueueItems(List<Song> songs) =>
      songs.asMap().entries.map((entry) {
        final song = entry.value;
        final videoId = YouTubeAudioService.extractVideoId(song);
        if (videoId != null) {
          return PlaylistItem.fromYouTube(
            playlistId: '',
            video: YouTubeMusicResult(
              videoId: videoId,
              title: song.title,
              channelTitle: song.artist,
              thumbnailUrl: song.artworkUrl ?? '',
              youtubeUrl:
                  song.sourceUrl ?? 'https://www.youtube.com/watch?v=$videoId',
              durationSeconds: song.duration > 0 ? song.duration : null,
            ),
            position: entry.key,
          );
        }
        return PlaylistItem.fromSong(
          playlistId: '',
          song: song,
          position: entry.key,
        );
      }).toList();

  Future<void> _playRecentSong(Song song, List<Song> recentSongs) async {
    final videoId = YouTubeAudioService.extractVideoId(song);
    if (videoId != null) {
      await _playerService.playYouTubeAudio(
        YouTubeMusicResult(
          videoId: videoId,
          title: song.title,
          channelTitle: song.artist,
          thumbnailUrl: song.artworkUrl ?? '',
          youtubeUrl:
              song.sourceUrl ?? 'https://www.youtube.com/watch?v=$videoId',
          durationSeconds: song.duration > 0 ? song.duration : null,
        ),
        mixedContextQueue: _recentQueueItems(recentSongs),
      );
    } else {
      await _playerService.playSong(
        song,
        contextQueue: recentSongs,
        onError: (error) {
          if (!mounted) return;
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(error)));
        },
      );
    }
  }

  List<Song> _upNextSongs() {
    final index = _playerService.currentIndex;
    final ytQueue = _playerService.ytQueue;
    if (ytQueue.isNotEmpty) {
      return ytQueue
          .skip(index + 1)
          .map(
            (video) => Song(
              id: 'yt_${video.videoId}',
              title: video.title,
              artist: video.channelTitle,
              artworkUrl: video.thumbnailUrl.isEmpty
                  ? null
                  : video.thumbnailUrl,
              streamUrl: video.streamUrl ?? '',
              sourceUrl: video.youtubeUrl,
              duration: video.durationSeconds ?? 0,
              providerId: 'youtube',
              providerName: 'YouTube',
            ),
          )
          .toList();
    }

    final mixedQueue = _playerService.mixedQueue;
    if (mixedQueue.isNotEmpty) {
      final savedSongs = _playerService.queue;
      return mixedQueue.skip(index + 1).map((item) {
        if (item.isYouTube) {
          final video = item.resolveYouTube()!;
          return Song(
            id: 'yt_${video.videoId}',
            title: video.title,
            artist: video.channelTitle,
            artworkUrl: video.thumbnailUrl.isEmpty ? null : video.thumbnailUrl,
            streamUrl: video.streamUrl ?? '',
            sourceUrl: video.youtubeUrl,
            duration: video.durationSeconds ?? 0,
            providerId: 'youtube',
            providerName: 'YouTube',
          );
        }
        return savedSongs.where((song) => song.id == item.songId).firstOrNull ??
            item.resolveSong()!;
      }).toList();
    }

    final queue = _playerService.queue;
    return queue.skip(index + 1).toList();
  }

  Future<void> _playUpNextSong(Song song) async {
    final ytQueue = _playerService.ytQueue;
    if (ytQueue.isNotEmpty) {
      final videoId = YouTubeAudioService.extractVideoId(song);
      final video = ytQueue
          .where((item) => item.videoId == videoId)
          .firstOrNull;
      if (video != null) {
        await _playerService.playYouTubeAudio(video, contextQueue: ytQueue);
        return;
      }
    }

    final mixedQueue = _playerService.mixedQueue;
    if (mixedQueue.isNotEmpty) {
      final videoId = YouTubeAudioService.extractVideoId(song);
      if (videoId != null) {
        final video = mixedQueue
            .where((item) => item.youtubeVideoId == videoId)
            .firstOrNull
            ?.resolveYouTube();
        if (video != null) {
          await _playerService.playYouTubeAudio(
            video,
            mixedContextQueue: mixedQueue,
          );
          return;
        }
      }
      await _playerService.playSong(song, mixedContextQueue: mixedQueue);
      return;
    }

    await _playRecentSong(song, _playerService.queue);
  }

  void _openPlayer() {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/player'),
        builder: (_) => const PlayerScreen(),
      ),
    );
  }

  void _toggleLike(YouTubeMusicResult video) {
    final song = Song(
      id: 'yt_${video.videoId}',
      title: video.title,
      artist: video.channelTitle.isNotEmpty ? video.channelTitle : 'YouTube',
      album: 'YouTube Music',
      artworkUrl: video.thumbnailUrl.isNotEmpty ? video.thumbnailUrl : null,
      streamUrl: '',
      sourceUrl: video.youtubeUrl,
      duration: video.durationSeconds ?? 0,
      providerId: 'youtube',
      providerName: 'YouTube',
    );

    final wasLiked = _libraryService.isLiked(song.id);
    _libraryService.toggleLike(song);

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          wasLiked ? 'Removed from Liked Songs' : 'Saved to Liked Songs',
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: Listenable.merge([_libraryService, _playerService]),
        builder: (context, _) {
          final likedSongs = _libraryService.likedSongs;
          final likedYouTube = _libraryService.likedYouTubeVideos;
          final playlists = _libraryService.playlists;
          final recentSongs = _libraryService.recentlyPlayed;
          final downloads = _libraryService.downloadedSongs;
          final currentSong = _playerService.currentSong;
          final isPlayingGlobal = _playerService.isPlaying;
          final homeRecentSongs = <Song>[
            if (currentSong != null &&
                !recentSongs.any((song) => song.id == currentSong.id))
              currentSong,
            ...recentSongs,
          ];
          final upNextSongs = _upNextSongs();
          final continueListeningSongs = upNextSongs.isNotEmpty
              ? upNextSongs
              : homeRecentSongs;

          return RefreshIndicator(
            color: AppTheme.primary,
            backgroundColor: AppTheme.surfaceCard,
            onRefresh: _refreshHomeSections,
            child: ListView(
              // Keep the last row reachable above the global mini-player.
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 120),
              children: [
                _buildHeroHeader(),
                _buildHomeSearchButton(),
                const SizedBox(height: 18),
                _buildLikedSongsCard(likedSongs, likedYouTube),
                if (currentSong != null) ...[
                  const SizedBox(height: 18),
                  _buildNowPlayingCard(currentSong, isPlayingGlobal),
                ],
                if (continueListeningSongs.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  _buildContinueListening(continueListeningSongs),
                ],
                if (homeRecentSongs.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  _buildRecentlyPlayed(homeRecentSongs),
                ],
                const SizedBox(height: 24),

                // Section 1: Trending on YouTube (Top 10 Tracks)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.primary.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: AppTheme.primary.withValues(alpha: 0.3),
                              ),
                            ),
                            child: const Text(
                              'TOP 10',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.primaryLight,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Trending Hits',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                        ],
                      ),
                      if (_trendingTracks.isNotEmpty)
                        TextButton.icon(
                          onPressed: _playAllTrending,
                          icon: const Icon(
                            Icons.play_circle_filled_rounded,
                            size: 18,
                            color: AppTheme.primaryLight,
                          ),
                          label: const Text(
                            'Play All',
                            style: TextStyle(
                              color: AppTheme.primaryLight,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                const SizedBox(height: 8),

                // Trending Track List or Skeleton Loading State
                if (_isLoadingTrending)
                  _buildTrendingLoadingState()
                else if (_trendingError != null && _trendingTracks.isEmpty)
                  _buildSectionErrorState(_trendingError!, _loadTrendingTracks)
                else
                  ..._trendingTracks.map((video) {
                    final isCurrentTrack =
                        currentSong != null &&
                        currentSong.id == 'yt_${video.videoId}';
                    final isPlaying = isCurrentTrack && isPlayingGlobal;
                    final isItemLoading = _loadingVideoId == video.videoId;
                    final isLiked = _libraryService.isLiked(
                      'yt_${video.videoId}',
                    );

                    return YouTubeResultTile(
                      video: video,
                      isPlaying: isPlaying,
                      isLoading: isItemLoading,
                      isLiked: isLiked,
                      // A single Home selection starts discovery from this
                      // song; Play All still uses the whole section.
                      onTap: () => _playYouTubeAudio(video, [video]),
                      onPlay: () => _playYouTubeAudio(video, [video]),
                      onLike: () => _toggleLike(video),
                      onAddToPlaylist: () => PlaylistPickerSheet.show(
                        context,
                        video,
                        _libraryService,
                      ),
                    );
                  }),

                // Section 2: Latest / New Releases (date-sorted, ~5 newest).
                // Skipped entirely when nothing could be loaded, so the page
                // never shows a heading with no songs under it.
                if (_isLoadingNewReleases ||
                    _newReleases.isNotEmpty ||
                    _newReleasesError != null) ...[
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: AppTheme.accentVibrant.withValues(
                                    alpha: 0.18,
                                  ),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: AppTheme.accentVibrant.withValues(
                                      alpha: 0.4,
                                    ),
                                  ),
                                ),
                                child: const Text(
                                  'NEW',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color: AppTheme.accentVibrant,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text(
                                  'Latest Releases',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: AppTheme.textPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_newReleases.isNotEmpty)
                          TextButton.icon(
                            onPressed: _playAllNewReleases,
                            icon: const Icon(
                              Icons.play_circle_filled_rounded,
                              size: 16,
                              color: AppTheme.primaryLight,
                            ),
                            label: const Text(
                              'Play All',
                              style: TextStyle(
                                color: AppTheme.primaryLight,
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                            ),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              minimumSize: const Size(0, 40),
                            ),
                          ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 8),

                  // New Release List or Skeleton Loading State
                  if (_isLoadingNewReleases && _newReleases.isEmpty)
                    _buildTrendingLoadingState()
                  else if (_newReleasesError != null && _newReleases.isEmpty)
                    _buildSectionErrorState(
                      _newReleasesError!,
                      _loadNewReleases,
                    )
                  else
                    ..._newReleases.map((video) {
                      final isCurrentTrack =
                          currentSong != null &&
                          currentSong.id == 'yt_${video.videoId}';
                      final isPlaying = isCurrentTrack && isPlayingGlobal;
                      final isItemLoading = _loadingReleaseId == video.videoId;
                      final isLiked = _libraryService.isLiked(
                        'yt_${video.videoId}',
                      );

                      return YouTubeResultTile(
                        video: video,
                        isPlaying: isPlaying,
                        isLoading: isItemLoading,
                        isLiked: isLiked,
                        onTap: () => _playYouTubeAudio(video, [
                          video,
                        ], isNewRelease: true),
                        onPlay: () => _playYouTubeAudio(video, [
                          video,
                        ], isNewRelease: true),
                        onLike: () => _toggleLike(video),
                        onAddToPlaylist: () => PlaylistPickerSheet.show(
                          context,
                          video,
                          _libraryService,
                        ),
                      );
                    }),
                ],

                const SizedBox(height: 24),

                // Section 5: Your Playlists Carousel
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Your Playlists',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      Text(
                        '${playlists.length} playlists',
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 195,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: playlists.length,
                    itemBuilder: (context, index) {
                      final playlist = playlists[index];
                      return PlaylistCard(
                        playlist: playlist,
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  PlaylistScreen(playlist: playlist),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),

                const SizedBox(height: 20),

                // Section 6: Downloads & Offline (if any exist)
                if (downloads.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Downloads & Offline',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        Text(
                          '${downloads.length} available',
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppTheme.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...downloads.map(
                    (song) => SongTile(song: song, queueContext: downloads),
                  ),
                ],

                // Extra padding for MiniPlayer docked at bottom
                const SizedBox(height: 100),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildTrendingLoadingState() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        children: List.generate(
          5,
          (index) => Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.surfaceCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Row(
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceLight,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 14,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceLight,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        height: 10,
                        width: 120,
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceLight,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceLight,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeroHeader() {
    final now = DateTime.now();
    final hour = now.hour;
    return SizedBox(
      height: 190,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedBuilder(
            animation: _timeOfDayAnimation,
            builder: (context, _) => CustomPaint(
              painter: _HomeHeroPainter(
                hour: hour,
                minute: now.minute,
                animationProgress: _timeOfDayAnimation.value,
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              MediaQuery.paddingOf(context).top + 8,
              16,
              14,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [AppTheme.primary, AppTheme.accentOrange],
                        ),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: const Icon(
                        Icons.graphic_eq_rounded,
                        color: Colors.white,
                        size: 25,
                      ),
                    ),
                    const SizedBox(width: 11),
                    const Text(
                      'Musi',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontWeight: FontWeight.w800,
                        fontSize: 28,
                        letterSpacing: -0.7,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Settings',
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SettingsScreen(),
                        ),
                      ),
                      icon: const Icon(
                        Icons.settings_outlined,
                        color: AppTheme.primaryLight,
                        size: 28,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _greeting,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFFFE7CF),
                          fontSize: 21,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ScaleTransition(
                      scale: Tween<double>(begin: 0.96, end: 1.04).animate(
                        CurvedAnimation(
                          parent: _timeOfDayAnimation,
                          curve: Curves.easeInOut,
                        ),
                      ),
                      child: Icon(
                        _greetingIcon,
                        color: hour >= 5 && hour < 17
                            ? AppTheme.primaryLight
                            : const Color(0xFFFFD68A),
                        size: 25,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Find your next favorite song.',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHomeSearchButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onSearchTap,
          borderRadius: BorderRadius.circular(28),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            decoration: BoxDecoration(
              color: AppTheme.surfaceCard,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: AppTheme.primary.withValues(alpha: 0.8),
                width: 1,
              ),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.search_rounded,
                  color: AppTheme.primaryLight,
                  size: 23,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Search songs, artists, albums...',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLikedSongsCard(
    List<Song> likedSongs,
    List<YouTubeMusicResult> likedYouTube,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: AppTheme.surfaceCard,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: () => widget.onNavigateToLibrary(1),
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF2C1A00), Color(0xFF1A1000)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: AppTheme.primary.withValues(alpha: 0.35),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [AppTheme.accentOrange, AppTheme.primary],
                    ),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: const Icon(
                    Icons.favorite_rounded,
                    color: Colors.white,
                    size: 25,
                  ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Liked Songs',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${likedSongs.length + likedYouTube.length} songs in collection',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.72),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton.filled(
                  tooltip: 'Play Liked Songs',
                  style: IconButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    padding: EdgeInsets.zero,
                  ),
                  icon: const Icon(
                    Icons.play_arrow_rounded,
                    color: Color(0xFF0E0B07),
                    size: 26,
                  ),
                  onPressed: likedSongs.isNotEmpty
                      ? () => _playerService.setQueue(likedSongs)
                      : likedYouTube.isNotEmpty
                      ? () => _playerService.playYouTubeAudio(
                          likedYouTube.first,
                          contextQueue: List.from(likedYouTube),
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNowPlayingCard(Song song, bool isPlaying) {
    final video = _playerService.currentYouTubeVideo;
    final title = song.title.isNotEmpty ? song.title : video?.title ?? '';
    final artist = song.artist.isNotEmpty
        ? song.artist
        : video?.channelTitle ?? '';
    final artwork = song.artworkUrl?.isNotEmpty == true
        ? song.artworkUrl
        : video?.thumbnailUrl;
    final isLiked = _libraryService.isLiked(song.id);
    final totalMs = _playerService.totalDuration.inMilliseconds;
    final progress = totalMs > 0
        ? (_playerService.currentPosition.inMilliseconds / totalMs).clamp(
            0.0,
            1.0,
          )
        : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: _openPlayer,
          child: Ink(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [
                  Color(0xFF30200E),
                  Color(0xFF18120A),
                  Color(0xFF21160A),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: AppTheme.primary.withValues(alpha: 0.65),
              ),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primary.withValues(alpha: 0.14),
                  blurRadius: 18,
                ),
              ],
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    if (artwork != null && artwork.isNotEmpty)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.network(
                          artwork,
                          width: 62,
                          height: 62,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _artworkPlaceholder(62),
                        ),
                      )
                    else
                      _artworkPlaceholder(62),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.graphic_eq_rounded,
                                color: AppTheme.primaryLight,
                                size: 17,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                'NOW PLAYING',
                                style: TextStyle(
                                  color: AppTheme.primaryLight.withValues(
                                    alpha: 0.95,
                                  ),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.1,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: 'Previous song',
                      onPressed: _playerService.previous,
                      icon: const Icon(
                        Icons.skip_previous_rounded,
                        color: Colors.white,
                        size: 26,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      tooltip: isPlaying ? 'Pause' : 'Play',
                      onPressed: _playerService.togglePlayPause,
                      icon: Icon(
                        isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: const Color(0xFF211307),
                        size: 28,
                      ),
                      style: IconButton.styleFrom(
                        backgroundColor: AppTheme.primaryLight,
                        minimumSize: const Size(48, 48),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Next song',
                      onPressed: _playerService.next,
                      icon: const Icon(
                        Icons.skip_next_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 5,
                          ),
                        ),
                        child: Slider(
                          value: progress,
                          onChanged: totalMs > 0 ? (_) {} : null,
                          onChangeEnd: totalMs > 0
                              ? (value) => _playerService.seek(
                                  Duration(
                                    milliseconds: (totalMs * value).round(),
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                    Text(
                      '${_formatTime(_playerService.currentPosition)} / ${_formatTime(_playerService.totalDuration)}',
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: isLiked ? 'Unlike song' : 'Like song',
                        onPressed: _playerService.toggleCurrentLike,
                        icon: Icon(
                          isLiked
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: isLiked
                              ? AppTheme.accent
                              : AppTheme.textSecondary,
                          size: 20,
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                      IconButton(
                        tooltip: 'Add to playlist',
                        onPressed: () => PlaylistPickerSheet.showSong(
                          context,
                          song,
                          _libraryService,
                        ),
                        icon: const Icon(Icons.playlist_add_rounded, size: 20),
                        color: AppTheme.primaryLight,
                        visualDensity: VisualDensity.compact,
                      ),
                      TextButton.icon(
                        onPressed: () =>
                            showPlayerQueueSheet(context, _playerService),
                        icon: const Icon(
                          Icons.queue_play_next_rounded,
                          size: 18,
                        ),
                        label: const Text('Queue'),
                        style: TextButton.styleFrom(
                          foregroundColor: AppTheme.primaryLight,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContinueListening(List<Song> songs) {
    return Column(
      children: [
        _sectionHeading(
          icon: Icons.history_rounded,
          title: 'Continue Listening',
          action: 'Queue',
          onAction: () => showPlayerQueueSheet(context, _playerService),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 112,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: songs.take(6).length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final song = songs[index];
              return SizedBox(
                width: 220,
                child: Material(
                  color: AppTheme.surfaceCard,
                  borderRadius: BorderRadius.circular(17),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(17),
                    onTap: () {
                      if (_playerService.currentSong?.id == song.id) {
                        _playerService.togglePlayPause();
                      } else {
                        _playUpNextSong(song);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(17),
                        border: Border.all(color: AppTheme.borderColor),
                      ),
                      child: Row(
                        children: [
                          Stack(
                            alignment: Alignment.bottomRight,
                            children: [
                              _songArtwork(song, 78),
                              Container(
                                margin: const EdgeInsets.all(4),
                                padding: const EdgeInsets.all(4),
                                decoration: const BoxDecoration(
                                  color: AppTheme.primary,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.play_arrow_rounded,
                                  color: Colors.black,
                                  size: 15,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  song.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  song.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: AppTheme.textSecondary,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildRecentlyPlayed(List<Song> songs) {
    return Column(
      children: [
        _sectionHeading(
          icon: Icons.headphones_rounded,
          title: 'Recently Played',
          action: 'See all',
          onAction: () => widget.onNavigateToLibrary(2),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 128,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: songs.take(10).length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final song = songs[index];
              return SizedBox(
                width: 92,
                child: InkWell(
                  onTap: () => _playRecentSong(song, songs),
                  borderRadius: BorderRadius.circular(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _songArtwork(song, 88),
                      const SizedBox(height: 5),
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _sectionHeading({
    required IconData icon,
    required String title,
    required String action,
    required VoidCallback onAction,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.primaryLight, size: 23),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.textPrimary,
              visualDensity: VisualDensity.compact,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(action, style: const TextStyle(fontSize: 12)),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppTheme.primaryLight,
                  size: 20,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _songArtwork(Song song, double size) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: song.artworkUrl?.isNotEmpty == true
          ? Image.network(
              song.artworkUrl!,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _artworkPlaceholder(size),
            )
          : _artworkPlaceholder(size),
    );
  }

  Widget _artworkPlaceholder(double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0xFF3A2A12), Color(0xFF181209)],
      ),
      borderRadius: BorderRadius.circular(12),
    ),
    alignment: Alignment.center,
    child: const Icon(Icons.music_note_rounded, color: AppTheme.primaryLight),
  );

  String _formatTime(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Widget _buildSectionErrorState(
    String message,
    Future<void> Function() retry,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Center(
        child: Column(
          children: [
            const Icon(
              Icons.wifi_off_rounded,
              size: 40,
              color: AppTheme.textMuted,
            ),
            const SizedBox(height: 10),
            Text(
              message,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: retry,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Retry'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primaryLight,
                side: const BorderSide(color: AppTheme.primary),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeHeroPainter extends CustomPainter {
  const _HomeHeroPainter({
    required this.hour,
    required this.minute,
    required this.animationProgress,
  });

  final int hour;
  final int minute;
  final double animationProgress;

  bool get isNight => hour == 0 || hour >= 21 || hour < 5;
  bool get isMidnight => hour == 0;
  bool get isMorning => hour >= 5 && hour < 12;
  bool get isNoon => hour == 12;
  bool get isAfternoon => hour >= 13 && hour < 17;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final skyColors = isMidnight
        ? const [Color(0xFF0D1022), Color(0xFF171329), Color(0xFF100D13)]
        : isNight
        ? const [Color(0xFF10172B), Color(0xFF242044), Color(0xFF100D13)]
        : isMorning
        ? const [Color(0xFF603B32), Color(0xFF633A2C), Color(0xFF100D0A)]
        : isNoon
        ? const [Color(0xFF53606A), Color(0xFF675746), Color(0xFF100D0A)]
        : isAfternoon
        ? const [Color(0xFF70432E), Color(0xFF60331F), Color(0xFF100D0A)]
        : const [Color(0xFF23160F), Color(0xFF3D1F12), Color(0xFF100D0A)];
    final sky = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: skyColors,
      ).createShader(rect);
    canvas.drawRect(rect, sky);

    final minuteOfDay = hour * 60 + minute;
    final daylightProgress = ((minuteOfDay - 5 * 60) / (16 * 60)).clamp(
      0.0,
      1.0,
    );
    final solarHeight = isNight
        ? 0.41
        : 0.63 - 0.27 * (1 - (daylightProgress * 2 - 1).abs());
    final sunCenter = Offset(
      size.width * 0.77,
      size.height * (solarHeight + (animationProgress - 0.5) * 0.012),
    );
    final orbColor = isNight
        ? const Color(0xFFB9C8FF)
        : isMorning
        ? const Color(0xFFFFC783)
        : isNoon
        ? const Color(0xFFFFE59B)
        : isAfternoon
        ? const Color(0xFFFFBA58)
        : const Color(0xFFFFA13A);
    final sun = Paint()
      ..shader = RadialGradient(
        colors: [
          orbColor.withValues(alpha: 0.95),
          orbColor.withValues(alpha: 0.45),
          orbColor.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromCircle(center: sunCenter, radius: 70));
    canvas.drawCircle(sunCenter, 68 + animationProgress * 3, sun);
    canvas.drawCircle(
      sunCenter,
      isNoon ? 30 : 27,
      Paint()..color = orbColor.withValues(alpha: isNight ? 0.68 : 0.82),
    );
    if (!isNight) {
      final rayPaint = Paint()
        ..color = orbColor.withValues(alpha: 0.28)
        ..strokeWidth = 1.3
        ..strokeCap = StrokeCap.round;
      for (var ray = 0; ray < 8; ray++) {
        final angle = ray * math.pi / 4 + animationProgress * 0.04;
        canvas.drawLine(
          sunCenter + Offset(math.cos(angle) * 35, math.sin(angle) * 35),
          sunCenter + Offset(math.cos(angle) * 43, math.sin(angle) * 43),
          rayPaint,
        );
      }
    }
    if (isNight) {
      // Small cutout turns the glowing orb into a crescent moon.
      canvas.drawCircle(
        Offset(sunCenter.dx + 11, sunCenter.dy - 9),
        24,
        Paint()..color = skyColors.first,
      );
      final starPaint = Paint()..color = const Color(0xFFFFE9B5);
      for (final point in const [
        Offset(0.18, 0.32),
        Offset(0.39, 0.23),
        Offset(0.58, 0.42),
        Offset(0.9, 0.28),
        Offset(0.29, 0.52),
      ]) {
        canvas.drawCircle(
          Offset(size.width * point.dx, size.height * point.dy),
          isMidnight ? 1.7 : 1.2,
          starPaint,
        );
      }
    }

    final farMountain = Path()
      ..moveTo(0, size.height * 0.69)
      ..lineTo(size.width * 0.25, size.height * 0.43)
      ..lineTo(size.width * 0.42, size.height * 0.66)
      ..lineTo(size.width * 0.63, size.height * 0.37)
      ..lineTo(size.width * 0.81, size.height * 0.68)
      ..lineTo(size.width, size.height * 0.49)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(farMountain, Paint()..color = const Color(0xFF21171A));

    final nearMountain = Path()
      ..moveTo(0, size.height * 0.81)
      ..lineTo(size.width * 0.2, size.height * 0.67)
      ..lineTo(size.width * 0.38, size.height * 0.78)
      ..lineTo(size.width * 0.58, size.height * 0.61)
      ..lineTo(size.width * 0.73, size.height * 0.78)
      ..lineTo(size.width * 0.89, size.height * 0.66)
      ..lineTo(size.width, size.height * 0.78)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(nearMountain, Paint()..color = const Color(0xFF120F0D));

    final fade = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.center,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, AppTheme.background],
      ).createShader(rect);
    canvas.drawRect(rect, fade);
  }

  @override
  bool shouldRepaint(covariant _HomeHeroPainter oldDelegate) =>
      hour != oldDelegate.hour ||
      minute != oldDelegate.minute ||
      animationProgress != oldDelegate.animationProgress;
}

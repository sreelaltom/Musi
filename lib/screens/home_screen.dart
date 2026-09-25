import 'package:flutter/material.dart';

import '../models/song.dart';
import '../models/youtube_music_result.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../services/youtube_audio_service.dart';
import '../services/youtube_music_api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/playlist_tile.dart';
import '../widgets/search_bar_widget.dart';
import '../widgets/song_tile.dart';
import '../widgets/youtube_result_tile.dart';
import 'playlist_picker_sheet.dart';
import 'playlist_screen.dart';
import 'settings_screen.dart';

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

class _HomeScreenState extends State<HomeScreen> {
  final YouTubeMusicApiService _ytService = YouTubeMusicApiService();
  final LibraryService _libraryService = LibraryService();
  final PlayerService _playerService = PlayerService();

  List<YouTubeMusicResult> _trendingTracks = [];
  bool _isLoadingTrending = true;
  String? _trendingError;
  String? _loadingVideoId;

  @override
  void initState() {
    super.initState();
    _loadTrendingTracks();
  }

  Future<void> _loadTrendingTracks() async {
    setState(() {
      _isLoadingTrending = true;
      _trendingError = null;
    });

    try {
      final results = await _ytService.getTrendingHits(limit: 10);
      // Pre-filter to ensure only playable tracks are displayed
      final playableResults =
          await YouTubeAudioService().filterPlayable(results);
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

  Future<void> _playYouTubeAudio(YouTubeMusicResult video) async {
    final currentSong = _playerService.currentSong;
    final isCurrent =
        currentSong != null && currentSong.id == 'yt_${video.videoId}';

    if (isCurrent) {
      await _playerService.togglePlayPause();
      return;
    }

    setState(() => _loadingVideoId = video.videoId);

    await _playerService.playYouTubeAudio(
      video,
      contextQueue: _trendingTracks,
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

    if (mounted) {
      setState(() => _loadingVideoId = null);
    }
  }

  void _playAllTrending() {
    if (_trendingTracks.isNotEmpty) {
      _playYouTubeAudio(_trendingTracks.first);
    }
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
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppTheme.primary, AppTheme.accentVibrant],
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.graphic_eq_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'Musi',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 24,
                letterSpacing: -0.5,
                color: Colors.white,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.settings_outlined,
              color: AppTheme.textSecondary,
            ),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
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

          return RefreshIndicator(
            color: AppTheme.primary,
            backgroundColor: AppTheme.surfaceCard,
            onRefresh: _loadTrendingTracks,
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                // Quick Search Bar Shortcut
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: MusiSearchBar(
                    readOnly: true,
                    onTap: widget.onSearchTap,
                  ),
                ),

                const SizedBox(height: 12),

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
                  _buildTrendingErrorState()
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
                      onTap: () => _playYouTubeAudio(video),
                      onPlay: () => _playYouTubeAudio(video),
                      onLike: () => _toggleLike(video),
                       onAddToPlaylist: () => PlaylistPickerSheet.show(
                         context,
                         video,
                         _libraryService,
                       ),
                     );
                  }),

                const SizedBox(height: 24),

                // Section 2: Liked Songs Spotlight Banner
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                   child: InkWell(
                      onTap: () => widget.onNavigateToLibrary(1),
                     borderRadius: BorderRadius.circular(16),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF2C1A00), Color(0xFF1A1000)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: AppTheme.primary.withValues(alpha: 0.35),
                          width: 0.8,
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [AppTheme.accentOrange, AppTheme.primary],
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(
                              Icons.favorite_rounded,
                              color: Colors.white,
                              size: 26,
                            ),
                          ),
                          const SizedBox(width: 16),
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
                                    fontSize: 12.5,
                                    color: Colors.white.withValues(alpha: 0.7),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton.filled(
                            style: IconButton.styleFrom(
                              backgroundColor: AppTheme.primary,
                              padding: EdgeInsets.zero,
                            ),
                            icon: const Icon(
                              Icons.play_arrow_rounded,
                              color: Color(0xFF0E0B07),
                              size: 26,
                            ),
                            onPressed: () {
                              if (likedSongs.isNotEmpty) {
                                _playerService.setQueue(likedSongs);
                              } else if (likedYouTube.isNotEmpty) {
                                _playerService.playYouTubeAudio(
                                  likedYouTube.first,
                                  contextQueue: List.from(likedYouTube),
                                );
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                // Section 3: Recently Played (Only shown if user has genuine history)
                if (recentSongs.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Recently Played',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        TextButton(
                          onPressed: () => _playerService.setQueue(recentSongs),
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
                  ),
                  ...recentSongs
                      .take(4)
                      .map(
                        (song) =>
                            SongTile(song: song, queueContext: recentSongs),
                      ),
                  const SizedBox(height: 20),
                ],

                // Section 4: Your Playlists Carousel
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

                // Section 5: Downloads & Offline (if any exist)
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

  Widget _buildTrendingErrorState() {
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
              _trendingError ?? 'Unable to connect to music service',
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _loadTrendingTracks,
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

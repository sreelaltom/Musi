import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../models/song.dart';
import '../models/youtube_music_result.dart';
import '../services/library_service.dart';
import '../services/player_service.dart';
import '../theme/app_theme.dart';
import '../widgets/song_tile.dart';
import '../widgets/youtube_result_tile.dart';
import 'playlist_screen.dart';

class LibraryScreen extends StatefulWidget {
  final int initialTabIndex;
  final ValueNotifier<int>? tabIndexNotifier;

  const LibraryScreen({
    super.key,
    this.initialTabIndex = 0,
    this.tabIndexNotifier,
  });

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  VoidCallback? _tabIndexListener;
  int _lastRequestedCategory = 0;

  @override
  void initState() {
    super.initState();
    _lastRequestedCategory = widget.initialTabIndex.clamp(0, 4);
    if (_lastRequestedCategory != 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openCategory(_lastRequestedCategory);
      });
    }
    _tabIndexListener = () {
      final requestedIndex = widget.tabIndexNotifier?.value;
      if (requestedIndex != null &&
          requestedIndex > 0 &&
          requestedIndex < _libraryCategories.length &&
          requestedIndex != _lastRequestedCategory) {
        _lastRequestedCategory = requestedIndex;
        _openCategory(requestedIndex);
      } else if (requestedIndex == 0) {
        _lastRequestedCategory = 0;
      }
    };
    widget.tabIndexNotifier?.addListener(_tabIndexListener!);
  }

  @override
  void dispose() {
    if (_tabIndexListener != null) {
      widget.tabIndexNotifier?.removeListener(_tabIndexListener!);
    }
    super.dispose();
  }

  void _openCategory(int index) {
    final libraryService = LibraryService();
    final playerService = PlayerService();
    final category = _libraryCategories[index];
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _LibraryCategoryScreen(
          title: category.title,
          contentBuilder: (context) => _buildCategoryContent(
            context,
            index,
            libraryService,
            playerService,
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryContent(
    BuildContext context,
    int index,
    LibraryService libraryService,
    PlayerService playerService,
  ) {
    switch (index) {
      case 0:
        return _buildPlaylistsTab(context, libraryService.playlists);
      case 1:
        return _buildLikedTab(
          libraryService.likedSongs,
          libraryService.likedYouTubeVideos,
          playerService,
        );
      case 2:
        return _buildRecentlyPlayedTab(
          libraryService.recentlyPlayed,
          libraryService.recentlyPlayedYouTube,
          playerService,
        );
      case 3:
        return _buildYouTubeLikedTab(
          libraryService.likedYouTubeVideos,
          playerService,
        );
      default:
        return _buildDownloadsTab(
          libraryService.downloadedSongs,
          playerService,
        );
    }
  }

  void _showCreatePlaylistDialog(BuildContext context) {
    final textController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceCard,
        title: const Text(
          'New Playlist',
          style: TextStyle(color: AppTheme.textPrimary),
        ),
        content: TextField(
          controller: textController,
          autofocus: true,
          style: const TextStyle(color: AppTheme.textPrimary),
          cursorColor: AppTheme.accent,
          decoration: const InputDecoration(
            hintText: 'Give your playlist a name',
            hintStyle: TextStyle(color: AppTheme.textMuted),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppTheme.accent),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppTheme.textMuted),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
            onPressed: () {
              if (textController.text.trim().isNotEmpty) {
                LibraryService().createPlaylist(textController.text.trim());
                Navigator.pop(ctx);
              }
            },
            child: const Text('Create', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final libraryService = LibraryService();

    return ListenableBuilder(
      listenable: libraryService,
      builder: (context, _) {
        final likedSongs = libraryService.likedSongs;
        final likedYouTube = libraryService.likedYouTubeVideos;
        final recentlyPlayed = libraryService.recentlyPlayed;
        final recentlyPlayedYouTube = libraryService.recentlyPlayedYouTube;
        final downloadedSongs = libraryService.downloadedSongs;
        final playlists = libraryService.playlists;

        final counts = <int>[
          playlists.length,
          likedSongs.length + likedYouTube.length,
          recentlyPlayed.length + recentlyPlayedYouTube.length,
          likedYouTube.length,
          downloadedSongs.length,
        ];

        return Scaffold(
          appBar: AppBar(
            title: const Text(
              'Your Library',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.add_rounded, size: 28),
                tooltip: 'Create Playlist',
                onPressed: () => _showCreatePlaylistDialog(context),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 120),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 2, 4, 16),
                child: Text(
                  'Your music, all in one place',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                ),
              ),
              for (var index = 0; index < _libraryCategories.length; index++)
                _buildCategoryCard(
                  context,
                  _libraryCategories[index],
                  counts[index],
                  index,
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCategoryCard(
    BuildContext context,
    _LibraryCategory category,
    int count,
    int index,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppTheme.surfaceCard,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openCategory(index),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: category.tint.withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Icon(category.icon, color: category.tint, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        category.title,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        category.subtitle,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$count',
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppTheme.textMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaylistsTab(BuildContext context, List<Playlist> playlists) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 120),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF35230A), AppTheme.surfaceCard],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: const Icon(
                      Icons.queue_music_rounded,
                      color: AppTheme.accent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Your playlists',
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${playlists.length} ${playlists.length == 1 ? 'playlist' : 'playlists'}',
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _showCreatePlaylistDialog(context),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Create playlist'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 22, 4, 10),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'All playlists',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
              Text(
                playlists.length.toString(),
                style: const TextStyle(color: AppTheme.textMuted),
              ),
            ],
          ),
        ),
        if (playlists.isEmpty)
          _buildLibraryEmptyState(
            icon: Icons.queue_music_rounded,
            title: 'No playlists yet',
            message: 'Create a playlist to keep your favorite music together.',
          ),
        ...playlists.map(
          (playlist) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: AppTheme.surfaceCard,
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PlaylistScreen(playlist: playlist),
                    ),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(15),
                        child: Container(
                          width: 64,
                          height: 64,
                          color: AppTheme.surfaceLight,
                          child: playlist.coverUrl != null
                              ? Image.network(
                                  playlist.coverUrl!,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => const Icon(
                                    Icons.queue_music_rounded,
                                    color: AppTheme.primaryLight,
                                  ),
                                )
                              : const Icon(
                                  Icons.queue_music_rounded,
                                  color: AppTheme.primaryLight,
                                  size: 28,
                                ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              playlist.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              '${playlist.songCount} ${playlist.songCount == 1 ? 'song' : 'songs'}',
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: AppTheme.textMuted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLibraryEmptyState({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      child: Column(
        children: [
          Icon(icon, size: 42, color: AppTheme.textMuted),
          const SizedBox(height: 10),
          Text(
            title,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildLikedTab(
    List<Song> likedSongs,
    List<YouTubeMusicResult> likedYouTube,
    PlayerService playerService,
  ) {
    if (likedSongs.isEmpty && likedYouTube.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.favorite_outline_rounded,
              size: 56,
              color: AppTheme.textMuted,
            ),
            SizedBox(height: 12),
            Text(
              'No liked items yet',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppTheme.textSecondary,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'Tap the heart icon on any song or YouTube video to save it here',
              style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 90),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${likedSongs.length} songs • ${likedYouTube.length} YouTube',
                style: const TextStyle(color: AppTheme.textMuted),
              ),
              if (likedSongs.isNotEmpty) ...[
                TextButton.icon(
                  onPressed: () =>
                      playerService.shuffleAndPlay(List<Song>.from(likedSongs)),
                  icon: const Icon(
                    Icons.shuffle_rounded,
                    color: AppTheme.accent,
                  ),
                  label: const Text(
                    'Shuffle',
                    style: TextStyle(color: AppTheme.accent),
                  ),
                ),
                TextButton.icon(
                  onPressed: () =>
                      playerService.setQueue(List.from(likedSongs)),
                  icon: const Icon(
                    Icons.play_arrow_rounded,
                    color: AppTheme.accent,
                  ),
                  label: const Text(
                    'Play Songs',
                    style: TextStyle(color: AppTheme.accent),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (likedSongs.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'Musi Songs',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppTheme.primaryLight,
              ),
            ),
          ),
          ...likedSongs.map(
            (song) => SongTile(song: song, queueContext: List.from(likedSongs)),
          ),
        ],
        if (likedYouTube.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'YouTube Videos',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.error,
                  ),
                ),
                TextButton.icon(
                  onPressed: () => playerService.playYouTubeAudio(
                    likedYouTube.first,
                    contextQueue: List.from(likedYouTube),
                  ),
                  icon: const Icon(
                    Icons.play_arrow_rounded,
                    color: AppTheme.accent,
                  ),
                  label: const Text(
                    'Play All',
                    style: TextStyle(color: AppTheme.accent),
                  ),
                ),
              ],
            ),
          ),
          ...likedYouTube.map(
            (video) => YouTubeResultTile(
              video: video,
              isLiked: true,
              // Play as background audio (same as home screen trending)
              onTap: () => playerService.playYouTubeAudio(
                video,
                contextQueue: List.from(likedYouTube),
              ),
              onLike: () => LibraryService().toggleYouTubeLike(video),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildRecentlyPlayedTab(
    List<Song> recentlyPlayed,
    List<YouTubeMusicResult> recentlyPlayedYouTube,
    PlayerService playerService,
  ) {
    if (recentlyPlayed.isEmpty && recentlyPlayedYouTube.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history_rounded, size: 56, color: AppTheme.textMuted),
            SizedBox(height: 12),
            Text(
              'No recently played items',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppTheme.textSecondary,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'Songs and videos you play will appear here',
              style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 90),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            '${recentlyPlayed.length} songs • ${recentlyPlayedYouTube.length} YouTube',
            style: const TextStyle(color: AppTheme.textMuted),
          ),
        ),
        if (recentlyPlayed.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'Musi Songs',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppTheme.primaryLight,
              ),
            ),
          ),
          ...recentlyPlayed.map(
            (song) =>
                SongTile(song: song, queueContext: List.from(recentlyPlayed)),
          ),
        ],
        if (recentlyPlayedYouTube.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'YouTube Videos',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppTheme.error,
              ),
            ),
          ),
          ...recentlyPlayedYouTube.map(
            (video) => YouTubeResultTile(
              video: video,
              isLiked: LibraryService().isLiked('yt_${video.videoId}'),
              onTap: () => playerService.playYouTubeAudio(
                video,
                contextQueue: List.from(recentlyPlayedYouTube),
              ),
              onLike: () => LibraryService().toggleYouTubeLike(video),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildYouTubeLikedTab(
    List<YouTubeMusicResult> likedYouTube,
    PlayerService playerService,
  ) {
    if (likedYouTube.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.ondemand_video_rounded,
              size: 56,
              color: AppTheme.textMuted,
            ),
            SizedBox(height: 12),
            Text(
              'No liked YouTube videos',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppTheme.textSecondary,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'Tap the heart icon on YouTube search results to save them here',
              style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 90),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            '${likedYouTube.length} videos',
            style: const TextStyle(color: AppTheme.textMuted),
          ),
        ),
        ...likedYouTube.map(
          (video) => YouTubeResultTile(
            video: video,
            onTap: () => playerService.playYouTubeAudio(
              video,
              contextQueue: List.from(likedYouTube),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDownloadsTab(
    List<Song> downloadedSongs,
    PlayerService playerService,
  ) {
    if (downloadedSongs.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.download_for_offline_outlined,
              size: 56,
              color: AppTheme.textMuted,
            ),
            SizedBox(height: 12),
            Text(
              'No downloaded songs',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppTheme.textSecondary,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'Downloaded songs will be stored locally for offline play',
              style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 90),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${downloadedSongs.length} offline tracks',
                style: const TextStyle(color: AppTheme.textMuted),
              ),
              Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: () => playerService.setQueue(
                      List.from(downloadedSongs),
                    ),
                    icon: const Icon(
                      Icons.play_arrow_rounded,
                      color: AppTheme.accent,
                    ),
                    label: const Text(
                      'Play All',
                      style: TextStyle(color: AppTheme.accent),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => playerService.smartShuffleAndPlay(
                      List.from(downloadedSongs),
                    ),
                    icon: const Icon(
                      Icons.shuffle_rounded,
                      color: AppTheme.accent,
                    ),
                    label: const Text(
                      'Smart Shuffle',
                      style: TextStyle(color: AppTheme.accent),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        ...downloadedSongs.map(
          (song) =>
              SongTile(song: song, queueContext: List.from(downloadedSongs)),
        ),
      ],
    );
  }
}

class _LibraryCategory {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color tint;

  const _LibraryCategory({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.tint,
  });
}

const _libraryCategories = <_LibraryCategory>[
  _LibraryCategory(
    title: 'My Playlists',
    subtitle: 'Your personal collections',
    icon: Icons.queue_music_rounded,
    tint: AppTheme.accent,
  ),
  _LibraryCategory(
    title: 'Liked Songs',
    subtitle: 'Music and videos you saved',
    icon: Icons.favorite_rounded,
    tint: AppTheme.error,
  ),
  _LibraryCategory(
    title: 'Recently Played',
    subtitle: 'Pick up where you left off',
    icon: Icons.history_rounded,
    tint: AppTheme.primaryLight,
  ),
  _LibraryCategory(
    title: 'Saved YouTube',
    subtitle: 'YouTube videos you liked',
    icon: Icons.ondemand_video_rounded,
    tint: AppTheme.error,
  ),
  _LibraryCategory(
    title: 'Downloads',
    subtitle: 'Listen offline',
    icon: Icons.download_for_offline_rounded,
    tint: AppTheme.accent,
  ),
];

class _LibraryCategoryScreen extends StatelessWidget {
  final String title;
  final Widget Function(BuildContext context) contentBuilder;

  const _LibraryCategoryScreen({
    required this.title,
    required this.contentBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final libraryService = LibraryService();
    final playerService = PlayerService();

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListenableBuilder(
        listenable: Listenable.merge([libraryService, playerService]),
        builder: (context, _) => contentBuilder(context),
      ),
    );
  }
}

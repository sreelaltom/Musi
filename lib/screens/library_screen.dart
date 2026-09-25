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

class _LibraryScreenState extends State<LibraryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this, initialIndex: widget.initialTabIndex);
    widget.tabIndexNotifier?.addListener(() {
      _tabController.index = widget.tabIndexNotifier!.value;
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
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
    final playerService = PlayerService();

    return ListenableBuilder(
      listenable: libraryService,
      builder: (context, _) {
        final likedSongs = libraryService.likedSongs;
        final likedYouTube = libraryService.likedYouTubeVideos;
        final recentlyPlayed = libraryService.recentlyPlayed;
        final recentlyPlayedYouTube = libraryService.recentlyPlayedYouTube;
        final downloadedSongs = libraryService.downloadedSongs;
        final playlists = libraryService.playlists;

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
            bottom: TabBar(
              controller: _tabController,
              indicatorColor: AppTheme.accent,
              indicatorWeight: 3,
              labelColor: AppTheme.accent,
              unselectedLabelColor: AppTheme.textSecondary,
              labelStyle: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
              isScrollable: true,
              tabs: [
                Tab(text: 'Playlists (${playlists.length})'),
                Tab(text: 'Liked (${likedSongs.length + likedYouTube.length})'),
                Tab(
                  text:
                      'Recent (${recentlyPlayed.length + recentlyPlayedYouTube.length})',
                ),
                Tab(text: 'YouTube (${likedYouTube.length})'),
                Tab(text: 'Downloads (${downloadedSongs.length})'),
              ],
            ),
          ),
          body: TabBarView(
            controller: _tabController,
            children: [
              // Tab 1: Playlists
              _buildPlaylistsTab(context, playlists),

              // Tab 2: Liked (Songs + YouTube)
              _buildLikedTab(likedSongs, likedYouTube, playerService),

              // Tab 3: Recently Played (Songs + YouTube)
              _buildRecentlyPlayedTab(
                recentlyPlayed,
                recentlyPlayedYouTube,
                playerService,
              ),

              // Tab 4: YouTube Liked
              _buildYouTubeLikedTab(likedYouTube, playerService),

              // Tab 5: Downloads
              _buildDownloadsTab(downloadedSongs, playerService),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPlaylistsTab(BuildContext context, List<Playlist> playlists) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      children: [
        // Create Playlist Banner button
        InkWell(
          onTap: () => _showCreatePlaylistDialog(context),
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: AppTheme.surfaceCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF2A2E3D)),
            ),
            child: const Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: AppTheme.surfaceLight,
                  child: Icon(Icons.add, color: AppTheme.accent),
                ),
                SizedBox(width: 14),
                Text(
                  'Create new playlist',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        ...playlists.map(
          (playlist) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: AppTheme.surfaceCard,
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    width: 48,
                    height: 48,
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
                          ),
                  ),
                ),
                title: Text(
                  playlist.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                subtitle: Text(
                  '${playlist.songCount} songs',
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 13,
                  ),
                ),
                trailing: const Icon(
                  Icons.chevron_right_rounded,
                  color: AppTheme.textMuted,
                ),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PlaylistScreen(playlist: playlist),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 90),
      ],
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
              if (likedSongs.isNotEmpty)
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
                  icon: const Icon(Icons.play_arrow_rounded, color: AppTheme.accent),
                  label: const Text('Play All', style: TextStyle(color: AppTheme.accent)),
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
              TextButton.icon(
                onPressed: () =>
                    playerService.setQueue(List.from(downloadedSongs)),
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
        ...downloadedSongs.map(
          (song) =>
              SongTile(song: song, queueContext: List.from(downloadedSongs)),
        ),
      ],
    );
  }
}

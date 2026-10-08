import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../models/song.dart';
import '../models/playlist_item.dart';
import '../models/youtube_music_result.dart';
import '../services/player_service.dart';
import '../services/library_service.dart';
import '../services/youtube_audio_service.dart';
import '../theme/app_theme.dart';
import '../widgets/song_tile.dart';
import '../widgets/youtube_result_tile.dart';

class PlaylistScreen extends StatelessWidget {
  final Playlist playlist;

  const PlaylistScreen({super.key, required this.playlist});

  @override
  Widget build(BuildContext context) {
    final libraryService = LibraryService();
    final playerService = PlayerService();

    return ListenableBuilder(
      listenable: libraryService,
      builder: (context, _) {
        // Find current playlist in library to get fresh state
        final currentPlaylist = libraryService.playlists.firstWhere(
          (p) => p.id == playlist.id,
          orElse: () => playlist,
        );

        return FutureBuilder<List<PlaylistItem>>(
          future: libraryService.getPlaylistItems(currentPlaylist.id),
          builder: (context, snapshot) {
            final playlistItems = snapshot.data ?? [];

            return Scaffold(
              body: CustomScrollView(
                slivers: [
                  SliverAppBar(
                    expandedHeight: 224,
                    pinned: true,
                    flexibleSpace: FlexibleSpaceBar(
                      title: Text(
                        currentPlaylist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          shadows: [
                            Shadow(color: Colors.black, blurRadius: 10),
                          ],
                        ),
                      ),
                      background: Stack(
                        fit: StackFit.expand,
                        children: [
                          Container(
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Color(0xFF3D2200),
                                  AppTheme.background,
                                ],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ),
                            ),
                            child: currentPlaylist.coverUrl != null
                                ? Image.network(
                                    currentPlaylist.coverUrl!,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) =>
                                        const SizedBox.shrink(),
                                  )
                                : null,
                          ),
                          Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Colors.transparent,
                                  AppTheme.background.withValues(alpha: 0.8),
                                  AppTheme.background,
                                ],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    actions: [
                      IconButton(
                        icon: const Icon(Icons.edit_rounded),
                        tooltip: 'Rename Playlist',
                        onPressed: () =>
                            _showRenameDialog(context, currentPlaylist),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_rounded),
                        tooltip: 'Add Songs',
                        onPressed: () =>
                            _showAddContentDialog(context, currentPlaylist),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline_rounded),
                        tooltip: 'Delete Playlist',
                        onPressed: () =>
                            _confirmDelete(context, currentPlaylist),
                      ),
                    ],
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${playlistItems.length} ${playlistItems.length == 1 ? 'song' : 'songs'}',
                                  style: const TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Text(
                                currentPlaylist.totalDurationFormatted,
                                style: const TextStyle(
                                  color: AppTheme.textSecondary,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Hold and drag to reorder · Swipe left to remove',
                            style: TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: AppTheme.primaryLight,
                                    side: BorderSide(
                                      color: playlistItems.isEmpty
                                          ? AppTheme.borderColor
                                          : AppTheme.primary.withValues(
                                              alpha: 0.6,
                                            ),
                                    ),
                                    minimumSize: const Size.fromHeight(48),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                  ),
                                  icon: const Icon(
                                    Icons.shuffle_rounded,
                                    size: 20,
                                  ),
                                  label: const Text(
                                    'Shuffle',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onPressed: playlistItems.isEmpty
                                      ? null
                                      : () => playerService
                                            .shuffleAndPlayPlaylist(
                                              List<PlaylistItem>.from(
                                                playlistItems,
                                              ),
                                            ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    minimumSize: const Size.fromHeight(48),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                  ),
                                  icon: const Icon(
                                    Icons.play_arrow_rounded,
                                    size: 22,
                                  ),
                                  label: const Text(
                                    'Play all',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onPressed: playlistItems.isEmpty
                                      ? null
                                      : () => playerService.setMixedQueue(
                                          List<PlaylistItem>.from(
                                            playlistItems,
                                          ),
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (playlistItems.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Text(
                          'No items in this playlist yet\nTap + to add songs or YouTube videos',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppTheme.textMuted),
                        ),
                      ),
                    )
                  else
                    SliverToBoxAdapter(
                      child: ReorderableListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: playlistItems.length,
                        onReorderItem: (oldIndex, newIndex) {
                          final items = List<PlaylistItem>.from(playlistItems);
                          final item = items.removeAt(oldIndex);
                          items.insert(newIndex.clamp(0, items.length), item);
                          // Update positions
                          for (int i = 0; i < items.length; i++) {
                            items[i] = items[i].copyWith(position: i);
                          }
                          libraryService.reorderPlaylistItems(
                            currentPlaylist.id,
                            items.map((i) => i.sourceId).toList(),
                            items.map((i) => i.sourceType).toList(),
                          );
                        },
                        itemBuilder: (context, index) {
                          final item = playlistItems[index];
                          return Padding(
                            key: ValueKey(
                              'reorder_${currentPlaylist.id}_'
                              '${item.sourceType.value}_${item.sourceId}',
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            child: Dismissible(
                              key: ValueKey(
                                '${currentPlaylist.id}_${item.sourceType.value}_${item.sourceId}',
                              ),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.only(right: 20),
                                decoration: BoxDecoration(
                                  color: AppTheme.error,
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: const Icon(
                                  Icons.delete_outline_rounded,
                                  color: Colors.white,
                                ),
                              ),
                              onDismissed: (_) {
                                if (item.isAuthorized) {
                                  libraryService.removeSongFromPlaylist(
                                    currentPlaylist.id,
                                    item.sourceId,
                                  );
                                } else {
                                  libraryService.removeYouTubeFromPlaylist(
                                    currentPlaylist.id,
                                    item.sourceId,
                                  );
                                }
                              },
                              child: Material(
                                color: AppTheme.surfaceCard,
                                borderRadius: BorderRadius.circular(18),
                                clipBehavior: Clip.antiAlias,
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: item.isAuthorized
                                          ? _buildAuthorizedSongTile(
                                              item,
                                              playlistItems,
                                            )
                                          : _buildYouTubeTile(
                                              context,
                                              item,
                                              playlistItems,
                                            ),
                                    ),
                                    ReorderableDragStartListener(
                                      index: index,
                                      child: const Padding(
                                        padding: EdgeInsets.only(right: 12),
                                        child: Icon(
                                          Icons.drag_handle_rounded,
                                          color: AppTheme.textMuted,
                                          size: 20,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 100)),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildAuthorizedSongTile(
    PlaylistItem item,
    List<PlaylistItem> queueContext,
  ) {
    // Find the full song if available
    final libraryService = LibraryService();
    final song =
        libraryService.likedSongs
            .where((s) => s.id == item.songId)
            .firstOrNull ??
        libraryService.recentlyPlayed
            .where((s) => s.id == item.songId)
            .firstOrNull ??
        libraryService.downloadedSongs
            .where((s) => s.id == item.songId)
            .firstOrNull ??
        Song(
          id: item.sourceId,
          title: item.title,
          artist: item.artistChannel ?? '',
          artworkUrl: item.artworkUrl,
          streamUrl: '',
          duration: 0,
        );

    return SongTile(
      song: song,
      queueContext: queueContext
          .where((i) => i.isAuthorized)
          .map(
            (i) => Song(
              id: i.sourceId,
              title: i.title,
              artist: i.artistChannel ?? '',
              artworkUrl: i.artworkUrl,
              streamUrl: '',
              duration: 0,
            ),
          )
          .toList(),
    );
  }

  Widget _buildYouTubeTile(
    BuildContext context,
    PlaylistItem item,
    List<PlaylistItem> queueContext,
  ) {
    final video = YouTubeMusicResult(
      videoId: item.youtubeVideoId ?? item.sourceId,
      title: item.title,
      channelTitle: item.artistChannel ?? '',
      thumbnailUrl: item.artworkUrl ?? '',
      youtubeUrl:
          'https://www.youtube.com/watch?v=${item.youtubeVideoId ?? item.sourceId}',
    );

    final libraryService = LibraryService();
    final playerService = PlayerService();
    final isLiked = libraryService.likedYouTubeVideos.any(
      (v) => v.videoId == video.videoId,
    );

    // PlaylistScreen's item FutureBuilder is driven by library changes, but
    // playback state changes independently. Listen here so the active track
    // and its Play/Pause control update immediately when playback starts,
    // pauses, resumes, or advances.
    return ListenableBuilder(
      listenable: playerService,
      builder: (context, _) {
        // A YouTube stream may leave the previously resolved Song in
        // currentSong while currentYouTubeVideo already points at the new
        // track. Treat the active YouTube video as authoritative in that
        // case, otherwise two playlist rows can appear active after Next.
        final activeYouTubeVideo = playerService.currentYouTubeVideo;
        final activeSong = playerService.currentSong;
        final activeSongVideoId = activeSong == null
            ? null
            : YouTubeAudioService.extractVideoId(activeSong);
        final isCurrentTrack = activeSongVideoId != null
            ? activeSongVideoId == video.videoId
            : activeYouTubeVideo != null
            ? activeYouTubeVideo.videoId == video.videoId
            : activeSong?.id == item.sourceId;
        final isPlaying = isCurrentTrack && playerService.isPlaying;

        void activateTrack() {
          if (isCurrentTrack) {
            if (playerService.isPlaying) {
              playerService.pause();
            } else {
              playerService.play();
            }
          } else {
            playerService.playYouTubeAudio(
              video,
              mixedContextQueue: queueContext,
            );
          }
        }

        return YouTubeResultTile(
          video: video,
          onTap: activateTrack,
          onPlay: activateTrack,
          onLike: () => libraryService.toggleYouTubeLike(video),
          isLiked: isLiked,
          isPlaying: isPlaying,
          isLoading: isCurrentTrack && playerService.isBuffering,
        );
      },
    );
  }

  void _showRenameDialog(BuildContext context, Playlist playlist) {
    final controller = TextEditingController(text: playlist.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceCard,
        title: const Text(
          'Rename Playlist',
          style: TextStyle(color: AppTheme.textPrimary),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: AppTheme.textPrimary),
          decoration: const InputDecoration(
            hintText: 'Playlist name',
            hintStyle: TextStyle(color: AppTheme.textMuted),
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
              if (controller.text.trim().isNotEmpty) {
                LibraryService().renamePlaylist(
                  playlist.id,
                  controller.text.trim(),
                );
                Navigator.pop(ctx);
              }
            },
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showAddContentDialog(BuildContext context, Playlist playlist) {
    final libraryService = LibraryService();
    final availableSongs = <Song>[
      ...libraryService.likedSongs,
      ...libraryService.recentlyPlayed,
      ...libraryService.downloadedSongs,
    ];

    // Deduplicate songs
    final uniqueSongs = <String, Song>{};
    for (final s in availableSongs) {
      uniqueSongs[s.id] = s;
    }
    final songsList = uniqueSongs.values
        .where((s) => !playlist.songs.any((ps) => ps.id == s.id))
        .toList();

    // Also include recently played YouTube videos
    final youTubeVideos = libraryService.recentlyPlayedYouTube
        .where((v) => !playlist.songs.any((ps) => ps.id == v.videoId))
        .toList();

    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Add to Playlist',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              if (songsList.isEmpty && youTubeVideos.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No items available in your library.',
                    style: TextStyle(color: AppTheme.textMuted),
                  ),
                )
              else
                Expanded(
                  child: ListView(
                    children: [
                      if (songsList.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Text(
                            'Musi Songs',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.primaryLight,
                            ),
                          ),
                        ),
                        ...songsList.map(
                          (s) => ListTile(
                            leading: const Icon(
                              Icons.music_note,
                              color: AppTheme.accent,
                            ),
                            title: Text(
                              s.title,
                              style: const TextStyle(
                                color: AppTheme.textPrimary,
                              ),
                            ),
                            subtitle: Text(
                              s.artist,
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                              ),
                            ),
                            trailing: const Icon(
                              Icons.add_circle_outline_rounded,
                              color: AppTheme.accent,
                            ),
                            onTap: () {
                              libraryService.addSongToPlaylist(playlist.id, s);
                              Navigator.pop(ctx);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Added ${s.title} to playlist'),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                      if (youTubeVideos.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Text(
                            'YouTube Videos',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.error,
                            ),
                          ),
                        ),
                        ...youTubeVideos.map(
                          (v) => ListTile(
                            leading: const Icon(
                              Icons.ondemand_video_rounded,
                              color: AppTheme.error,
                            ),
                            title: Text(
                              v.title,
                              style: const TextStyle(
                                color: AppTheme.textPrimary,
                              ),
                            ),
                            subtitle: Text(
                              v.channelTitle,
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                              ),
                            ),
                            trailing: const Icon(
                              Icons.add_circle_outline_rounded,
                              color: AppTheme.error,
                            ),
                            onTap: () {
                              libraryService.addYouTubeToPlaylist(
                                playlist.id,
                                v,
                              );
                              Navigator.pop(ctx);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Added ${v.title} to playlist'),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  void _confirmDelete(BuildContext context, Playlist playlist) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceCard,
        title: const Text(
          'Delete Playlist?',
          style: TextStyle(color: AppTheme.textPrimary),
        ),
        content: Text(
          'Are you sure you want to delete "${playlist.name}"?',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppTheme.textMuted),
            ),
          ),
          TextButton(
            onPressed: () {
              LibraryService().deletePlaylist(playlist.id);
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            child: const Text(
              'Delete',
              style: TextStyle(color: AppTheme.error),
            ),
          ),
        ],
      ),
    );
  }
}

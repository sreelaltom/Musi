import 'package:flutter/material.dart';

import '../services/player_service.dart';
import '../services/library_service.dart';
import '../theme/app_theme.dart';
import '../widgets/player_controls.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  double? _dragValue;

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final playerService = PlayerService();
    final libraryService = LibraryService();

    return ListenableBuilder(
      listenable: Listenable.merge([playerService, libraryService]),
      builder: (context, _) {
        final song = playerService.currentSong;
        if (song == null) {
          return Container(
            color: AppTheme.background,
            child: const Center(
              child: Text(
                'No song selected',
                style: TextStyle(color: AppTheme.textMuted),
              ),
            ),
          );
        }

        final isLiked = libraryService.isLiked(song.id);
        final isDownloaded = libraryService.isDownloaded(song.id);

        final totalDurationMs = playerService.totalDuration.inMilliseconds
            .toDouble();
        final currentPositionMs = playerService.currentPosition.inMilliseconds
            .toDouble();
        final effectivePositionMs = (_dragValue ?? currentPositionMs).clamp(
          0.0,
          totalDurationMs > 0 ? totalDurationMs : 1.0,
        );

        return Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF1E1200), AppTheme.background],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SafeArea(
            top: true,
            bottom: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Top pull-down handle & bar
                  Column(
                    children: [
                      Container(
                        width: 44,
                        height: 5,
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 30,
                            ),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                          Column(
                            children: [
                              const Text(
                                'PLAYING FROM QUEUE',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1.2,
                                  color: AppTheme.textMuted,
                                ),
                              ),
                              Text(
                                song.album ?? 'Musi Library',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              IconButton(
                                icon: const Icon(
                                  Icons.queue_music_rounded,
                                  size: 24,
                                ),
                                tooltip: 'Queue',
                                onPressed: () =>
                                    _showQueueSheet(context, playerService),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.more_vert_rounded,
                                  size: 22,
                                ),
                                onPressed: () =>
                                    _showSongOptions(context, song),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),

                  // Large Album Artwork with buffering overlay if applicable
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: 1.0,
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(24),
                              boxShadow: [
                                BoxShadow(
                                  color: AppTheme.primary.withValues(
                                    alpha: 0.25,
                                  ),
                                  blurRadius: 30,
                                  spreadRadius: 2,
                                  offset: const Offset(0, 10),
                                ),
                              ],
                            ),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(24),
                                  child: song.artworkUrl != null
                                      ? Image.network(
                                          song.artworkUrl!,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, _, _) =>
                                              _buildFallbackArtwork(),
                                        )
                                      : _buildFallbackArtwork(),
                                ),
                                if (playerService.isBuffering)
                                  Container(
                                    decoration: BoxDecoration(
                                      color: Colors.black45,
                                      borderRadius: BorderRadius.circular(24),
                                    ),
                                    child: const Center(
                                      child: CircularProgressIndicator(
                                        color: AppTheme.accent,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Song Title, Artist, Like & Download buttons
                  Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  song.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                    color: AppTheme.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  song.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              isLiked
                                  ? Icons.favorite_rounded
                                  : Icons.favorite_border_rounded,
                              color: isLiked
                                  ? AppTheme.accent
                                  : AppTheme.textSecondary,
                              size: 28,
                            ),
                            tooltip: isLiked ? 'Unlike' : 'Like',
                            onPressed: () => libraryService.toggleLike(song),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.playlist_add_rounded,
                              color: AppTheme.accent,
                              size: 28,
                            ),
                            tooltip: 'Add to Playlist',
                            onPressed: () =>
                                _showAddToPlaylistDialog(context, song),
                          ),
                           IconButton(
                              icon: Icon(
                                isDownloaded
                                    ? Icons.download_done_rounded
                                    : Icons.download_rounded,
                                color: isDownloaded
                                    ? AppTheme.accent
                                    : AppTheme.textSecondary,
                                size: 28,
                              ),
                              tooltip: isDownloaded
                                  ? 'Downloaded'
                                  : 'Download for Offline',
                              onPressed: () {
                                libraryService.toggleDownload(
                                  song,
                                  onError: (err) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(err),
                                        backgroundColor: AppTheme.surfaceCard,
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Progress Bar & Durations
                      Column(
                        children: [
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 7,
                              ),
                              trackHeight: 4,
                            ),
                            child: Slider(
                              value: effectivePositionMs,
                              min: 0.0,
                              max: totalDurationMs > 0 ? totalDurationMs : 1.0,
                              onChanged: (val) {
                                setState(() {
                                  _dragValue = val;
                                });
                              },
                              onChangeEnd: (val) {
                                playerService.seek(
                                  Duration(milliseconds: val.round()),
                                );
                                setState(() {
                                  _dragValue = null;
                                });
                              },
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _formatDuration(
                                    Duration(
                                      milliseconds: effectivePositionMs.round(),
                                    ),
                                  ),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textMuted,
                                  ),
                                ),
                                if (playerService.isBuffering)
                                  const Text(
                                    'Buffering...',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: AppTheme.accent,
                                    ),
                                  ),
                                Text(
                                  _formatDuration(playerService.totalDuration),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),

                      // Player Controls (Shuffle, Prev, Play/Pause, Next, Repeat)
                      const PlayerControls(iconScale: 1.0),

                      const SizedBox(height: 16),

                      // Audio source / Permitted indicator info
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.verified_user_outlined,
                            size: 14,
                            color: AppTheme.textMuted,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            song.sourceUrl != null
                                ? 'Source: ${song.sourceUrl}'
                                : 'Permitted Stream Source',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppTheme.textMuted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildFallbackArtwork() {
    return Container(
      color: AppTheme.surfaceLight,
      child: const Center(
        child: Icon(Icons.music_note, color: AppTheme.primaryLight, size: 90),
      ),
    );
  }

  void _showQueueSheet(BuildContext context, PlayerService playerService) {
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
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Queue (${playerService.queue.length} songs)',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        playerService.clearQueue();
                        Navigator.pop(ctx);
                      },
                      child: const Text(
                        'Clear',
                        style: TextStyle(color: AppTheme.error),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: playerService.queue.length,
                  itemBuilder: (c, idx) {
                    final qSong = playerService.queue[idx];
                    final isCurrent = qSong.id == playerService.currentSong?.id;
                    return ListTile(
                      leading: Icon(
                        isCurrent
                            ? Icons.volume_up_rounded
                            : Icons.music_note_rounded,
                        color: isCurrent ? AppTheme.accent : AppTheme.textMuted,
                      ),
                      title: Text(
                        qSong.title,
                        style: TextStyle(
                          color: isCurrent
                              ? AppTheme.accent
                              : AppTheme.textPrimary,
                          fontWeight: isCurrent
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                      subtitle: Text(
                        qSong.artist,
                        style: const TextStyle(color: AppTheme.textSecondary),
                      ),
                      trailing: Text(
                        qSong.durationFormatted,
                        style: const TextStyle(color: AppTheme.textMuted),
                      ),
                      onTap: () {
                        playerService.playSong(qSong);
                        Navigator.pop(ctx);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showSongOptions(BuildContext context, dynamic song) {
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
              ListTile(
                leading: const Icon(
                  Icons.playlist_add_rounded,
                  color: AppTheme.textPrimary,
                ),
                title: const Text('Add to Playlist'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showAddToPlaylistDialog(context, song);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.info_outline_rounded,
                  color: AppTheme.textPrimary,
                ),
                title: const Text('Song Details & License'),
                subtitle: Text('ID: ${song.id}\nStream: ${song.streamUrl}'),
                onTap: () => Navigator.pop(ctx),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showAddToPlaylistDialog(BuildContext context, dynamic song) {
    final playlists = LibraryService().playlists;
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppTheme.surfaceCard,
          title: const Text(
            'Add to Playlist',
            style: TextStyle(color: AppTheme.textPrimary),
          ),
          content: playlists.isEmpty
              ? const Text(
                  'No playlists available',
                  style: TextStyle(color: AppTheme.textSecondary),
                )
              : SizedBox(
                  width: double.maxFinite,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: playlists.length,
                    itemBuilder: (c, idx) {
                      final p = playlists[idx];
                      return ListTile(
                        title: Text(
                          p.name,
                          style: const TextStyle(color: AppTheme.textPrimary),
                        ),
                        subtitle: Text(
                          '${p.songCount} songs',
                          style: const TextStyle(color: AppTheme.textSecondary),
                        ),
                        onTap: () {
                          LibraryService().addSongToPlaylist(p.id, song);
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Added to ${p.name}')),
                          );
                        },
                      );
                    },
                  ),
                ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Cancel',
                style: TextStyle(color: AppTheme.accent),
              ),
            ),
          ],
        );
      },
    );
  }
}

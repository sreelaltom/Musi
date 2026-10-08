import 'package:flutter/material.dart';

import '../screens/player_screen.dart';
import '../services/player_service.dart';
import '../theme/app_theme.dart';

class MiniPlayer extends StatelessWidget {
  final GlobalKey<NavigatorState> navigatorKey;

  const MiniPlayer({super.key, required this.navigatorKey});

  @override
  Widget build(BuildContext context) {
    final playerService = PlayerService();

    return ListenableBuilder(
      listenable: playerService,
      builder: (context, _) {
        final song = playerService.currentSong;
        final video = playerService.currentYouTubeVideo;

        if (song == null && video == null) {
          return const SizedBox.shrink();
        }
        final displayVideo = song == null || playerService.isBuffering
            ? video
            : null;

        return _buildMusiPlayer(
          context,
          title: displayVideo?.title ?? song?.title ?? video?.title ?? '',
          artist:
              displayVideo?.channelTitle ??
              song?.artist ??
              video?.channelTitle ??
              '',
          artworkUrl:
              displayVideo?.thumbnailUrl ??
              song?.artworkUrl ??
              video?.thumbnailUrl,
          playerService: playerService,
        );
      },
    );
  }

  Widget _buildMusiPlayer(
    BuildContext context, {
    required String title,
    required String artist,
    required String? artworkUrl,
    required PlayerService playerService,
  }) {
    final double progress = playerService.totalDuration.inMilliseconds > 0
        ? (playerService.currentPosition.inMilliseconds /
                  playerService.totalDuration.inMilliseconds)
              .clamp(0.0, 1.0)
        : 0.0;

    return GestureDetector(
      onTap: () {
        navigatorKey.currentState?.push(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: '/player'),
            builder: (_) => const PlayerScreen(),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.surfaceCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: AppTheme.primary.withValues(alpha: 0.25),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        width: 44,
                        height: 44,
                        color: AppTheme.surfaceLight,
                        child: artworkUrl != null && artworkUrl.isNotEmpty
                            ? Image.network(
                                artworkUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => const Icon(
                                  Icons.music_note,
                                  color: AppTheme.primaryLight,
                                  size: 24,
                                ),
                              )
                            : const Icon(
                                Icons.music_note,
                                color: AppTheme.primaryLight,
                                size: 24,
                              ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary,
                              decoration: TextDecoration.none,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.textSecondary,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: playerService.isCurrentSongLiked
                          ? 'Unlike song'
                          : 'Like song',
                      icon: Icon(
                        playerService.isCurrentSongLiked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        color: playerService.isCurrentSongLiked
                            ? AppTheme.accent
                            : AppTheme.textSecondary,
                        size: 20,
                      ),
                      onPressed: playerService.toggleCurrentLike,
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(
                        minimumSize: const Size(36, 36),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Previous',
                      icon: const Icon(
                        Icons.skip_previous_rounded,
                        color: AppTheme.textPrimary,
                        size: 26,
                      ),
                      onPressed: playerService.previous,
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(
                        minimumSize: const Size(36, 36),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    IconButton(
                      tooltip: playerService.isPlaying ? 'Pause' : 'Play',
                      icon: Icon(
                        playerService.isPlaying
                            ? Icons.pause_circle_filled_rounded
                            : Icons.play_circle_fill_rounded,
                        color: AppTheme.accent,
                        size: 34,
                      ),
                      onPressed: playerService.togglePlayPause,
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(
                        minimumSize: const Size(36, 36),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.skip_next_rounded,
                        color: AppTheme.textPrimary,
                        size: 26,
                      ),
                      onPressed: playerService.next,
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(
                        minimumSize: const Size(36, 36),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],
                ),
              ),
              LinearProgressIndicator(
                value: progress,
                backgroundColor: AppTheme.surfaceLight,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  AppTheme.accent,
                ),
                minHeight: 2.5,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

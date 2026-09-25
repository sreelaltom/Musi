import 'package:flutter/material.dart';

import '../screens/player_screen.dart';
import '../services/player_service.dart';
import '../theme/app_theme.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final playerService = PlayerService();

    return ListenableBuilder(
      listenable: playerService,
      builder: (context, _) {
        final song = playerService.currentSong;

        if (song == null) {
          return const SizedBox.shrink();
        }

        return _buildMusiPlayer(context, song, playerService);
      },
    );
  }

  Widget _buildMusiPlayer(
    BuildContext context,
    dynamic song,
    PlayerService playerService,
  ) {
    final double progress = playerService.totalDuration.inMilliseconds > 0
        ? (playerService.currentPosition.inMilliseconds /
                  playerService.totalDuration.inMilliseconds)
              .clamp(0.0, 1.0)
        : 0.0;

    return GestureDetector(
      onTap: () {
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          backgroundColor: Colors.transparent,
          builder: (ctx) => const PlayerScreen(),
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
                        child: song.artworkUrl != null
                            ? Image.network(
                                song.artworkUrl!,
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
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        playerService.isPlaying
                            ? Icons.pause_circle_filled_rounded
                            : Icons.play_circle_fill_rounded,
                        color: AppTheme.accent,
                        size: 34,
                      ),
                      onPressed: playerService.togglePlayPause,
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.skip_next_rounded,
                        color: AppTheme.textPrimary,
                        size: 26,
                      ),
                      onPressed: playerService.next,
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

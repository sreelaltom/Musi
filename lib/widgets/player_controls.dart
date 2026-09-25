import 'package:flutter/material.dart';

import '../services/player_service.dart';
import '../theme/app_theme.dart';

class PlayerControls extends StatelessWidget {
  final double iconScale;

  const PlayerControls({super.key, this.iconScale = 1.0});

  @override
  Widget build(BuildContext context) {
    final playerService = PlayerService();

    return ListenableBuilder(
      listenable: playerService,
      builder: (context, _) {
        final isShuffle = playerService.isShuffle;
        final repeatMode = playerService.repeatMode;

        IconData repeatIcon;
        Color repeatColor = AppTheme.textMuted;
        switch (repeatMode) {
          case PlayerRepeatMode.off:
            repeatIcon = Icons.repeat_rounded;
            repeatColor = AppTheme.textMuted;
            break;
          case PlayerRepeatMode.all:
            repeatIcon = Icons.repeat_rounded;
            repeatColor = AppTheme.accent;
            break;
          case PlayerRepeatMode.one:
            repeatIcon = Icons.repeat_one_rounded;
            repeatColor = AppTheme.accent;
            break;
        }

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // Shuffle
            IconButton(
              icon: Icon(
                Icons.shuffle_rounded,
                color: isShuffle ? AppTheme.accent : AppTheme.textMuted,
                size: 24 * iconScale,
              ),
              tooltip: isShuffle ? 'Shuffle On' : 'Shuffle Off',
              onPressed: playerService.toggleShuffle,
            ),

            // Previous
            IconButton(
              icon: Icon(
                Icons.skip_previous_rounded,
                color: AppTheme.textPrimary,
                size: 36 * iconScale,
              ),
              tooltip: 'Previous',
              onPressed: playerService.previous,
            ),

            // Play / Pause
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [AppTheme.primary, AppTheme.accent],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.primary.withValues(alpha: 0.4),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: IconButton(
                padding: EdgeInsets.all(14 * iconScale),
                icon: Icon(
                  playerService.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 40 * iconScale,
                ),
                tooltip: playerService.isPlaying ? 'Pause' : 'Play',
                onPressed: playerService.togglePlayPause,
              ),
            ),

            // Next
            IconButton(
              icon: Icon(
                Icons.skip_next_rounded,
                color: AppTheme.textPrimary,
                size: 36 * iconScale,
              ),
              tooltip: 'Next',
              onPressed: playerService.next,
            ),

            // Repeat
            IconButton(
              icon: Icon(repeatIcon, color: repeatColor, size: 24 * iconScale),
              tooltip: 'Repeat: ${repeatMode.name}',
              onPressed: playerService.cycleRepeatMode,
            ),
          ],
        );
      },
    );
  }
}

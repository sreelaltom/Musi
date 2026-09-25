import 'package:flutter/material.dart';

import '../models/youtube_music_result.dart';
import '../theme/app_theme.dart';

class YouTubeResultTile extends StatelessWidget {
  final YouTubeMusicResult video;
  final VoidCallback? onTap;
  final VoidCallback? onPlay;
  final VoidCallback? onSkip;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onLike;
  final bool isLiked;
  final bool isPlaying;
  final bool isLoading;

  const YouTubeResultTile({
    super.key,
    required this.video,
    this.onTap,
    this.onPlay,
    this.onSkip,
    this.onAddToPlaylist,
    this.onLike,
    this.isLiked = false,
    this.isPlaying = false,
    this.isLoading = false,
  });

  String _formatDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: isPlaying
            ? AppTheme.primary.withValues(alpha: 0.12)
            : AppTheme.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap ?? onPlay,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                // Thumbnail with duration overlay
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        color: AppTheme.surfaceLight,
                        child: video.thumbnailUrl.isNotEmpty
                            ? Image.network(
                                video.thumbnailUrl,
                                fit: BoxFit.cover,
                                width: 56,
                                height: 56,
                                errorBuilder: (_, _, _) =>
                                    _buildFallbackThumbnail(),
                              )
                            : _buildFallbackThumbnail(),
                      ),
                      if (video.durationSeconds != null &&
                          video.durationSeconds! > 0)
                        Positioned(
                          bottom: 2,
                          right: 2,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.75),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              _formatDuration(video.durationSeconds!),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),

                // Video info (Title & Channel with badge)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isPlaying
                              ? AppTheme.accent
                              : AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              video.channelTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.error.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: AppTheme.error.withValues(alpha: 0.35),
                              ),
                            ),
                            child: const Text(
                              'YouTube',
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 8),

                // Quick Play/Pause or Spinner
                if (isLoading)
                  const SizedBox(
                    width: 38,
                    height: 38,
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppTheme.accent,
                        ),
                      ),
                    ),
                  )
                else
                  IconButton(
                    icon: Icon(
                      isPlaying
                          ? Icons.pause_circle_filled_rounded
                          : Icons.play_circle_fill_rounded,
                      color: isPlaying
                          ? AppTheme.accent
                          : AppTheme.primaryLight,
                      size: 34,
                    ),
                    tooltip: isPlaying ? 'Pause' : 'Play',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 38,
                      minHeight: 38,
                    ),
                    onPressed: onPlay ?? onTap,
                  ),

                // More Options Menu (Add to playlist, Like, Watch Video, etc.)
                PopupMenuButton<String>(
                  icon: const Icon(
                    Icons.more_vert_rounded,
                    color: AppTheme.textMuted,
                    size: 20,
                  ),
                  tooltip: 'Options',
                  color: AppTheme.surfaceCard,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                   onSelected: (value) {
                    switch (value) {
                      case 'like':
                        onLike?.call();
                        break;
                      case 'playlist':
                        onAddToPlaylist?.call();
                        break;
                      case 'skip':
                        onSkip?.call();
                        break;
                    }
                  },
                  itemBuilder: (ctx) => [
                    PopupMenuItem(
                      value: 'like',
                      child: Row(
                        children: [
                          Icon(
                            isLiked
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                            color: isLiked
                                ? AppTheme.accent
                                : AppTheme.textPrimary,
                            size: 18,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            isLiked ? 'Unlike' : 'Like Song',
                            style: const TextStyle(color: AppTheme.textPrimary),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'playlist',
                      child: const Row(
                        children: [
                          Icon(
                            Icons.playlist_add_rounded,
                            color: AppTheme.textPrimary,
                            size: 18,
                          ),
                          SizedBox(width: 10),
                          Text(
                            'Add to Playlist',
                            style: TextStyle(color: AppTheme.textPrimary),
                          ),
                        ],
                      ),
                    ),
                    if (onSkip != null)
                      PopupMenuItem(
                        value: 'skip',
                        child: const Row(
                          children: [
                            Icon(
                              Icons.close_rounded,
                              color: AppTheme.textMuted,
                              size: 18,
                            ),
                            SizedBox(width: 10),
                            Text(
                              'Dismiss',
                              style: TextStyle(color: AppTheme.textMuted),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFallbackThumbnail() {
    return Container(
      color: AppTheme.surfaceLight,
      child: const Center(
        child: Icon(
          Icons.ondemand_video_rounded,
          color: AppTheme.primaryLight,
          size: 26,
        ),
      ),
    );
  }
}

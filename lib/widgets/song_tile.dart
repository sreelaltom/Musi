import 'package:flutter/material.dart';

import '../models/song.dart';
import '../models/music_provider.dart';
import '../services/player_service.dart';
import '../services/library_service.dart';
import '../services/download_service.dart';
import '../services/music_provider_manager.dart';
import '../theme/app_theme.dart';

class SongTile extends StatelessWidget {
  final Song song;
  final List<Song>? queueContext;
  final VoidCallback? onTap;
  final bool showArtwork;

  const SongTile({
    super.key,
    required this.song,
    this.queueContext,
    this.onTap,
    this.showArtwork = true,
  });

  @override
  Widget build(BuildContext context) {
    final playerService = PlayerService();
    final libraryService = LibraryService();
    final downloadService = DownloadService();
    final providerManager = MusicProviderManager();

    return ListenableBuilder(
      listenable: Listenable.merge([
        playerService,
        libraryService,
        downloadService,
      ]),
      builder: (context, _) {
        final isCurrentSong = playerService.currentSong?.id == song.id;
        final isPlaying = isCurrentSong && playerService.isPlaying;
        final isLiked = libraryService.isLiked(song.id);
        final isDownloaded = libraryService.isDownloaded(song.id);
        final isDownloading = downloadService.isDownloading(song.id);
        final progress = downloadService.getProgress(song.id);

        final playability = providerManager.validatePlayability(song);
        final canPlay = playability == SourcePlayability.playable;
        final canDownload = providerManager.canDownload(song);

        return InkWell(
          onTap: canPlay
              ? (onTap ??
                    () {
                      playerService.playSong(
                        song,
                        contextQueue: queueContext,
                        onError: (err) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(err),
                              backgroundColor: AppTheme.surfaceCard,
                            ),
                          );
                        },
                      );
                      libraryService.addRecentlyPlayed(song);
                    })
              : null,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                if (showArtwork) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      width: 52,
                      height: 52,
                      color: AppTheme.surfaceLight,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          if (song.artworkUrl != null)
                            Image.network(
                              song.artworkUrl!,
                              fit: BoxFit.cover,
                              width: 52,
                              height: 52,
                              errorBuilder: (_, _, _) =>
                                  _buildFallbackArtwork(),
                            )
                          else
                            _buildFallbackArtwork(),
                          if (isCurrentSong)
                            Container(
                              width: 52,
                              height: 52,
                              color: Colors.black54,
                              child: Icon(
                                isPlaying
                                    ? Icons.volume_up_rounded
                                    : Icons.pause_rounded,
                                color: AppTheme.accent,
                                size: 24,
                              ),
                            ),
                          if (!canPlay)
                            Container(
                              width: 52,
                              height: 52,
                              color: Colors.black54,
                              child: Icon(
                                Icons.lock_outline_rounded,
                                color: Colors.white.withValues(alpha: 0.7),
                                size: 24,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: isCurrentSong
                                    ? AppTheme.accent
                                    : (canPlay
                                          ? AppTheme.textPrimary
                                          : AppTheme.textSecondary),
                              ),
                            ),
                          ),
                          if (!canPlay)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.amber.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: Colors.amber.withValues(alpha: 0.4),
                                ),
                              ),
                              child: Text(
                                _getPlayabilityLabel(playability),
                                style: const TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.amber,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          if (isDownloaded) ...[
                            const Icon(
                              Icons.download_done_rounded,
                              size: 13,
                              color: AppTheme.accent,
                            ),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Text(
                              '${song.artist}${song.album != null ? ' • ${song.album}' : ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (song.providerName != null ||
                          song.license != null) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            if (song.providerName != null) ...[
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: AppTheme.surfaceLight,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  song.providerName!,
                                  style: const TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w500,
                                    color: AppTheme.textMuted,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                            ],
                            if (song.license != null) ...[
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: AppTheme.primary.withValues(
                                    alpha: 0.15,
                                  ),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: AppTheme.primary.withValues(
                                      alpha: 0.3,
                                    ),
                                  ),
                                ),
                                child: Text(
                                  song.license!.name,
                                  style: const TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w500,
                                    color: AppTheme.primaryLight,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                Text(
                  song.durationFormatted,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: Icon(
                    isLiked
                        ? Icons.favorite_rounded
                        : Icons.favorite_outline_rounded,
                    color: isLiked ? AppTheme.accent : AppTheme.textMuted,
                    size: 20,
                  ),
                  tooltip: isLiked ? 'Unlike' : 'Like',
                  onPressed: () => libraryService.toggleLike(song),
                ),
                if (isDownloading)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        value: progress > 0 ? progress : null,
                        strokeWidth: 2.2,
                        color: AppTheme.accent,
                      ),
                    ),
                  )
                else if (canDownload && !isDownloaded)
                  IconButton(
                    icon: Icon(
                      isDownloaded
                          ? Icons.download_done_rounded
                          : Icons.download_rounded,
                      color: isDownloaded
                          ? AppTheme.accent
                          : AppTheme.textMuted,
                      size: 20,
                    ),
                    tooltip: isDownloaded ? 'Remove Download' : 'Download Song',
                    onPressed: () {
                      if (isDownloaded) {
                        _confirmDeleteDownload(context, song, libraryService);
                      } else {
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
                      }
                    },
                  )
                else if (!canDownload && !isDownloaded)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Icon(
                      Icons.lock_outline_rounded,
                      color: AppTheme.textMuted.withValues(alpha: 0.5),
                      size: 20,
                    ),
                  )
                else if (isDownloaded)
                  IconButton(
                    icon: const Icon(
                      Icons.download_done_rounded,
                      color: AppTheme.accent,
                      size: 20,
                    ),
                    tooltip: 'Remove Download',
                    onPressed: () =>
                        _confirmDeleteDownload(context, song, libraryService),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _getPlayabilityLabel(SourcePlayability playability) {
    switch (playability) {
      case SourcePlayability.notPlayableUnknownLicense:
        return 'License';
      case SourcePlayability.notPlayableNoStreamUrl:
        return 'No stream';
      case SourcePlayability.notPlayableProviderDisabled:
        return 'Disabled';
      case SourcePlayability.notPlayableOfflineMode:
        return 'Offline';
      default:
        return 'Locked';
    }
  }

  void _confirmDeleteDownload(
    BuildContext context,
    Song song,
    LibraryService libraryService,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceCard,
        title: const Text(
          'Delete Download?',
          style: TextStyle(color: AppTheme.textPrimary),
        ),
        content: Text(
          'Delete downloaded audio for "${song.title}"? The song will remain in your library but won\'t be available offline.',
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
              Navigator.pop(ctx);
              libraryService.toggleDownload(song);
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

  Widget _buildFallbackArtwork() {
    return Container(
      color: AppTheme.surfaceLight,
      child: const Center(
        child: Icon(Icons.music_note, color: AppTheme.primaryLight, size: 28),
      ),
    );
  }
}

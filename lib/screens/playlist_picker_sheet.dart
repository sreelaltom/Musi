import 'package:flutter/material.dart';

import '../models/youtube_music_result.dart';
import '../services/library_service.dart';
import '../theme/app_theme.dart';

/// Bottom sheet for selecting a playlist to add a YouTube video to.
class PlaylistPickerSheet extends StatelessWidget {
  final YouTubeMusicResult video;
  final LibraryService libraryService;

  const PlaylistPickerSheet({
    super.key,
    required this.video,
    required this.libraryService,
  });

  static Future<void> show(
    BuildContext context,
    YouTubeMusicResult video,
    LibraryService libraryService,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) =>
          PlaylistPickerSheet(video: video, libraryService: libraryService),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.textMuted.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Add to Playlist',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              video.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: AppTheme.textMuted),
            ),
            const SizedBox(height: 16),
            ListenableBuilder(
              listenable: libraryService,
              builder: (context, _) {
                final playlists = libraryService.playlists;
                if (playlists.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No playlists yet.\nCreate one from the Library tab.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
                    ),
                  );
                }
                return Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: playlists.length,
                    itemBuilder: (context, index) {
                      final playlist = playlists[index];
                      return ListTile(
                        leading: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: AppTheme.primary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.queue_music_rounded,
                            color: AppTheme.primary,
                            size: 22,
                          ),
                        ),
                        title: Text(
                          playlist.name,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 15,
                          ),
                        ),
                        subtitle: Text(
                          '${playlist.songs.length} songs',
                          style: const TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 12,
                          ),
                        ),
                        onTap: () async {
                          await libraryService.addYouTubeToPlaylist(
                            playlist.id,
                            video,
                          );
                          if (context.mounted) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Added to playlist'),
                              ),
                            );
                          }
                        },
                      );
                    },
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

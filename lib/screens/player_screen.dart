import 'package:flutter/material.dart';

import '../models/youtube_music_result.dart';
import '../services/player_service.dart';
import '../services/library_service.dart';
import '../services/youtube_music_api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/player_controls.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  double? _dragValue;

  // Related songs state
  bool _relatedLoading = false;
  List<YouTubeMusicResult> _relatedSongs = [];
  List<YouTubeMusicResult> _moreBySinger = [];
  String? _lastFetchedVideoId;

  final _ytApiService = YouTubeMusicApiService();

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _fetchRelated(String videoId, String title, String artist) async {
    if (_lastFetchedVideoId == videoId || _relatedLoading) return;
    setState(() {
      _relatedLoading = true;
      _lastFetchedVideoId = videoId;
    });

    try {
      // Fetch in parallel: generic related + more by same artist
      final results = await Future.wait([
        _ytApiService.getRelatedTracks(
          videoId: videoId,
          title: title,
          artist: artist,
          limit: 15,
        ),
        _ytApiService.searchTracks(
          '$artist songs',
          limit: 12,
          includeAudioUrl: false,
        ),
      ]);

      final related = results[0];
      final moreBySinger = results[1]
          .where((v) => v.videoId != videoId)
          .toList();

      if (mounted) {
        setState(() {
          _relatedSongs = related.where((v) => v.videoId != videoId).toList();
          _moreBySinger = moreBySinger;
          _relatedLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _relatedLoading = false);
    }
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
              child: Text('No song selected', style: TextStyle(color: AppTheme.textMuted)),
            ),
          );
        }

        final isLiked = libraryService.isLiked(song.id);
        final isDownloaded = libraryService.isDownloaded(song.id);

        final totalDurationMs = playerService.totalDuration.inMilliseconds.toDouble();
        final currentPositionMs = playerService.currentPosition.inMilliseconds.toDouble();
        final effectivePositionMs = (_dragValue ?? currentPositionMs).clamp(
          0.0,
          totalDurationMs > 0 ? totalDurationMs : 1.0,
        );

        // Trigger related fetch when song changes
        final videoId = song.id.startsWith('yt_') ? song.id.substring(3) : null;
        if (videoId != null && videoId != _lastFetchedVideoId) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _fetchRelated(videoId, song.title, song.artist);
          });
        }

        final upNext = playerService.ytQueue.isNotEmpty
            ? playerService.ytQueue
                .skip(playerService.currentIndex + 1)
                .take(15)
                .toList()
            : <YouTubeMusicResult>[];

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
            child: CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                // ── Top bar ──────────────────────────────────────────────
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    child: Column(
                      children: [
                        // Pull handle
                        Center(
                          child: Container(
                            width: 44,
                            height: 5,
                            margin: const EdgeInsets.only(bottom: 12),
                            decoration: BoxDecoration(
                              color: Colors.white24,
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30),
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
                                  icon: const Icon(Icons.queue_music_rounded, size: 24),
                                  tooltip: 'Queue',
                                  onPressed: () => _showQueueSheet(context, playerService),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.more_vert_rounded, size: 22),
                                  onPressed: () => _showSongOptions(context, song),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                // ── Album Artwork ─────────────────────────────────────────
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: AspectRatio(
                      aspectRatio: 1.0,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.primary.withValues(alpha: 0.25),
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
                                      errorBuilder: (_, _, _) => _buildFallbackArtwork(),
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
                                  child: CircularProgressIndicator(color: AppTheme.accent),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // ── Song info + controls ──────────────────────────────────
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                    child: Column(
                      children: [
                        // Title, artist, action buttons
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
                                isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                                color: isLiked ? AppTheme.accent : AppTheme.textSecondary,
                                size: 28,
                              ),
                              tooltip: isLiked ? 'Unlike' : 'Like',
                              onPressed: () => libraryService.toggleLike(song),
                            ),
                            IconButton(
                              icon: const Icon(Icons.playlist_add_rounded, color: AppTheme.accent, size: 28),
                              tooltip: 'Add to Playlist',
                              onPressed: () => _showAddToPlaylistDialog(context, song),
                            ),
                            IconButton(
                              icon: Icon(
                                isDownloaded ? Icons.download_done_rounded : Icons.download_rounded,
                                color: isDownloaded ? AppTheme.accent : AppTheme.textSecondary,
                                size: 28,
                              ),
                              tooltip: isDownloaded ? 'Downloaded' : 'Download for Offline',
                              onPressed: () {
                                libraryService.toggleDownload(
                                  song,
                                  onError: (err) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text(err), backgroundColor: AppTheme.surfaceCard),
                                    );
                                  },
                                );
                              },
                            ),
                          ],
                        ),

                        const SizedBox(height: 16),

                        // Progress bar + durations
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                            trackHeight: 4,
                          ),
                          child: Slider(
                            value: effectivePositionMs,
                            min: 0.0,
                            max: totalDurationMs > 0 ? totalDurationMs : 1.0,
                            onChanged: (val) => setState(() => _dragValue = val),
                            onChangeEnd: (val) {
                              playerService.seek(Duration(milliseconds: val.round()));
                              setState(() => _dragValue = null);
                            },
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _formatDuration(Duration(milliseconds: effectivePositionMs.round())),
                                style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                              ),
                              if (playerService.isBuffering)
                                const Text(
                                  'Buffering...',
                                  style: TextStyle(fontSize: 11, color: AppTheme.accent),
                                ),
                              Text(
                                _formatDuration(playerService.totalDuration),
                                style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 12),
                        const PlayerControls(iconScale: 1.0),
                        const SizedBox(height: 16),

                        // Source info
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.verified_user_outlined, size: 14, color: AppTheme.textMuted),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                song.sourceUrl != null
                                    ? 'Source: ${song.sourceUrl}'
                                    : 'Permitted Stream Source',
                                style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                      ],
                    ),
                  ),
                ),

                // ── Divider before related ────────────────────────────────
                const SliverToBoxAdapter(child: SizedBox(height: 8)),
                SliverToBoxAdapter(
                  child: Divider(
                    color: Colors.white.withValues(alpha: 0.06),
                    thickness: 1,
                    indent: 24,
                    endIndent: 24,
                  ),
                ),

                // ── Related Songs carousel ────────────────────────────────
                if (_relatedLoading)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Column(
                          children: [
                            CircularProgressIndicator(color: AppTheme.accent, strokeWidth: 2),
                            SizedBox(height: 10),
                            Text(
                              'Loading related songs...',
                              style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else ...[
                  if (_relatedSongs.isNotEmpty) ...[
                    _buildSectionHeader('Related Songs', Icons.recommend_rounded),
                    SliverToBoxAdapter(
                      child: _RelatedCarousel(
                        songs: _relatedSongs,
                        currentVideoId: videoId,
                        onTap: (v) => PlayerService().playYouTubeAudio(
                          v,
                          contextQueue: List.from(_relatedSongs),
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 8)),
                  ],

                  if (_moreBySinger.isNotEmpty) ...[
                    _buildSectionHeader('More by ${song.artist}', Icons.person_rounded),
                    SliverToBoxAdapter(
                      child: _RelatedCarousel(
                        songs: _moreBySinger,
                        currentVideoId: videoId,
                        onTap: (v) => PlayerService().playYouTubeAudio(
                          v,
                          contextQueue: List.from(_moreBySinger),
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 8)),
                  ],

                  if (upNext.isNotEmpty) ...[
                    _buildSectionHeader('Up Next', Icons.queue_music_rounded),
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (ctx, i) {
                          final v = upNext[i];
                          return _UpNextTile(
                            video: v,
                            index: playerService.currentIndex + 1 + i,
                            onTap: () => PlayerService().playYouTubeAudio(v),
                          );
                        },
                        childCount: upNext.length,
                      ),
                    ),
                  ],
                ],

                // Bottom padding
                const SliverToBoxAdapter(child: SizedBox(height: 32)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 10),
        child: Row(
          children: [
            Icon(icon, size: 18, color: AppTheme.accent),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
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
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Queue (${playerService.queue.length} songs)',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    TextButton(
                      onPressed: () {
                        playerService.clearQueue();
                        Navigator.pop(ctx);
                      },
                      child: const Text('Clear', style: TextStyle(color: AppTheme.error)),
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
                        isCurrent ? Icons.volume_up_rounded : Icons.music_note_rounded,
                        color: isCurrent ? AppTheme.accent : AppTheme.textMuted,
                      ),
                      title: Text(
                        qSong.title,
                        style: TextStyle(
                          color: isCurrent ? AppTheme.accent : AppTheme.textPrimary,
                          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      subtitle: Text(qSong.artist, style: const TextStyle(color: AppTheme.textSecondary)),
                      trailing: Text(qSong.durationFormatted, style: const TextStyle(color: AppTheme.textMuted)),
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
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.playlist_add_rounded, color: AppTheme.textPrimary),
                title: const Text('Add to Playlist'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showAddToPlaylistDialog(context, song);
                },
              ),
              ListTile(
                leading: const Icon(Icons.info_outline_rounded, color: AppTheme.textPrimary),
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
          title: const Text('Add to Playlist', style: TextStyle(color: AppTheme.textPrimary)),
          content: playlists.isEmpty
              ? const Text('No playlists available', style: TextStyle(color: AppTheme.textSecondary))
              : SizedBox(
                  width: double.maxFinite,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: playlists.length,
                    itemBuilder: (c, idx) {
                      final p = playlists[idx];
                      return ListTile(
                        title: Text(p.name, style: const TextStyle(color: AppTheme.textPrimary)),
                        subtitle: Text('${p.songCount} songs', style: const TextStyle(color: AppTheme.textSecondary)),
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
              child: const Text('Cancel', style: TextStyle(color: AppTheme.accent)),
            ),
          ],
        );
      },
    );
  }
}

// ── Related Songs Horizontal Carousel ────────────────────────────────────────
class _RelatedCarousel extends StatelessWidget {
  final List<YouTubeMusicResult> songs;
  final String? currentVideoId;
  final void Function(YouTubeMusicResult) onTap;

  const _RelatedCarousel({
    required this.songs,
    required this.onTap,
    this.currentVideoId,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 170,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: songs.length,
        itemBuilder: (ctx, i) {
          final v = songs[i];
          final isCurrent = v.videoId == currentVideoId;
          return GestureDetector(
            onTap: () => onTap(v),
            child: Container(
              width: 130,
              margin: const EdgeInsets.only(right: 12),
              decoration: BoxDecoration(
                color: isCurrent ? AppTheme.primary.withValues(alpha: 0.15) : AppTheme.surfaceCard,
                borderRadius: BorderRadius.circular(14),
                border: isCurrent
                    ? Border.all(color: AppTheme.accent, width: 1.5)
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Thumbnail
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
                    child: v.thumbnailUrl.isNotEmpty
                        ? Image.network(
                            v.thumbnailUrl,
                            width: 130,
                            height: 100,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => _fallbackThumb(),
                          )
                        : _fallbackThumb(),
                  ),
                  // Title + artist
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            v.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: isCurrent ? AppTheme.accent : AppTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            v.channelTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 10, color: AppTheme.textMuted),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _fallbackThumb() {
    return Container(
      width: 130,
      height: 100,
      color: AppTheme.surfaceLight,
      child: const Icon(Icons.music_note_rounded, color: AppTheme.textMuted, size: 36),
    );
  }
}

// ── Up Next List Tile ─────────────────────────────────────────────────────────
class _UpNextTile extends StatelessWidget {
  final YouTubeMusicResult video;
  final int index;
  final VoidCallback onTap;

  const _UpNextTile({
    required this.video,
    required this.index,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 2),
      leading: Stack(
        alignment: Alignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: video.thumbnailUrl.isNotEmpty
                ? Image.network(
                    video.thumbnailUrl,
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 48,
                      height: 48,
                      color: AppTheme.surfaceLight,
                      child: const Icon(Icons.music_note_rounded, color: AppTheme.textMuted, size: 22),
                    ),
                  )
                : Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceLight,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.music_note_rounded, color: AppTheme.textMuted, size: 22),
                  ),
          ),
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.black45,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(
                '$index',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
      title: Text(
        video.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppTheme.textPrimary),
      ),
      subtitle: Text(
        video.channelTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
      ),
      trailing: video.durationFormatted != null
          ? Text(video.durationFormatted!, style: const TextStyle(fontSize: 11, color: AppTheme.textMuted))
          : null,
      onTap: onTap,
    );
  }
}

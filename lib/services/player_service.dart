import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/song.dart';
import '../models/playlist_item.dart';
import '../models/youtube_music_result.dart';
import '../database/song_dao.dart';
import '../database/settings_dao.dart';
import '../database/music_cache_dao.dart';
import '../models/music_cache_entry.dart';
import '../services/audio_handler.dart';
import '../services/library_service.dart';
import '../services/music_item_resolver.dart';
import '../services/youtube_audio_service.dart';
import '../services/youtube_music_api_service.dart';

enum PlayerRepeatMode { off, all, one }

/// A single queued Next/Previous request.
///
/// [completer] lets the caller await its own request specifically, so a caller
/// such as auto-advance finishes only once the song it asked for has actually
/// been loaded and started.
class _NavRequest {
  final bool next;
  final Completer<void> completer = Completer<void>();

  _NavRequest(this.next);

  String get label => next ? 'next' : 'previous';
}

class PlayerService extends ChangeNotifier {
  static final PlayerService _instance = PlayerService._internal();
  factory PlayerService() => _instance;
  PlayerService._internal();

  MusiAudioHandler? _audioHandler;
  final SongDao _songDao = SongDao();
  final SettingsDao _settingsDao = SettingsDao();
  final MusicCacheDao _musicCacheDao = MusicCacheDao();
  final MusicItemResolver _resolver = MusicItemResolver();
  final YouTubeAudioService _youtubeAudioService = YouTubeAudioService();
  final YouTubeMusicApiService _ytApiService = YouTubeMusicApiService();

  Song? _currentSong;
  YouTubeMusicResult? _currentYouTubeVideo;
  bool _isPlaying = false;
  bool _isBuffering = false;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  DateTime? _lastPositionUiUpdate;
  DateTime? _lastPlaybackSnapshotWrite;
  Duration? _pendingResumePosition;

  // _ytQueue stores the ordered YouTube videos for next/prev navigation
  List<YouTubeMusicResult> _ytQueue = [];
  List<Song> _queue = [];
  List<PlaylistItem> _mixedQueue = [];
  int _currentIndex = -1;
  bool _isShuffle = false;
  PlayerRepeatMode _repeatMode = PlayerRepeatMode.off;
  String? _lastError;

  /// Whether the active queue may be grown with YouTube related tracks.
  ///
  /// Saved queues play in their defined order first, then related discoveries
  /// are appended so playback can continue beyond the final saved item.
  bool _allowRelatedExtension = true;

  /// Whether the active queue will be grown with YouTube related tracks.
  ///
  /// Exposed for tests and queue diagnostics.
  @visibleForTesting
  bool get allowsRelatedExtension => _allowRelatedExtension;

  /// Pending Next/Previous requests, oldest first.
  ///
  /// Every press from any surface (in-app button, notification, lock screen,
  /// headset, Bluetooth) lands here and is honoured in order. Requests are never
  /// dropped: a skip pressed while the previous song is still resolving still
  /// runs, and a burst of same-direction presses advances one position per
  /// press. The worker coalesces a burst into a single load so it does not pay
  /// for one stream resolve per press.
  final List<_NavRequest> _navQueue = [];

  /// True while [_drainNavQueue] is processing the queue. Guarantees only one
  /// navigation touches `_currentIndex` and the audio handler at a time, so
  /// rapid presses cannot produce conflicting or duplicated playback requests.
  bool _navWorkerRunning = false;

  /// Safety valve only. Far above any realistic burst of presses; it exists so a
  /// stuck media key cannot grow the queue without bound. Requests are never
  /// dropped in normal use.
  static const int _maxQueuedNavigation = 50;

  // Guards against duplicate auto-advance from repeated `completed` states
  bool _isAdvancing = false;

  // Pre-warm timer: resolves next track's URL while current song still plays
  Timer? _prewarmTimer;
  Timer? _sleepTimerTicker;
  DateTime? _sleepTimerDeadline;
  String? _prewarmingVideoId; // tracks which videoId we're pre-warming
  bool _relatedEnsuredForCurrentTrack = false; // one background refill per song

  // In-flight related-tracks fetch, so overlapping requests for the SAME song
  // share one lookup instead of racing (or being dropped).
  Future<int>? _relatedFetchInFlight;
  String? _relatedFetchVideoId;

  /// Budget for a single `getRelatedTracks` cascade.
  static const Duration _relatedFetchCallTimeout = Duration(seconds: 25);

  /// Wall-clock budget for one `next()`/`previous()` navigation, covering all
  /// of its skip-past-unplayable retries.
  ///
  /// A single track whose stream cannot be resolved already costs a full
  /// resolve timeout, so without an overall cap a run of unplayable tracks
  /// could block navigation for many minutes. This stays under the 90s
  /// stalled-navigation threshold so the navigation guard is always released by
  /// this budget rather than by the stalled-navigation recovery (which would
  /// leave two navigations racing over the same queue index).
  static const Duration _navigationBudget = Duration(seconds: 60);

  /// Total budget for the related-tracks fetch that runs AHEAD of time, when the
  /// queue is running low. Nothing is waiting on it, so it can be patient.
  static const Duration _relatedFetchBackgroundBudget = Duration(seconds: 60);

  /// Total budget for the related-tracks fetch made from inside `next()` when the
  /// queue has run out. Playback has already stopped here and the user is
  /// waiting — with the phone locked this is the difference between "rolls on
  /// to the next song" and "looks broken", so it gets one short attempt.
  static const Duration _relatedFetchAdvanceBudget = Duration(seconds: 8);

  // Watches for the wedged state where the UI/session say "playing" but the
  // player has no source loaded, and restarts playback.
  Timer? _stallWatchdog;
  int _stallRecoveries = 0;
  DateTime? _lastStallRecovery;

  // Stream subscriptions
  StreamSubscription? _posSub;
  StreamSubscription? _bufferedSub;
  StreamSubscription? _durSub;
  StreamSubscription? _stateSub;
  StreamSubscription? _errSub; // ExoPlayer error stream (catches 403 directly)

  Song? get currentSong => _currentSong;
  YouTubeMusicResult? get currentYouTubeVideo => _currentYouTubeVideo;
  bool get isPlaying => _isPlaying;
  bool get isBuffering => _isBuffering;
  Duration get currentPosition => _currentPosition;
  Duration get totalDuration => _totalDuration;
  Duration get bufferedPosition => _bufferedPosition;
  List<Song> get queue => List.unmodifiable(_queue);
  List<PlaylistItem> get mixedQueue => List.unmodifiable(_mixedQueue);
  List<YouTubeMusicResult> get ytQueue => List.unmodifiable(_ytQueue);
  int get currentIndex => _currentIndex;
  bool get isShuffle => _isShuffle;
  PlayerRepeatMode get repeatMode => _repeatMode;
  bool get hasCurrentSong => _currentSong != null;
  bool get hasCurrentYouTubeVideo => _currentYouTubeVideo != null;
  bool get isCurrentSongLiked {
    final song = _currentSong;
    if (song != null) return LibraryService().isLiked(song.id);
    final video = _currentYouTubeVideo;
    return video != null && LibraryService().isLiked('yt_${video.videoId}');
  }

  String? get lastError => _lastError;
  bool get isPlayingYouTube => _currentYouTubeVideo != null;
  DateTime? get sleepTimerDeadline => _sleepTimerDeadline;
  Duration? get sleepTimerRemaining {
    final deadline = _sleepTimerDeadline;
    if (deadline == null) return null;
    final remaining = deadline.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Starts an in-memory sleep timer. It runs while playback is in the
  /// background, and intentionally is not persisted across a process restart.
  void startSleepTimer(Duration duration) {
    if (duration <= Duration.zero) {
      throw ArgumentError.value(duration, 'duration', 'Must be positive.');
    }
    _sleepTimerTicker?.cancel();
    _sleepTimerDeadline = DateTime.now().add(duration);
    _sleepTimerTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final remaining = sleepTimerRemaining;
      if (remaining == null) return;
      if (remaining == Duration.zero) {
        _finishSleepTimer();
      } else {
        notifyListeners();
      }
    });
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTimerTicker?.cancel();
    _sleepTimerTicker = null;
    if (_sleepTimerDeadline == null) return;
    _sleepTimerDeadline = null;
    notifyListeners();
  }

  void _finishSleepTimer() {
    _sleepTimerTicker?.cancel();
    _sleepTimerTicker = null;
    if (_sleepTimerDeadline == null) return;
    _sleepTimerDeadline = null;
    notifyListeners();
    // Pause the active source; keep its item and queue intact for later.
    unawaited(pause());
  }

  @visibleForTesting
  static Song mergeRestoredTrackMetadata(
    Song song,
    YouTubeMusicResult? queuedVideo,
  ) => song.copyWith(
    title: YouTubeMusicResult.isUsableTitle(song.title)
        ? song.title
        : YouTubeMusicResult.isUsableTitle(queuedVideo?.title)
        ? queuedVideo!.title
        : song.title,
    artist: YouTubeMusicResult.isUsableTitle(song.artist)
        ? song.artist
        : YouTubeMusicResult.isUsableTitle(queuedVideo?.channelTitle)
        ? queuedVideo!.channelTitle
        : song.artist,
    artworkUrl: (song.artworkUrl?.isNotEmpty ?? false)
        ? song.artworkUrl
        : queuedVideo?.thumbnailUrl,
  );

  /// Replaces the visible metadata for a currently playing YouTube track after
  /// its title has been recovered from the video's canonical details.
  void updateCurrentSongMetadata(Song song) {
    if (_currentSong?.id != song.id) return;
    _currentSong = song;
    _queue = _queue.map((item) => item.id == song.id ? song : item).toList();
    final videoId = YouTubeAudioService.extractVideoId(song);
    if (videoId != null) {
      final title = song.title;
      final artist = song.artist;
      final artwork = song.artworkUrl;
      if (_currentYouTubeVideo?.videoId == videoId) {
        _currentYouTubeVideo = _currentYouTubeVideo!.copyWith(
          title: title,
          channelTitle: artist,
          thumbnailUrl: artwork,
        );
      }
      _ytQueue = _ytQueue
          .map(
            (video) => video.videoId == videoId
                ? video.copyWith(
                    title: title,
                    channelTitle: artist,
                    thumbnailUrl: artwork,
                  )
                : video,
          )
          .toList();
      _mixedQueue = _mixedQueue
          .map(
            (item) => item.isYouTube && item.youtubeVideoId == videoId
                ? item.copyWith(
                    title: title,
                    artistChannel: artist,
                    artworkUrl: artwork,
                  )
                : item,
          )
          .toList();
    }
    _audioHandler?.updateSongMetadata(song);
    notifyListeners();
  }

  void init(MusiAudioHandler handler) {
    _audioHandler = handler;
    _startStallWatchdog();

    // Connect skip callbacks from Android media notification to PlayerService
    _audioHandler!.onPlay = _resumeFromMediaControl;
    _audioHandler!.onSkipToNext = () async => next();
    _audioHandler!.onSkipToPrevious = () async => previous();
    _audioHandler!.onToggleLike = toggleCurrentLike;
    _audioHandler!.onIsCurrentLiked = () => isCurrentSongLiked;
    _audioHandler!.onPreviousMediaTrack = () async =>
        _requestNavigation(next: false);
    _audioHandler!.onTaskRemovedCallback = _persistPlaybackSnapshot;
    _audioHandler!.onPauseCallback = _persistPlaybackSnapshot;
    _audioHandler!.updateLikeState(isCurrentSongLiked);
    unawaited(_restoreLastPlayback());

    final player = _audioHandler!.player;

    _posSub?.cancel();
    _posSub = player.positionStream.listen((pos) {
      _currentPosition = pos;
      final now = DateTime.now();
      final lastSnapshotWrite = _lastPlaybackSnapshotWrite;
      if (lastSnapshotWrite == null ||
          now.difference(lastSnapshotWrite) >= const Duration(seconds: 5)) {
        _lastPlaybackSnapshotWrite = now;
        unawaited(_persistPlaybackSnapshot());
      }
      // Audio position streams can tick many times per second. Publishing each
      // tick rebuilds every player listener (including long scrolling lists),
      // so cap UI refreshes while keeping the slider responsive.
      if (_lastPositionUiUpdate == null ||
          now.difference(_lastPositionUiUpdate!) >=
              const Duration(milliseconds: 350)) {
        _lastPositionUiUpdate = now;
        notifyListeners();
      }
      // Schedule next-track pre-warm when 30s remain (or immediately for short tracks)
      _schedulePrewarm(pos);
    });

    _bufferedSub?.cancel();
    _bufferedSub = player.bufferedPositionStream.listen((buf) {
      _bufferedPosition = buf;
    });

    _durSub?.cancel();
    _durSub = player.durationStream.listen((dur) {
      if (dur != null) {
        _totalDuration = dur;
        notifyListeners();
      }
    });

    _stateSub?.cancel();
    _stateSub = player.playerStateStream.listen((state) {
      _isPlaying = state.playing;
      _isBuffering =
          state.processingState == ProcessingState.buffering ||
          state.processingState == ProcessingState.loading;

      if (state.processingState == ProcessingState.completed) {
        _handleSongCompletion();
      }

      notifyListeners();
    });

    // Listen for ExoPlayer errors (e.g. HTTP 403 on YouTube CDN URLs).
    // When a source error fires, cycle through ALL remaining clients in one
    // locked loop so competing error events cannot trigger a second parallel retry.
    bool autoRetrying = false;
    _errSub?.cancel();
    _errSub = player.errorStream.listen((Object error) async {
      if (autoRetrying) return; // Prevent concurrent auto-retry loops
      final errStr = error.toString();
      debugPrint('PlayerService: ExoPlayer error: $errStr');
      // Check if this looks like a 403/source error on a YouTube track
      final videoId =
          _currentYouTubeVideo?.videoId ??
          (_currentSong != null
              ? YouTubeAudioService.extractVideoId(_currentSong!)
              : null);
      if (videoId == null) return;
      if (!errStr.contains('403') &&
          !errStr.contains('Source error') &&
          !errStr.contains('TYPE_SOURCE')) {
        return;
      }

      // A newly pressed Next/Previous owns the player while its source is
      // being resolved. Retrying the old URL here can stop() that new source,
      // abort its load, and leave the session in an error state. Let the
      // serialized navigation worker finish instead of racing it.
      if (_navWorkerRunning || _navQueue.isNotEmpty) {
        debugPrint(
          'PlayerService: source error for $videoId superseded by queued navigation',
        );
        return;
      }

      autoRetrying = true;
      try {
        debugPrint(
          'PlayerService: ExoPlayer 403 detected, cycling all clients for $videoId',
        );
        final video =
            _currentYouTubeVideo ??
            YouTubeMusicResult(
              videoId: videoId,
              title: _currentSong?.title ?? 'YouTube Track',
              channelTitle: _currentSong?.artist ?? '',
              thumbnailUrl: _currentSong?.artworkUrl ?? '',
              youtubeUrl: 'https://www.youtube.com/watch?v=$videoId',
            );

        // A forced refresh already races yt-dlp with a different extractor
        // client and has its own fallback cascade. Repeating that six times
        // can hold the service in error recovery for several minutes.
        for (int attempt = 1; attempt <= 2; attempt++) {
          try {
            if (_currentYouTubeVideo?.videoId != videoId) return;
            if (_navWorkerRunning || _navQueue.isNotEmpty) return;
            _youtubeAudioService.invalidateCache(videoId);
            final refreshed = await _youtubeAudioService.resolveToSong(
              video,
              forceRefresh: true, // advances client index each call
            );
            if (_currentYouTubeVideo?.videoId != videoId) return;
            if (_navWorkerRunning || _navQueue.isNotEmpty) return;
            if (refreshed != null && _audioHandler != null) {
              _currentSong = refreshed;
              notifyListeners();
              await _audioHandler!.player.stop();
              await _audioHandler!.playSongItem(refreshed);
              debugPrint(
                'PlayerService: Auto-retry succeeded on attempt $attempt for $videoId',
              );
              return; // success — exit the retry loop
            }
          } catch (retryErr) {
            debugPrint(
              'PlayerService: Auto-retry attempt $attempt failed for $videoId: $retryErr',
            );
            if (attempt < 2) {
              await Future.delayed(const Duration(milliseconds: 500));
            }
          }
        }
        debugPrint(
          'PlayerService: stream refreshes exhausted for $videoId; '
          'advancing to the next playable queue item',
        );

        // A failed CDN URL must not leave the lock-screen's Play action
        // pointing at an idle ExoPlayer. If this same song is still current,
        // publish the stopped state and continue through the normal queue
        // worker, which also fetches related tracks for discovery queues.
        if (_currentYouTubeVideo?.videoId == videoId) {
          _lastError = errStr;
          await _markPlaybackStopped();
          if (_currentYouTubeVideo?.videoId == videoId) {
            await _requestNavigation(next: true);
          }
        }
      } finally {
        autoRetrying = false;
      }
    });
  }

  /// Toggles the currently playing song in the existing liked-songs library.
  /// This is shared by the in-app controls and Android media notification.
  Future<void> toggleCurrentLike() async {
    final video = _currentYouTubeVideo;
    final song =
        _currentSong ??
        (video == null
            ? null
            : Song(
                id: 'yt_${video.videoId}',
                title: video.title,
                artist: video.channelTitle.isNotEmpty
                    ? video.channelTitle
                    : 'YouTube',
                album: 'YouTube Music',
                artworkUrl: video.thumbnailUrl,
                streamUrl: '',
                sourceUrl: video.youtubeUrl,
                duration: video.durationSeconds ?? 0,
                providerId: 'youtube',
                providerName: 'YouTube',
              ));
    if (song == null) return;
    await LibraryService().toggleLike(song);
    _audioHandler?.updateLikeState(isCurrentSongLiked);
    notifyListeners();
  }

  static const String _playbackSnapshotKey = 'last_playback_snapshot_v1';

  Future<void> _persistPlaybackSnapshot() async {
    final song = _currentSong;
    final video = _currentYouTubeVideo;
    if (song == null && video == null) return;

    final snapshot = <String, dynamic>{
      'songId': song?.id ?? 'yt_${video!.videoId}',
      'videoId': video?.videoId,
      'positionMs': _currentPosition.inMilliseconds,
      'currentIndex': _currentIndex,
      'mixedQueue': _mixedQueue.map((item) => item.toMap()).toList(),
    };
    try {
      await _settingsDao.setSetting(_playbackSnapshotKey, jsonEncode(snapshot));
    } catch (e) {
      debugPrint('PlayerService: could not save playback position: $e');
    }
  }

  Future<void> _restoreLastPlayback() async {
    try {
      final library = LibraryService();
      await library.init();
      if (_currentSong != null || _currentYouTubeVideo != null) return;

      final encoded = await _settingsDao.getSetting(_playbackSnapshotKey);
      final snapshot = encoded == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(encoded) as Map);
      final songId = snapshot['songId'] as String?;
      Song? song = songId == null ? null : await _songDao.getSongById(songId);
      if (song == null && library.recentlyPlayed.isNotEmpty) {
        song = library.recentlyPlayed.first;
      }
      if (song == null) return;

      final videoId =
          snapshot['videoId'] as String? ??
          YouTubeAudioService.extractVideoId(song);
      final encodedQueue = snapshot['mixedQueue'];
      var mixedQueue = encodedQueue is List
          ? encodedQueue
                .whereType<Map>()
                .map(
                  (item) =>
                      PlaylistItem.fromMap(Map<String, dynamic>.from(item)),
                )
                .toList()
          : <PlaylistItem>[];

      if (mixedQueue.isEmpty) {
        mixedQueue = [
          if (videoId != null)
            PlaylistItem.fromYouTube(
              playlistId: '',
              video: YouTubeMusicResult(
                videoId: videoId,
                title: song.title,
                channelTitle: song.artist,
                thumbnailUrl: song.artworkUrl ?? '',
                youtubeUrl:
                    song.sourceUrl ??
                    'https://www.youtube.com/watch?v=$videoId',
                durationSeconds: song.duration > 0 ? song.duration : null,
              ),
              position: 0,
            )
          else
            PlaylistItem.fromSong(playlistId: '', song: song, position: 0),
        ];
      }

      _mixedQueue = mixedQueue;
      final savedIndex = (snapshot['currentIndex'] as num?)?.toInt() ?? 0;
      _currentIndex = savedIndex.clamp(0, mixedQueue.length - 1);
      _ytQueue = mixedQueue.every((item) => item.isYouTube)
          ? mixedQueue.map((item) => item.resolveYouTube()!).toList()
          : [];
      _queue = <Song>[];
      for (final item in mixedQueue.where((item) => item.isAuthorized)) {
        final savedSong = item.songId == null
            ? null
            : await _songDao.getSongById(item.songId!);
        if (savedSong != null) _queue.add(savedSong);
      }

      final currentPlaylistItem = mixedQueue[_currentIndex];
      final queueVideo = currentPlaylistItem.resolveYouTube();
      final activeSong = mergeRestoredTrackMetadata(song, queueVideo);
      if (activeSong.title != song.title ||
          activeSong.artist != song.artist ||
          activeSong.artworkUrl != song.artworkUrl) {
        await library.updateRecentlyPlayedMetadata(activeSong);
      }
      _currentSong =
          videoId != null &&
              (activeSong.id.startsWith('yt_') || activeSong.id == songId)
          ? activeSong.copyWith(streamUrl: '')
          : activeSong;
      if (videoId != null) {
        _currentYouTubeVideo =
            (queueVideo?.videoId == videoId
                    ? queueVideo
                    : YouTubeMusicResult(
                        videoId: videoId,
                        title: activeSong.title,
                        channelTitle: activeSong.artist,
                        thumbnailUrl: activeSong.artworkUrl ?? '',
                        youtubeUrl:
                            activeSong.sourceUrl ??
                            'https://www.youtube.com/watch?v=$videoId',
                        durationSeconds: activeSong.duration > 0
                            ? activeSong.duration
                            : null,
                      ))
                ?.copyWith(
                  durationSeconds: activeSong.duration > 0
                      ? activeSong.duration
                      : null,
                );
      }

      if (videoId != null &&
          (!YouTubeMusicResult.isUsableTitle(activeSong.title) ||
              !YouTubeMusicResult.isUsableTitle(activeSong.artist))) {
        unawaited(_recoverRestoredTrackMetadata(activeSong, videoId));
      }
      if (_currentSong != null) {
        _audioHandler?.updateSongMetadata(_currentSong!);
      }

      final positionMs = (snapshot['positionMs'] as num?)?.toInt() ?? 0;
      _currentPosition = Duration(milliseconds: positionMs.clamp(0, 86400000));
      _pendingResumePosition = _currentPosition;
      _totalDuration = Duration(
        seconds: activeSong.duration > 0 ? activeSong.duration : 180,
      );
      _isPlaying = false;
      debugPrint('PlayerService: restored last track "${activeSong.title}"');
      notifyListeners();
    } catch (e, st) {
      debugPrint('PlayerService: could not restore last track: $e\n$st');
    }
  }

  Future<void> _recoverRestoredTrackMetadata(Song song, String videoId) async {
    try {
      final cached = await _musicCacheDao.getCacheEntry(
        CachedSourceType.youtube,
        videoId,
      );
      final cachedTitle = cached?.title;
      final details = YouTubeMusicResult.isUsableTitle(cachedTitle)
          ? YouTubeMusicResult(
              videoId: videoId,
              title: cachedTitle!.trim(),
              channelTitle: YouTubeMusicResult.isUsableTitle(cached?.artist)
                  ? cached!.artist!.trim()
                  : 'YouTube',
              thumbnailUrl: cached?.thumbnailUrl ?? '',
              youtubeUrl:
                  cached?.sourceUrl ??
                  'https://www.youtube.com/watch?v=$videoId',
              durationSeconds: cached?.duration,
            )
          : await _ytApiService.getVideoDetails(videoId);
      if (details == null || !details.hasUsableTitle) return;

      final updated = song.copyWith(
        title: details.title,
        artist: YouTubeMusicResult.isUsableTitle(details.channelTitle)
            ? details.channelTitle
            : 'YouTube',
        artworkUrl: details.thumbnailUrl.isNotEmpty
            ? details.thumbnailUrl
            : song.artworkUrl,
        duration:
            details.durationSeconds != null && details.durationSeconds! > 0
            ? details.durationSeconds
            : song.duration,
      );
      await LibraryService().updateRecentlyPlayedMetadata(updated);
      if (_currentSong?.id == song.id) updateCurrentSongMetadata(updated);
      debugPrint('PlayerService: restored title metadata for $videoId');
    } catch (error) {
      debugPrint(
        'PlayerService: could not restore metadata for $videoId: $error',
      );
    }
  }

  void _handleSongCompletion() {
    // A `completed` state can arrive more than once (e.g. re-emitted after a
    // source swap). Only auto-advance on the first one so the next track is
    // not skipped over.
    if (_isAdvancing) return;
    _isAdvancing = true;

    Future<void> run() async {
      try {
        switch (_repeatMode) {
          case PlayerRepeatMode.one:
            await seek(Duration.zero);
            await play();
            break;
          case PlayerRepeatMode.all:
            await next();
            break;
          case PlayerRepeatMode.off:
            // Hand off to next(); it decides whether to advance, wrap on
            // repeat, or stop cleanly at the end of the queue.
            final queueLen = _ytQueue.isNotEmpty
                ? _ytQueue.length
                : (_mixedQueue.isNotEmpty ? _mixedQueue.length : _queue.length);
            if (queueLen > 0) {
              await next();
            } else {
              await pause();
              await seek(Duration.zero);
            }
            break;
        }
      } catch (e) {
        debugPrint('PlayerService: auto-advance failed: $e');
      }
    }

    run().whenComplete(() => _isAdvancing = false);
  }

  /// Schedule pre-warming the next track URL so it's cached before completion.
  /// Called on every position update — uses a timer so we only fire once per song.
  void _schedulePrewarm(Duration position) {
    if (_totalDuration == Duration.zero) return;
    if (!_isPlaying) return;

    final remaining = _totalDuration - position;
    // Trigger 30s before end (or at 50% for tracks shorter than 60s)
    final threshold = _totalDuration.inSeconds < 60
        ? _totalDuration * 0.5
        : const Duration(seconds: 30);

    if (remaining <= threshold) {
      _ensureNextTrackQueued();
      _prewarmNextTrack();
    }
  }

  /// Make sure a next track exists before the current one ends, off the critical
  /// path.
  ///
  /// The related fetch runs once when a song starts and can fail silently — a
  /// rate limit, or no usable network while the app is backgrounded. When that
  /// happens the end-of-track advance has to fetch related tracks inline, which
  /// blocks for the whole advance budget with the phone locked and no feedback.
  /// Retrying here, ~30s before the end, moves that work into the background
  /// where the user cannot feel it.
  ///
  /// Runs at most once per track: position updates fire continuously inside the
  /// pre-warm window, and without this guard a persistently failing endpoint
  /// would be retried on every one of them.
  void _ensureNextTrackQueued() {
    if (!_allowRelatedExtension) return;
    if (_relatedEnsuredForCurrentTrack) return;
    final video = _currentYouTubeVideo;
    if (video == null) return;
    // Something is already queued to play next — nothing to arrange.
    if (_ytQueue.isNotEmpty && _currentIndex + 1 < _ytQueue.length) return;

    _relatedEnsuredForCurrentTrack = true;
    unawaited(
      _fetchAndQueueRelatedSongsForSong(
        video.videoId,
        video.title,
        video.channelTitle,
      ),
    );
  }

  /// Pre-resolve the next track's stream URL into the cache while the current
  /// track is still playing. This means when auto-advance fires — or when the
  /// user presses Next — the URL is already available and playback starts with
  /// no network delay, which is critical for smooth background playback.
  ///
  /// Called as soon as a track starts, so the resolve cost is paid up front in
  /// the background rather than on the Next press.
  void _prewarmNextTrack() {
    final nextId = _nextVideoIdToPrewarm();
    if (nextId == null || nextId.isEmpty) return;

    // Don't pre-warm the same ID twice
    if (_prewarmingVideoId == nextId) return;
    _prewarmingVideoId = nextId;

    _prewarmTimer?.cancel();
    _prewarmTimer = Timer(Duration.zero, () async {
      try {
        debugPrint(
          'PlayerService: Pre-warming stream URL for next track: $nextId',
        );
        await _youtubeAudioService.resolveStream(nextId);
        debugPrint('PlayerService: ✅ Pre-warm complete for $nextId');
      } catch (e) {
        debugPrint('PlayerService: Pre-warm failed for $nextId: $e');
      }
    });
  }

  /// The videoId whose stream should be cached next, across every queue shape.
  ///
  /// `_ytQueue` is checked first because next()/previous() prefer it. Returns
  /// null when there is no known next track — including at the end of a finite
  /// queue, where the following track only exists once related extension has run.
  String? _nextVideoIdToPrewarm() {
    if (_ytQueue.isNotEmpty) {
      final nextIdx = _currentIndex + 1;
      if (nextIdx >= 0 && nextIdx < _ytQueue.length) {
        return _ytQueue[nextIdx].videoId;
      }
      return null;
    }
    if (_mixedQueue.isNotEmpty) {
      final nextIdx = _currentIndex + 1;
      if (nextIdx >= 0 && nextIdx < _mixedQueue.length) {
        return _mixedQueue[nextIdx].youtubeVideoId;
      }
      return null;
    }
    if (_queue.isNotEmpty) {
      final nextIdx = _currentIndex + 1;
      if (nextIdx >= 0 && nextIdx < _queue.length) {
        // Only YouTube-backed songs resolve through YouTubeAudioService;
        // local files and Jamendo tracks are already playable directly.
        final id = _queue[nextIdx].id;
        if (id.startsWith('yt_')) return id.substring(3);
      }
    }
    return null;
  }

  /// Forget the pre-warmed track so the newly playing song's successor gets
  /// warmed even if it was warmed for an earlier song.
  void _resetPrewarmForNewTrack() {
    _prewarmingVideoId = null;
    _prewarmTimer?.cancel();
    _relatedEnsuredForCurrentTrack = false;
  }

  /// Play a [Song] object (local file or remote stream).
  Future<void> playSong(
    Song song, {
    List<Song>? contextQueue,
    List<PlaylistItem>? mixedContextQueue,
    Function(String error)? onError,
  }) async {
    _lastError = null;
    final youtubeVideoId = YouTubeAudioService.extractVideoId(song);
    if (YouTubeAudioService.isYouTubeSong(song) &&
        youtubeVideoId != null &&
        (!YouTubeMusicResult.isUsableTitle(song.title) ||
            !YouTubeMusicResult.isUsableTitle(song.artist))) {
      final mixedVideo = mixedContextQueue
          ?.where(
            (item) => item.isYouTube && item.youtubeVideoId == youtubeVideoId,
          )
          .firstOrNull
          ?.resolveYouTube();
      final queuedVideo = _ytQueue
          .where((item) => item.videoId == youtubeVideoId)
          .firstOrNull;
      final songVideo = YouTubeMusicResult(
        videoId: youtubeVideoId,
        title: song.title,
        channelTitle: song.artist,
        thumbnailUrl: song.artworkUrl ?? '',
        youtubeUrl:
            song.sourceUrl ?? 'https://www.youtube.com/watch?v=$youtubeVideoId',
        durationSeconds: song.duration > 0 ? song.duration : null,
      );
      final selectedVideo = mixedVideo?.hasUsableTitle == true
          ? mixedVideo!
          : YouTubeMusicResult.isUsableTitle(song.title)
          ? songVideo
          : mixedVideo ?? queuedVideo ?? songVideo;
      var playlistItems =
          mixedContextQueue ??
          contextQueue?.asMap().entries.map((entry) {
            final queuedSong = entry.value;
            final videoId = YouTubeAudioService.extractVideoId(queuedSong);
            if (videoId == null) {
              return PlaylistItem.fromSong(
                playlistId: '',
                song: queuedSong,
                position: entry.key,
              );
            }
            return PlaylistItem.fromYouTube(
              playlistId: '',
              video: YouTubeMusicResult(
                videoId: videoId,
                title: queuedSong.title,
                channelTitle: queuedSong.artist,
                thumbnailUrl: queuedSong.artworkUrl ?? '',
                youtubeUrl:
                    queuedSong.sourceUrl ??
                    'https://www.youtube.com/watch?v=$videoId',
                durationSeconds: queuedSong.duration > 0
                    ? queuedSong.duration
                    : null,
              ),
              position: entry.key,
            );
          }).toList();
      if (playlistItems != null &&
          !playlistItems.any(
            (item) => item.isYouTube && item.youtubeVideoId == youtubeVideoId,
          )) {
        playlistItems = [
          PlaylistItem.fromYouTube(
            playlistId: '',
            video: selectedVideo,
            position: 0,
          ),
          ...playlistItems.map(
            (item) => item.copyWith(position: item.position + 1),
          ),
        ];
      }

      await playYouTubeAudio(
        selectedVideo,
        mixedContextQueue: playlistItems,
        onError: onError,
      );
      return;
    }

    // A new song is starting, so its successor needs warming even if the
    // previous song already warmed that track.
    _resetPrewarmForNewTrack();

    // Check offline mode
    final isOfflineMode = await _settingsDao.getOfflineMode();
    final hasValidLocalFile =
        song.localPath != null && await File(song.localPath!).exists();

    if (isOfflineMode && !hasValidLocalFile) {
      final msg =
          'Offline mode is active. Only downloaded songs can be played.';
      _lastError = msg;
      onError?.call(msg);
      notifyListeners();
      return;
    }

    if (mixedContextQueue != null && mixedContextQueue.isNotEmpty) {
      _mixedQueue = List.from(mixedContextQueue);
      // Finish the selected collection in order, then continue with related.
      _allowRelatedExtension = true;
      // Keep navigation indexed against the complete playlist, including
      // YouTube items. The resolver turns a YouTube playlist item into a Song
      // for playback, so matching only authorized items inserted a duplicate
      // at the front and made Next replay the first track.
      final resolvedVideoId = YouTubeAudioService.isYouTubeSong(song)
          ? YouTubeAudioService.extractVideoId(song)
          : null;
      _currentIndex = _mixedQueue.indexWhere((item) {
        if (item.isAuthorized) {
          return item.songId == song.id || item.sourceId == song.id;
        }
        return resolvedVideoId != null &&
            (item.youtubeVideoId == resolvedVideoId ||
                item.sourceId == resolvedVideoId);
      });
      if (_currentIndex == -1) {
        _mixedQueue.insert(
          0,
          PlaylistItem.fromSong(playlistId: '', song: song, position: 0),
        );
        _currentIndex = 0;
      }
      // In mixed playlists, _currentIndex addresses _mixedQueue. Leaving a
      // YouTube-only side queue populated would make Next/Previous skip saved
      // authorized songs and interpret the shared index in the wrong list.
      _ytQueue = [];
      _queue = mixedContextQueue
          .where((item) => item.isAuthorized && item.songId != null)
          .map(
            (item) => Song(
              id: item.songId!,
              title: item.title,
              artist: item.artistChannel ?? '',
              artworkUrl: item.artworkUrl,
              streamUrl: '',
              duration: 0,
            ),
          )
          .toList();
    } else if (contextQueue != null && contextQueue.isNotEmpty) {
      _queue = List.from(contextQueue);
      _currentIndex = _queue.indexWhere((s) => s.id == song.id);
      if (_currentIndex == -1) {
        _queue.insert(0, song);
        _currentIndex = 0;
      }
      _ytQueue = [];
      _allowRelatedExtension = true;
      _mixedQueue = _queue.asMap().entries.map((entry) {
        final queuedSong = entry.value;
        final videoId = YouTubeAudioService.extractVideoId(queuedSong);
        if (videoId != null) {
          return PlaylistItem.fromYouTube(
            playlistId: '',
            video: YouTubeMusicResult(
              videoId: videoId,
              title: queuedSong.title,
              channelTitle: queuedSong.artist,
              thumbnailUrl: queuedSong.artworkUrl ?? '',
              youtubeUrl:
                  queuedSong.sourceUrl ??
                  'https://www.youtube.com/watch?v=$videoId',
              durationSeconds: queuedSong.duration > 0
                  ? queuedSong.duration
                  : null,
            ),
            position: entry.key,
          );
        }
        return PlaylistItem.fromSong(
          playlistId: '',
          song: queuedSong,
          position: entry.key,
        );
      }).toList();
    } else if (!_queue.any((s) => s.id == song.id)) {
      // A standalone authorized-song tap starts a fresh discovery queue. Do
      // not append it to a stale playlist from an earlier screen.
      _queue = [song];
      _ytQueue = [];
      _mixedQueue = [
        PlaylistItem.fromSong(playlistId: '', song: song, position: 0),
      ];
      _allowRelatedExtension = true;
      _currentIndex = 0;
    } else {
      _currentIndex = _queue.indexWhere((s) => s.id == song.id);
    }

    _currentSong = song;
    final resolvedVideoId = YouTubeAudioService.extractVideoId(song);
    if (resolvedVideoId == null) {
      _currentYouTubeVideo = null;
    } else {
      PlaylistItem? activePlaylistItem;
      for (final item in _mixedQueue) {
        if (!item.isAuthorized &&
            (item.youtubeVideoId == resolvedVideoId ||
                item.sourceId == resolvedVideoId)) {
          activePlaylistItem = item;
          break;
        }
      }
      if (activePlaylistItem != null) {
        _currentYouTubeVideo = YouTubeMusicResult(
          videoId: resolvedVideoId,
          title: activePlaylistItem.title,
          channelTitle: activePlaylistItem.artistChannel ?? song.artist,
          thumbnailUrl: activePlaylistItem.artworkUrl ?? song.artworkUrl ?? '',
          youtubeUrl: 'https://www.youtube.com/watch?v=$resolvedVideoId',
        );
      } else if (_currentYouTubeVideo?.videoId != resolvedVideoId) {
        final queuedVideo = _ytQueue
            .where((video) => video.videoId == resolvedVideoId)
            .firstOrNull;
        _currentYouTubeVideo =
            queuedVideo ??
            YouTubeMusicResult(
              videoId: resolvedVideoId,
              title: song.title,
              channelTitle: song.artist,
              thumbnailUrl: song.artworkUrl ?? '',
              youtubeUrl:
                  song.sourceUrl ??
                  'https://www.youtube.com/watch?v=$resolvedVideoId',
            );
      }
    }
    _currentPosition = Duration.zero;
    _totalDuration = Duration(seconds: song.duration > 0 ? song.duration : 180);
    notifyListeners();

    try {
      if (_audioHandler != null) {
        await _audioHandler!.playSongItem(song);
      }
      await LibraryService().addRecentlyPlayed(song);
      await _persistPlaybackSnapshot();
      if (YouTubeAudioService.isYouTubeSong(song)) {
        final videoId = YouTubeAudioService.extractVideoId(song);
        if (videoId != null) {
          _fetchAndQueueRelatedSongsForSong(videoId, song.title, song.artist);
        }
      }
      // Resolve the next track's stream now, while this one plays, so pressing
      // Next loads instantly instead of paying the resolve on the press.
      _prewarmNextTrack();
    } catch (e, st) {
      debugPrint('PlayerService: playSongItem failed: $e\n$st');
      // Retry with fresh stream URL — rotate through clients on each attempt
      final videoId = YouTubeAudioService.extractVideoId(song);
      if (videoId != null) {
        bool recovered = false;
        for (int attempt = 1; attempt <= 3; attempt++) {
          try {
            debugPrint('PlayerService: Retry $attempt/3 for $videoId');
            _youtubeAudioService.invalidateCache(videoId);
            final resolved = await _youtubeAudioService.resolveStream(
              videoId,
              forceRefresh: true, // rotates to next YouTube client each call
            );
            if (resolved != null &&
                resolved.url.isNotEmpty &&
                _audioHandler != null) {
              final refreshedSong = song.copyWith(
                streamUrl: resolved.url,
                headers: resolved.headers,
              );
              _currentSong = refreshedSong;
              notifyListeners();
              await _audioHandler!.player.stop();
              await _audioHandler!.playSongItem(refreshedSong);
              await LibraryService().addRecentlyPlayed(refreshedSong);
              recovered = true;
              break;
            }
          } catch (retryError) {
            debugPrint('PlayerService: Retry $attempt failed: $retryError');
            if (attempt == 3) break;
            await Future.delayed(const Duration(milliseconds: 800));
          }
        }
        if (recovered) return;
      }

      const err =
          'Unable to play this audio stream. Check your connection or try another song.';
      _lastError = err;
      onError?.call(err);
      notifyListeners();
    }
  }

  /// Play a YouTube video as native background audio (just_audio + AudioService).
  ///
  /// FIX: contextQueue is now stored in _ytQueue so next()/previous() can
  /// navigate YouTube videos directly without going through the resolver.
  /// FIX: Stops the player before setting a new audio source to clear any
  /// AAC decoder error state from a previous track (e.g., 403/buffering issues).
  Future<YouTubeMusicResult?> _recoverYouTubeMetadata(
    YouTubeMusicResult video, {
    Song? storedSong,
  }) async {
    final videoId = video.videoId;
    final playlistItem = _mixedQueue
        .where((item) => item.isYouTube && item.youtubeVideoId == videoId)
        .firstOrNull;
    final queuedVideo = _ytQueue
        .where((item) => item.videoId == videoId)
        .firstOrNull;
    final recentSong = LibraryService().recentlyPlayed
        .where((song) => song.id == 'yt_$videoId')
        .firstOrNull;
    final cachedEntry = await _musicCacheDao.getCacheEntry(
      CachedSourceType.youtube,
      videoId,
    );
    final songWithMetadata = [storedSong, recentSong]
        .whereType<Song>()
        .where(
          (song) =>
              YouTubeMusicResult.isUsableTitle(song.title) ||
              YouTubeMusicResult.isUsableTitle(song.artist),
        )
        .firstOrNull;

    var title = YouTubeMusicResult.isUsableTitle(video.title)
        ? video.title.trim()
        : '';
    if (title.isEmpty &&
        YouTubeMusicResult.isUsableTitle(songWithMetadata?.title)) {
      title = songWithMetadata!.title.trim();
    }
    if (title.isEmpty &&
        YouTubeMusicResult.isUsableTitle(playlistItem?.title)) {
      title = playlistItem!.title.trim();
    }
    if (title.isEmpty && YouTubeMusicResult.isUsableTitle(queuedVideo?.title)) {
      title = queuedVideo!.title.trim();
    }
    if (title.isEmpty && YouTubeMusicResult.isUsableTitle(cachedEntry?.title)) {
      title = cachedEntry!.title.trim();
    }

    YouTubeMusicResult? canonicalDetails;
    if (title.isEmpty) {
      try {
        canonicalDetails = await _ytApiService
            .getVideoDetails(videoId)
            .timeout(const Duration(seconds: 8));
        if (YouTubeMusicResult.isUsableTitle(canonicalDetails?.title)) {
          title = canonicalDetails!.title.trim();
        }
      } catch (error) {
        debugPrint(
          'PlayerService: could not recover title for $videoId: $error',
        );
      }
    }
    if (!YouTubeMusicResult.isUsableTitle(title)) return null;

    String? firstUsableArtist(Iterable<String?> values) {
      for (final value in values) {
        if (YouTubeMusicResult.isUsableTitle(value)) return value!.trim();
      }
      return null;
    }

    final artist =
        firstUsableArtist([
          video.channelTitle,
          songWithMetadata?.artist,
          playlistItem?.artistChannel,
          queuedVideo?.channelTitle,
          cachedEntry?.artist,
          canonicalDetails?.channelTitle,
        ]) ??
        'YouTube';
    final enriched = video.copyWith(
      title: title,
      channelTitle: artist,
      thumbnailUrl: video.thumbnailUrl.isNotEmpty
          ? video.thumbnailUrl
          : (songWithMetadata?.artworkUrl ??
                cachedEntry?.thumbnailUrl ??
                canonicalDetails?.thumbnailUrl ??
                ''),
      durationSeconds:
          video.durationSeconds ??
          canonicalDetails?.durationSeconds ??
          (songWithMetadata != null && songWithMetadata.duration > 0
              ? songWithMetadata.duration
              : null),
    );

    _ytQueue = _ytQueue
        .map((item) => item.videoId == videoId ? enriched : item)
        .toList();
    _mixedQueue = _mixedQueue
        .map(
          (item) => item.isYouTube && item.youtubeVideoId == videoId
              ? item.copyWith(
                  title: enriched.title,
                  artistChannel: enriched.channelTitle,
                  artworkUrl: enriched.thumbnailUrl,
                )
              : item,
        )
        .toList();
    return enriched;
  }

  Future<void> playYouTubeAudio(
    YouTubeMusicResult video, {
    List<YouTubeMusicResult>? contextQueue,
    List<PlaylistItem>? mixedContextQueue,
    Duration? startAt,
    Function(String error)? onError,
    bool stopPlayerFirst = true,
    bool allowRelatedExtension = true,
  }) async {
    _lastError = null;

    // Stop any previous playback to clear decoder error state. Skipped during
    // queue navigation: stopping here briefly flips `playing` to false, which
    // drops the media foreground service and can stall track advancement once
    // the app is backgrounded.
    if (stopPlayerFirst) {
      try {
        if (_audioHandler != null) {
          await _audioHandler!.player.stop();
        }
      } catch (e) {
        debugPrint('PlayerService: stop before playYouTubeAudio failed: $e');
      }
    }

    _isBuffering = true;
    // Reset prewarm state for the new song so its next track gets pre-warmed
    _resetPrewarmForNewTrack();
    notifyListeners();

    // Store YouTube context queue for next/previous navigation
    if (contextQueue != null && contextQueue.isNotEmpty) {
      _ytQueue = List.from(contextQueue);
      // Liked Songs and other saved collections pass false: they are finite, so
      // they must not be grown with related tracks.
      _allowRelatedExtension = allowRelatedExtension;
      _currentIndex = _ytQueue.indexWhere((v) => v.videoId == video.videoId);
      if (_currentIndex == -1) {
        _ytQueue.insert(0, video);
        _currentIndex = 0;
      }
      // Build PlaylistItem mixed queue from YouTube context
      _mixedQueue = _ytQueue.asMap().entries.map((entry) {
        return PlaylistItem.fromYouTube(
          playlistId: '',
          video: entry.value,
          position: entry.key,
        );
      }).toList();
    } else if (mixedContextQueue != null && mixedContextQueue.isNotEmpty) {
      _mixedQueue = List.from(mixedContextQueue);
      // Finish the selected collection in order, then continue with related.
      _allowRelatedExtension = allowRelatedExtension;
      _currentIndex = _mixedQueue.indexWhere(
        (item) => item.isYouTube && item.youtubeVideoId == video.videoId,
      );
      if (_currentIndex == -1) _currentIndex = 0;
      // Navigation must use the full mixed playlist, not a YouTube-only
      // projection that skips local/authorized songs and shifts the index.
      _ytQueue = [];
    } else {
      // No queue context was supplied. Reconcile the active queue with what is
      // actually playing, so Next/Previous always continue from the song the
      // user is hearing:
      //
      //  - the pointer already sits on this track: queue navigation from
      //    _performNext/_performPrevious positioned us, so leave it alone.
      //    Checking this first matters when the queue holds the same track
      //    twice, where indexWhere would snap back to the earlier copy.
      //  - the track is elsewhere in the queue (an "Up Next" or related-song
      //    tap): move the pointer to it. Without this the pointer stayed on
      //    the old track, so Next walked the queue from the wrong place.
      //  - the track is not in the queue at all — a song opened outside any
      //    playlist: rebuild the queue around it. Keeping a stale queue here
      //    made Next advance through unrelated songs, or appear to do nothing.
      final pointerOnTrack =
          _currentIndex >= 0 &&
          _currentIndex < _ytQueue.length &&
          _ytQueue[_currentIndex].videoId == video.videoId;
      if (pointerOnTrack) {
        // Already correct.
      } else {
        final existing = _ytQueue.indexWhere((v) => v.videoId == video.videoId);
        if (existing != -1) {
          _currentIndex = existing;
        } else {
          _ytQueue = [video];
          _allowRelatedExtension = true;
          _currentIndex = 0;
          // Keep the mixed view in step so the Up Next list the UI reads does
          // not keep showing the queue we just replaced.
          _mixedQueue = [
            PlaylistItem.fromYouTube(playlistId: '', video: video, position: 0),
          ];
        }
      }
    }

    Song? song;
    try {
      final downloadedSong = await _songDao.getSongById('yt_${video.videoId}');
      final metadataVideo = await _recoverYouTubeMetadata(
        video,
        storedSong: downloadedSong,
      );
      if (metadataVideo == null) {
        _isBuffering = false;
        _isPlaying = false;
        _lastError = 'Could not verify this song title. Skipping this track.';
        await _audioHandler?.stop();
        _audioHandler?.mediaItem.add(null);
        onError?.call(_lastError!);
        notifyListeners();
        return;
      }
      video = metadataVideo;
      _currentYouTubeVideo = video;
      notifyListeners();

      final downloadedPath = downloadedSong?.localPath;
      final hasDownloadedFile =
          downloadedPath != null &&
          downloadedPath.isNotEmpty &&
          await File(downloadedPath).exists();
      if (downloadedSong != null && hasDownloadedFile) {
        // Keep the YouTube queue identity for next/previous, but let the audio
        // handler select the app-private file without requesting the network.
        song = downloadedSong.copyWith(
          title: video.title,
          artist: video.channelTitle,
          artworkUrl: video.thumbnailUrl.isEmpty
              ? downloadedSong.artworkUrl
              : video.thumbnailUrl,
          duration: video.durationSeconds ?? downloadedSong.duration,
        );
      } else {
        song = await _youtubeAudioService.resolveToSong(video);
      }
      if (song == null || (song.streamUrl.isEmpty && !hasDownloadedFile)) {
        _isBuffering = false;
        const msg =
            'Unable to resolve YouTube audio. Check connection or try another song.';
        _lastError = msg;
        onError?.call(msg);
        notifyListeners();
        return;
      }

      _currentSong = song;
      _currentYouTubeVideo =
          video; // Keep video reference after playSong sets it
      _currentPosition = startAt ?? Duration.zero;
      _totalDuration = Duration(
        seconds: video.durationSeconds != null && video.durationSeconds! > 0
            ? video.durationSeconds!
            : 180,
      );
      notifyListeners();

      if (_audioHandler != null) {
        await _audioHandler!.playSongItem(song, startAt: startAt);
      }
      if (startAt != null) _pendingResumePosition = null;
      // Restore video reference (playSongItem doesn't clear it)
      _currentYouTubeVideo = video;
      _isBuffering = false;
      notifyListeners();

      await LibraryService().addRecentlyPlayed(song);
      await _persistPlaybackSnapshot();
      _fetchAndQueueRelatedSongs(video);
      // Resolve the next track's stream now, while this one plays, so pressing
      // Next loads instantly instead of paying the resolve on the press.
      _prewarmNextTrack();
    } catch (e) {
      // Navigation is serialized by _drainNavQueue. Retrying the same failed
      // source here holds that worker and makes every later notification skip
      // wait; return the failure to _performNext so it can skip this item and
      // load the next queued song instead.
      if (_navWorkerRunning) {
        // A manifest can resolve successfully but its signed CDN URL can still
        // be rejected with 403 when ExoPlayer opens it. Before skipping the
        // selected song, force one fresh extractor/yt-dlp resolution. This is
        // bounded by YouTubeAudioService's resolve budget and only runs for a
        // navigation load failure.
        try {
          debugPrint(
            'PlayerService: refreshing failed navigation source for ${video.videoId}',
          );
          _youtubeAudioService.invalidateCache(video.videoId);
          final refreshedSong = await _youtubeAudioService.resolveToSong(
            video,
            forceRefresh: true,
          );
          if (_currentYouTubeVideo?.videoId != video.videoId) return;
          if (refreshedSong != null && _audioHandler != null) {
            await _audioHandler!.player.stop();
            _currentSong = refreshedSong;
            await _audioHandler!.playSongItem(refreshedSong);
            _lastError = null;
            _isBuffering = false;
            notifyListeners();
            debugPrint(
              'PlayerService: refreshed navigation source for ${video.videoId}',
            );
            return;
          }
        } catch (retryError) {
          debugPrint(
            'PlayerService: fresh navigation source failed for '
            '${video.videoId}: $retryError',
          );
        }

        _lastError = 'Unable to load this YouTube stream: $e';
        await _markPlaybackStopped();
        return;
      }

      // Retry with fresh stream URLs — rotate through YouTube clients on each attempt
      final videoId = video.videoId;
      bool recovered = false;
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          debugPrint('PlayerService: YouTube retry $attempt/3 for $videoId');
          _youtubeAudioService.invalidateCache(videoId);
          final refreshedSong = await _youtubeAudioService.resolveToSong(
            video,
            forceRefresh:
                true, // advances to next YouTube client & gets fresh headers
          );
          if (refreshedSong != null && _audioHandler != null) {
            _currentSong = refreshedSong;
            notifyListeners();
            await _audioHandler!.player.stop();
            await _audioHandler!.playSongItem(refreshedSong);
            _isBuffering = false;
            notifyListeners();
            await LibraryService().addRecentlyPlayed(refreshedSong);
            recovered = true;
            break;
          }
        } catch (retryError) {
          debugPrint(
            'PlayerService: YouTube retry $attempt failed: $retryError',
          );
          if (attempt < 3) {
            await Future.delayed(const Duration(milliseconds: 800));
          }
        }
      }
      if (recovered) return;

      await _markPlaybackStopped();
      final msg = 'Failed to play YouTube track after 3 retries. Try again.';
      _lastError = msg;
      onError?.call(msg);
      notifyListeners();
    }
  }

  /// Make the reported playback state match reality.
  ///
  /// Called when playback could not be started. Without this the player stays
  /// stopped while `_isPlaying` and the MediaSession still claim the previous
  /// track is playing, which looks like a frozen app.
  Future<void> _markPlaybackStopped() async {
    _isPlaying = false;
    _isBuffering = false;
    try {
      await _audioHandler?.publishIdleState();
    } catch (e) {
      debugPrint('PlayerService: publishIdleState failed: $e');
    }
    notifyListeners();
  }

  /// Restore playback when the player is stalled with no source loaded.
  ///
  /// After a failed source swap the ExoPlayer platform stays deactivated:
  /// `_isPlaying` and the MediaSession still report playing, but there is no
  /// media item, the AudioTrack is stopped and no further events arrive, so
  /// nothing can ever fix it. Re-issue the current song instead.
  void _startStallWatchdog() {
    _stallWatchdog?.cancel();
    _stallWatchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_checkForStall());
    });
  }

  Future<void> _checkForStall() async {
    final handler = _audioHandler;
    final song = _currentSong;
    if (handler == null || song == null) return;

    // Only when we believe playback is running yet the player has nothing
    // loaded. A genuine user pause sets _isPlaying=false and is skipped.
    if (!_isPlaying) return;
    if (handler.player.playing) return;
    if (handler.player.processingState != ProcessingState.idle) return;

    // Back off between attempts and give up after repeated failures rather
    // than looping forever on a source that will not load.
    final last = _lastStallRecovery;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 20)) {
      return;
    }
    if (_stallRecoveries >= 3) {
      _stallRecoveries = 0;
      await _markPlaybackStopped();
      return;
    }

    _stallRecoveries++;
    _lastStallRecovery = DateTime.now();
    debugPrint(
      'PlayerService: stalled with no source, restarting "${song.title}" '
      '(attempt $_stallRecoveries/3)',
    );
    _isPlaying = false;
    _isBuffering = true;
    notifyListeners();

    try {
      await handler.playSongItem(song);
      _stallRecoveries = 0;
    } catch (e) {
      debugPrint('PlayerService: stall recovery failed: $e');
    }
    _isBuffering = false;
    notifyListeners();
  }

  /// Automatically fetch related tracks and append them to the queue for
  /// continuous play.
  Future<void> _fetchAndQueueRelatedSongs(YouTubeMusicResult video) async {
    await _fetchAndQueueRelatedSongsForSong(
      video.videoId,
      video.title,
      video.channelTitle,
    );
  }

  /// Fetch related songs by videoId, title, and artist, and add to the queue
  Future<void> _fetchAndQueueRelatedSongsForSong(
    String videoId,
    String title,
    String artist,
  ) async {
    // Fetching appends after the existing collection; it does not reorder or
    // replace saved items.
    if (!_allowRelatedExtension) return;

    // Only fetch if queue has fewer than 5 upcoming songs to avoid excessive queuing
    final remainingInQueue = _ytQueue.isNotEmpty
        ? (_ytQueue.length - (_currentIndex + 1))
        : (_mixedQueue.length - (_currentIndex + 1));
    if (remainingInQueue > 4) return;

    final added = await _extendQueueWithRelated(
      videoId: videoId,
      title: title,
      artist: artist,
      limit: 10,
      overallTimeout: _relatedFetchBackgroundBudget,
    );

    // The extension may be what created the next track — in single-video mode
    // there was nothing to warm when the song started. Warm it now so the first
    // Next press is a cache hit instead of a fresh resolve.
    if (added > 0) _prewarmNextTrack();
  }

  /// Append related tracks to the end of the YouTube queue so playback rolls on
  /// instead of stopping.
  ///
  /// [attempts] retries exist because `getRelatedTracks` depends on the
  /// Chaquopy Python bridge and YouTube's related endpoint, which intermittently
  /// rate-limit or return nothing. A single empty response used to end playback
  /// outright — most visibly in single-track mode, where reaching the end of the
  /// queue is the normal case rather than a genuine end of a playlist.
  ///
  /// Returns the number of tracks appended (0 if nothing could be fetched).
  ///
  /// [overallTimeout] caps the wall-clock time across ALL retries rather than
  /// each one. A single `getRelatedTracks` cascade can burn its whole per-call
  /// timeout, so without an overall budget `attempts` multiplies the stall.
  Future<int> _extendQueueWithRelated({
    required String videoId,
    required String title,
    required String artist,
    int limit = 10,
    int attempts = 3,
    Duration? overallTimeout,
  }) {
    // Share an in-flight lookup only when it is for the SAME song. Adopting a
    // different song's results would append unrelated tracks, and awaiting a
    // foreign fetch is how a background advance stalls and then stops outright
    // when it could have kept playing.
    final inFlight = _relatedFetchInFlight;
    if (inFlight != null && _relatedFetchVideoId == videoId) return inFlight;

    late final Future<int> future;
    future =
        _fetchRelatedIntoQueue(
          videoId: videoId,
          title: title,
          artist: artist,
          limit: limit,
          attempts: attempts,
          overallTimeout: overallTimeout,
        ).whenComplete(() {
          if (identical(_relatedFetchInFlight, future)) {
            _relatedFetchInFlight = null;
            _relatedFetchVideoId = null;
          }
        });
    _relatedFetchInFlight = future;
    _relatedFetchVideoId = videoId;
    return future;
  }

  Future<int> _fetchRelatedIntoQueue({
    required String videoId,
    required String title,
    required String artist,
    required int limit,
    required int attempts,
    Duration? overallTimeout,
  }) async {
    // Bound the total time across every retry, not just each attempt.
    final deadline = overallTimeout == null
        ? null
        : DateTime.now().add(overallTimeout);

    for (var attempt = 1; attempt <= attempts; attempt++) {
      // Stop retrying once the budget is gone: on the critical path a shorter
      // silence is far better than a long one, and the next advance will simply
      // try again.
      final remaining = deadline?.difference(DateTime.now());
      if (remaining != null && remaining <= Duration.zero) {
        debugPrint(
          'PlayerService: related fetch for $videoId gave up after '
          '$overallTimeout (attempt $attempt/$attempts)',
        );
        return 0;
      }

      try {
        debugPrint(
          'PlayerService: fetching related for "$title" by "$artist" '
          '(attempt $attempt/$attempts)',
        );
        // Never exceed what is left of the overall budget.
        final perCall =
            remaining != null && remaining < _relatedFetchCallTimeout
            ? remaining
            : _relatedFetchCallTimeout;
        final related = await _ytApiService
            .getRelatedTracks(
              videoId: videoId,
              title: title,
              artist: artist,
              limit: limit,
            )
            // Bounded: this reaches the Chaquopy Python bridge, which can stall
            // while the app is backgrounded. An unbounded wait here would leave
            // next() suspended and block every later advance.
            .timeout(perCall);

        if (related.isEmpty) {
          debugPrint(
            'PlayerService: related fetch attempt $attempt/$attempts '
            'returned nothing for $videoId',
          );
        } else {
          final isMixedQueue = _ytQueue.isEmpty && _mixedQueue.isNotEmpty;
          final existing = isMixedQueue
              ? _mixedQueue
                    .where((item) => item.isYouTube)
                    .map((item) => item.youtubeVideoId)
                    .whereType<String>()
                    .toSet()
              : (_ytQueue.map((v) => v.videoId).toSet()..add(videoId));
          final newTracks = related
              .where((v) => !existing.contains(v.videoId))
              .toList();
          if (newTracks.isNotEmpty) {
            if (!isMixedQueue) _ytQueue.addAll(newTracks);
            for (final track in newTracks) {
              _mixedQueue.add(
                PlaylistItem.fromYouTube(
                  playlistId: '',
                  video: track,
                  position: _mixedQueue.length,
                ),
              );
            }
            notifyListeners();
            debugPrint(
              'PlayerService: Added ${newTracks.length} related tracks to '
              'queue (total ${isMixedQueue ? _mixedQueue.length : _ytQueue.length})',
            );
            return newTracks.length;
          }
          debugPrint(
            'PlayerService: related fetch for $videoId returned only '
            'already-queued tracks',
          );
        }
      } catch (e) {
        debugPrint(
          'PlayerService: related fetch attempt $attempt/$attempts failed '
          'for $videoId: $e',
        );
      }

      if (attempt < attempts) {
        final backoff = Duration(milliseconds: 700 * attempt);
        // Don't sleep past the end of the budget.
        final left = deadline?.difference(DateTime.now());
        if (left != null && left <= backoff) {
          return 0;
        }
        await Future.delayed(backoff);
      }
    }
    return 0;
  }

  Future<void> togglePlayPause() async {
    if (_currentSong == null && _currentYouTubeVideo == null) return;
    if (_isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> play() => _resumeFromMediaControl();

  /// A Play press from the app, notification, lock screen, or headset should
  /// recover a failed source instead of asking just_audio to resume an empty
  /// ExoPlayer instance (which can silently remain stopped after an HTTP 403).
  Future<void> _resumeFromMediaControl() async {
    final handler = _audioHandler;
    if (handler == null) {
      _isPlaying = true;
      notifyListeners();
      return;
    }

    final video = _currentYouTubeVideo;
    if (video != null &&
        (handler.player.processingState == ProcessingState.idle ||
            _lastError != null)) {
      debugPrint(
        'PlayerService: Play requested with no active YouTube source; '
        'refreshing ${video.videoId}',
      );
      final savedResumePosition = _pendingResumePosition;
      await playYouTubeAudio(
        video,
        contextQueue: _ytQueue.isNotEmpty ? _ytQueue : null,
        mixedContextQueue: _ytQueue.isEmpty && _mixedQueue.isNotEmpty
            ? _mixedQueue
            : null,
        startAt: savedResumePosition,
        stopPlayerFirst: true,
        allowRelatedExtension: _allowRelatedExtension,
      );
      return;
    }

    final song = _currentSong;
    if (handler.player.processingState == ProcessingState.idle &&
        song != null) {
      debugPrint(
        'PlayerService: Play requested with no active source; reloading "${song.title}"',
      );
      final savedResumePosition = _pendingResumePosition;
      await handler.playSongItem(song, startAt: savedResumePosition);
      _pendingResumePosition = null;
      await _persistPlaybackSnapshot();
      return;
    }

    _lastError = null;
    await handler.resumePlayer();
  }

  Future<void> pause() async {
    if (_audioHandler != null) {
      await _audioHandler!.pause();
    } else {
      _isPlaying = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    if (_audioHandler != null) {
      await _audioHandler!.stop();
    }
    _isPlaying = false;
    _currentPosition = Duration.zero;
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    _currentPosition = position;
    if (_audioHandler != null) {
      await _audioHandler!.seek(position);
    }
    notifyListeners();
  }

  /// Skip to the next track.
  ///
  /// Safe to call from any state and any surface — including while another
  /// navigation is resolving, with the app backgrounded, or from a media
  /// button. The request is queued and always honoured; awaiting the returned
  /// future completes once this specific skip has been processed.
  Future<void> next() => _requestNavigation(next: true);

  /// Queue a navigation request and start the worker if it is idle.
  Future<void> _requestNavigation({required bool next}) {
    if (_navQueue.length >= _maxQueuedNavigation) {
      debugPrint(
        'PlayerService: navigation queue at $_maxQueuedNavigation, ignoring '
        '${next ? 'next' : 'previous'}',
      );
      return Future<void>.value();
    }
    final request = _NavRequest(next);
    _navQueue.add(request);
    debugPrint(
      'PlayerService: ${request.label} queued (${_navQueue.length} pending)',
    );
    // Not awaited: this caller's own future completes via request.completer, and
    // the worker must keep running while this caller awaits.
    unawaited(_drainNavQueue());
    return request.completer.future;
  }

  /// Process queued navigation requests strictly in order, one at a time.
  ///
  /// Consecutive requests in the same direction are coalesced into a single
  /// multi-step skip that loads only the final track. Order is still honoured
  /// and no request is dropped: a burst of five Next presses advances exactly
  /// five positions, but pays for one stream resolve instead of five. That
  /// matters because each resolve can take seconds — running them back to back
  /// is what made rapid presses look like nothing was loading.
  Future<void> _drainNavQueue() async {
    if (_navWorkerRunning) return;
    _navWorkerRunning = true;
    try {
      while (_navQueue.isNotEmpty) {
        final request = _navQueue.removeAt(0);

        // Absorb the run of same-direction requests that are already waiting
        // behind this one, so the whole burst resolves to one track change.
        var count = 1;
        final coalesced = <_NavRequest>[request];
        while (_navQueue.isNotEmpty && _navQueue.first.next == request.next) {
          coalesced.add(_navQueue.removeAt(0));
          count++;
        }

        try {
          // Log execution, not just queueing: a run of "queued (N pending)"
          // lines with no "running" line after them means the worker is stuck
          // inside a previous navigation.
          debugPrint(
            'PlayerService: running ${request.label}'
            '${count > 1 ? ' x$count' : ''}'
            ' (${coalesced.length} request(s) coalesced)',
          );
          if (request.next) {
            await _performNext(count: count);
          } else {
            await _performPrevious(count: count);
          }
          debugPrint('PlayerService: ${request.label} finished');
        } catch (error, stack) {
          // Logged rather than surfaced: a failed skip must not become an
          // unhandled async error in the UI's fire-and-forget button handlers,
          // and it must not stop the rest of the queue from draining.
          debugPrint('PlayerService: ${request.label} failed: $error\n$stack');
        }
        for (final done in coalesced) {
          if (!done.completer.isCompleted) done.completer.complete();
        }
      }
    } finally {
      _navWorkerRunning = false;
    }
  }

  /// One Next: advance a single track, skipping past unplayable ones.
  ///
  /// [count] advances the queue position [count] times but loads only the final
  /// track. A burst of presses is coalesced by the worker so that skipping ten
  /// tracks costs one stream resolve, not ten — previously each queued press
  /// ran a full sequential load, so a rapid burst appeared to hang.
  ///
  /// FIX: For YouTube queues, uses _ytQueue directly instead of going through
  /// the resolver — avoids re-resolving playlist items that may not have the
  /// full YouTubeMusicResult metadata, which caused "next not loading" bugs.
  /// Uses a loop instead of recursive next() calls to avoid navigation guards
  /// blocking navigation when a track fails to resolve.
  Future<void> _performNext({int count = 1}) async {
    // Ensure buffering state is reset before navigation
    _isBuffering = false;

    try {
      // Loop to find the next playable track, skipping unplayable ones
      // without recursive calls.
      //
      // The loop is also bounded by wall clock. Each attempt can spend up to a
      // full resolve timeout on a track that turns out to be unplayable, so 20
      // attempts could otherwise hold this navigation for many minutes — during
      // which every later skip would sit in the queue unprocessed. Giving up
      // lets the worker move on to whatever is queued next.
      final navigationDeadline = DateTime.now().add(_navigationBudget);
      var stepsToAdvance = count;
      for (int attempt = 0; attempt < 20; attempt++) {
        if (DateTime.now().isAfter(navigationDeadline)) {
          debugPrint(
            'PlayerService.next: gave up after $_navigationBudget '
            '(attempt $attempt/20), releasing navigation guard',
          );
          return;
        }
        if (_ytQueue.isNotEmpty) {
          // Walk every requested step, including steps that cross the current
          // end of a discovery queue. Related results can arrive while a burst
          // is being handled, so re-check the queue after each extension.
          var remaining = stepsToAdvance;
          while (remaining > 0) {
            if (_isShuffle && _ytQueue.length > 1) {
              final random = Random();
              int idx;
              do {
                idx = random.nextInt(_ytQueue.length);
              } while (idx == _currentIndex && _ytQueue.length > 1);
              _currentIndex = idx;
              remaining--;
              continue;
            }
            if (_currentIndex + 1 < _ytQueue.length) {
              _currentIndex++;
              remaining--;
              continue;
            }
            // Saved queues play in order first, then roll into related tracks.
            if (!_allowRelatedExtension) {
              if (_repeatMode == PlayerRepeatMode.all && _ytQueue.isNotEmpty) {
                _currentIndex = 0;
                remaining--;
                continue;
              }
              _currentIndex = 0;
              remaining--;
              continue;
            }

            final current =
                _ytQueue[_currentIndex.clamp(0, _ytQueue.length - 1)];
            final added = await _extendQueueWithRelated(
              videoId: current.videoId,
              title: current.title,
              artist: current.channelTitle,
              limit: 10,
              attempts: 2,
              overallTimeout: _relatedFetchAdvanceBudget,
            ).timeout(_relatedFetchAdvanceBudget, onTimeout: () => 0);
            if (added > 0 && _currentIndex + 1 < _ytQueue.length) {
              continue;
            }
            // Related lookup can fail or be rate-limited. Keep playback
            // moving by cycling this queue and try discovery again later.
            _currentIndex = 0;
            remaining--;
            continue;
          }

          await playYouTubeAudio(
            _ytQueue[_currentIndex],
            stopPlayerFirst: false,
          );
          // If playback failed, continue to the next track (loop continues)
          if (_lastError != null) {
            debugPrint(
              'PlayerService.next: YouTube track failed, trying next: $_lastError',
            );
            // The requested destination was unplayable. Skip it once; do not
            // replay the original burst count and jump past valid tracks.
            stepsToAdvance = 1;
            continue;
          }
          return;
        }

        final List<dynamic> effectiveQueue = _mixedQueue.isNotEmpty
            ? _mixedQueue
            : _queue;
        if (effectiveQueue.isEmpty) {
          return;
        }

        var remaining = stepsToAdvance;
        var nextIndex = _currentIndex;
        while (remaining > 0) {
          if (_isShuffle && effectiveQueue.length > 1) {
            final random = Random();
            do {
              nextIndex = random.nextInt(effectiveQueue.length);
            } while (nextIndex == _currentIndex && effectiveQueue.length > 1);
          } else if (nextIndex + 1 < effectiveQueue.length) {
            nextIndex++;
          } else {
            final current = _currentYouTubeVideo;
            if (_allowRelatedExtension && current != null) {
              await _extendQueueWithRelated(
                videoId: current.videoId,
                title: current.title,
                artist: current.channelTitle,
                limit: 10,
                attempts: 2,
                overallTimeout: _relatedFetchAdvanceBudget,
              ).timeout(_relatedFetchAdvanceBudget, onTimeout: () => 0);
            }
            // Continue from any appended recommendations; if discovery is
            // temporarily empty, loop the collection instead of going silent.
            final queueLength = _mixedQueue.isNotEmpty
                ? _mixedQueue.length
                : _queue.length;
            nextIndex = nextIndex + 1 < queueLength ? nextIndex + 1 : 0;
          }
          remaining--;
        }
        _currentIndex = nextIndex;

        final nextItem = effectiveQueue[_currentIndex];
        if (nextItem is PlaylistItem && nextItem.isAuthorized) {
          final res = await _resolver.resolvePlaylistItem(nextItem);
          if (res.song != null && res.isAvailable) {
            await playSong(res.song!, mixedContextQueue: _mixedQueue);
            return;
          }
        } else if (nextItem is PlaylistItem) {
          final res = await _resolver.resolvePlaylistItem(nextItem);
          if (res.song != null && res.isAvailable) {
            await playSong(res.song!, mixedContextQueue: _mixedQueue);
            return;
          }
        } else if (nextItem is Song) {
          await playSong(nextItem, contextQueue: _queue);
          return;
        }
        // If we reach here, this track couldn't be played — loop to next
      }
    } finally {
      _isBuffering = false;
    }
  }

  /// How far into a track Previous must be before it restarts the track
  /// instead of stepping back to the previous one. Matches the convention in
  /// mainstream players.
  static const Duration previousRestartThreshold = Duration(seconds: 3);

  /// Whether a Previous press should restart the current track rather than
  /// step back one. Public so the UI can reflect it and tests can assert it.
  bool get shouldRestartOnPrevious =>
      _currentPosition >= previousRestartThreshold;

  /// Restart the current track from the beginning, leaving the queue position
  /// untouched.
  Future<void> restartCurrent() async {
    await seek(Duration.zero);
  }

  /// Step back one track, or restart the current one when it is already playing.
  ///
  /// Past [previousRestartThreshold] this restarts immediately rather than
  /// queueing: a seek is cheap and must never be delayed behind an in-flight
  /// track change, otherwise pressing Previous during a load would step back a
  /// track instead of restarting. Below the threshold the step is queued behind
  /// any navigation already running, so it cannot race it.
  Future<void> previous() async {
    if (shouldRestartOnPrevious) {
      await restartCurrent();
      return;
    }
    await _requestNavigation(next: false);
  }

  /// Always move to the preceding queue item, even when the current track is
  /// beyond the normal Previous-button restart threshold. Swipe navigation
  /// uses this so a right swipe consistently means "previous track".
  Future<void> skipToPrevious() => _requestNavigation(next: false);

  /// One Previous: move back a single track.
  ///
  /// [count] steps back [count] positions in one go and loads only the final
  /// track, so a burst of presses costs one resolve rather than one per press.
  Future<void> _performPrevious({int count = 1}) async {
    _isBuffering = false;

    try {
      if (_ytQueue.isNotEmpty) {
        int prevIndex;
        if (count > 1) {
          // Burst: step back arithmetically, clamping at the start of the queue.
          final target = _currentIndex - count;
          prevIndex = target < 0 ? 0 : target;
        } else if (_currentIndex > 0) {
          prevIndex = _currentIndex - 1;
        } else if (_repeatMode == PlayerRepeatMode.all) {
          prevIndex = _ytQueue.length - 1;
        } else {
          _isBuffering = false;
          await seek(Duration.zero);
          return;
        }
        _currentIndex = prevIndex;

        await playYouTubeAudio(_ytQueue[_currentIndex], stopPlayerFirst: false);
        return;
      }

      final List<dynamic> effectiveQueue = _mixedQueue.isNotEmpty
          ? _mixedQueue
          : _queue;
      if (effectiveQueue.isEmpty) {
        _isBuffering = false;
        return;
      }

      int prevIndex;
      if (count > 1) {
        // Burst: step back arithmetically, wrapping to the end when it runs
        // past the start so the result matches repeated single steps.
        prevIndex = (_currentIndex - count) % effectiveQueue.length;
        if (prevIndex < 0) prevIndex += effectiveQueue.length;
      } else if (_currentIndex > 0) {
        prevIndex = _currentIndex - 1;
      } else if (_repeatMode == PlayerRepeatMode.all) {
        prevIndex = effectiveQueue.length - 1;
      } else {
        _isBuffering = false;
        await seek(Duration.zero);
        return;
      }
      _currentIndex = prevIndex;

      final prevItem = effectiveQueue[_currentIndex];
      if (prevItem is PlaylistItem && prevItem.isAuthorized) {
        final res = await _resolver.resolvePlaylistItem(prevItem);
        if (res.song != null && res.isAvailable) {
          await playSong(res.song!, mixedContextQueue: _mixedQueue);
          return;
        }
      } else if (prevItem is PlaylistItem) {
        final res = await _resolver.resolvePlaylistItem(prevItem);
        if (res.song != null && res.isAvailable) {
          await playSong(res.song!, mixedContextQueue: _mixedQueue);
          return;
        }
      } else if (prevItem is Song) {
        await playSong(prevItem, contextQueue: _queue);
        return;
      }
      // If we reach here, skip to beginning of current track
      await seek(Duration.zero);
    } finally {
      _isBuffering = false;
    }
  }

  void toggleShuffle() {
    _isShuffle = !_isShuffle;
    notifyListeners();
  }

  void cycleRepeatMode() {
    switch (_repeatMode) {
      case PlayerRepeatMode.off:
        _repeatMode = PlayerRepeatMode.all;
        break;
      case PlayerRepeatMode.all:
        _repeatMode = PlayerRepeatMode.one;
        break;
      case PlayerRepeatMode.one:
        _repeatMode = PlayerRepeatMode.off;
        break;
    }
    notifyListeners();
  }

  /// Play [songs] in random order, starting from a random track.
  ///
  /// The queue itself is permuted instead of picking a random track on every
  /// advance, so each song plays exactly once before any repeat. Because the
  /// shuffled list *is* the queue, next()/previous() walk it unchanged — no
  /// navigation logic is involved.
  ///
  /// The order stays in effect until something replaces the queue (another
  /// playlist, or a single song tapped directly).
  Future<void> shuffleAndPlay(List<Song> songs) async {
    if (songs.isEmpty) return;
    final shuffled = List<Song>.from(songs)..shuffle(Random());
    // The order is already shuffled. Leaving _isShuffle on would make next()
    // jump to a fresh random index on every advance, which can replay a track
    // before the rest of the playlist has been heard.
    _isShuffle = false;
    // The shuffled order itself determines the random first track. Starting
    // at a random offset in that order could skip the entries before the
    // offset when repeat is off, so always begin at its first item.
    await setQueue(shuffled, startIndex: 0);
  }

  /// Shuffle downloaded songs while spreading artists apart and favoring
  /// tracks that have not been played recently.
  Future<void> smartShuffleAndPlay(List<Song> songs) async {
    if (songs.isEmpty) return;
    List<Song> recent;
    try {
      recent = await _songDao.getRecentlyPlayed();
    } catch (_) {
      recent = const [];
    }
    final ordered = smartShuffleOrder(
      songs,
      recentlyPlayed: recent,
      random: Random(),
    );
    _isShuffle = false;
    await setQueue(ordered, startIndex: 0);
  }

  @visibleForTesting
  static List<Song> smartShuffleOrder(
    List<Song> songs, {
    List<Song> recentlyPlayed = const [],
    Random? random,
  }) {
    final rng = random ?? Random();
    final remaining = List<Song>.from(songs);
    final recency = <String, int>{};
    for (var index = 0; index < recentlyPlayed.length; index++) {
      recency.putIfAbsent(recentlyPlayed[index].id, () => index);
    }
    final result = <Song>[];
    while (remaining.isNotEmpty) {
      final lastArtist = result.isEmpty
          ? null
          : result.last.artist.trim().toLowerCase();
      final candidates = remaining.where((song) {
        return lastArtist == null ||
            song.artist.trim().toLowerCase() != lastArtist;
      }).toList();
      final available = candidates.isEmpty ? remaining : candidates;
      final viable = available.where((candidate) {
        final counts = <String, int>{};
        for (final song in remaining) {
          if (identical(song, candidate)) continue;
          final artist = song.artist.trim().toLowerCase();
          counts[artist] = (counts[artist] ?? 0) + 1;
        }
        final nextLength = remaining.length - 1;
        return counts.values.every((count) => count <= (nextLength + 1) ~/ 2);
      }).toList();
      final pool = viable.isEmpty ? available : viable;
      pool.sort((a, b) {
        final aRecency = recency[a.id] ?? recentlyPlayed.length + 1;
        final bRecency = recency[b.id] ?? recentlyPlayed.length + 1;
        return bRecency.compareTo(aRecency);
      });
      // Choose randomly among the least recently played few tracks to balance
      // freshness with a different order each time.
      final topCount = pool.length < 3 ? pool.length : 3;
      final selected = pool.removeAt(rng.nextInt(topCount));
      remaining.remove(selected);
      result.add(selected);
    }
    return result;
  }

  /// [shuffleAndPlay] for a playlist, which may mix authorized songs and
  /// YouTube items.
  Future<void> shuffleAndPlayPlaylist(List<PlaylistItem> items) async {
    if (items.isEmpty) return;
    final shuffled = List<PlaylistItem>.from(items)..shuffle(Random());
    _isShuffle = false;
    await setMixedQueue(
      shuffled,
      // The order is randomized above; start at its beginning so every saved
      // playlist item is reachable before finite-queue playback ends.
      startIndex: 0,
    );
  }

  Future<void> setQueue(List<Song> songs, {int startIndex = 0}) async {
    if (songs.isEmpty) return;
    _queue = List.from(songs);
    _ytQueue = [];
    // Preserve saved order first, then continue with related discoveries.
    _allowRelatedExtension = true;
    _mixedQueue = songs
        .map(
          (s) => PlaylistItem.fromSong(
            playlistId: '',
            song: s,
            position: songs.indexOf(s),
          ),
        )
        .toList();
    _currentIndex = startIndex.clamp(0, songs.length - 1);
    await playSong(_queue[_currentIndex]);
  }

  Future<void> setMixedQueue(
    List<PlaylistItem> items, {
    int startIndex = 0,
  }) async {
    if (items.isEmpty) return;
    _mixedQueue = List.from(items);
    _ytQueue = [];
    // Preserve playlist order first, then continue with related discoveries.
    _allowRelatedExtension = true;
    _queue = items
        .where((item) => item.isAuthorized && item.songId != null)
        .map(
          (item) => Song(
            id: item.songId!,
            title: item.title,
            artist: item.artistChannel ?? '',
            artworkUrl: item.artworkUrl,
            streamUrl: '',
            duration: 0,
          ),
        )
        .toList();
    _currentIndex = startIndex.clamp(0, items.length - 1);

    final firstItem = items[_currentIndex];
    final res = await _resolver.resolvePlaylistItem(firstItem);
    if (res.song != null && res.isAvailable) {
      await playSong(res.song!, mixedContextQueue: _mixedQueue);
    } else {
      // If the first item couldn't be resolved, try the next item iteratively
      for (int attempt = 1; attempt < items.length; attempt++) {
        _currentIndex = attempt;
        final res = await _resolver.resolvePlaylistItem(items[_currentIndex]);
        if (res.song != null && res.isAvailable) {
          await playSong(res.song!, mixedContextQueue: _mixedQueue);
          return;
        }
      }
    }
  }

  void clearQueue() {
    _queue.clear();
    _mixedQueue.clear();
    _ytQueue.clear();
    // Back to the default discovery behaviour for whatever plays next.
    _allowRelatedExtension = true;
    _currentIndex = -1;
    _currentSong = null;
    _currentYouTubeVideo = null;
    stop();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _bufferedSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _sleepTimerTicker?.cancel();
    _stallWatchdog?.cancel();
    _stallWatchdog = null;
    super.dispose();
  }
}

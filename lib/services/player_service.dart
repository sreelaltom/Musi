import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/song.dart';
import '../models/playlist_item.dart';
import '../models/youtube_music_result.dart';
import '../database/song_dao.dart';
import '../database/settings_dao.dart';
import '../services/audio_handler.dart';
import '../services/music_item_resolver.dart';
import '../services/youtube_audio_service.dart';

enum PlayerRepeatMode { off, all, one }

class PlayerService extends ChangeNotifier {
  static final PlayerService _instance = PlayerService._internal();
  factory PlayerService() => _instance;
  PlayerService._internal();

  MusiAudioHandler? _audioHandler;
  final SongDao _songDao = SongDao();
  final SettingsDao _settingsDao = SettingsDao();
  final MusicItemResolver _resolver = MusicItemResolver();
  final YouTubeAudioService _youtubeAudioService = YouTubeAudioService();

  Song? _currentSong;
  YouTubeMusicResult? _currentYouTubeVideo;
  bool _isPlaying = false;
  bool _isBuffering = false;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  Duration _bufferedPosition = Duration.zero;

  // _ytQueue stores the ordered YouTube videos for next/prev navigation
  List<YouTubeMusicResult> _ytQueue = [];
  List<Song> _queue = [];
  List<PlaylistItem> _mixedQueue = [];
  int _currentIndex = -1;
  bool _isShuffle = false;
  PlayerRepeatMode _repeatMode = PlayerRepeatMode.off;
  String? _lastError;

  // Guards against concurrent next() calls
  bool _isNavigating = false;

  // Stream subscriptions
  StreamSubscription? _posSub;
  StreamSubscription? _bufferedSub;
  StreamSubscription? _durSub;
  StreamSubscription? _stateSub;

  Song? get currentSong => _currentSong;
  YouTubeMusicResult? get currentYouTubeVideo => _currentYouTubeVideo;
  bool get isPlaying => _isPlaying;
  bool get isBuffering => _isBuffering;
  Duration get currentPosition => _currentPosition;
  Duration get totalDuration => _totalDuration;
  Duration get bufferedPosition => _bufferedPosition;
  List<Song> get queue => List.unmodifiable(_queue);
  List<PlaylistItem> get mixedQueue => List.unmodifiable(_mixedQueue);
  int get currentIndex => _currentIndex;
  bool get isShuffle => _isShuffle;
  PlayerRepeatMode get repeatMode => _repeatMode;
  bool get hasCurrentSong => _currentSong != null;
  bool get hasCurrentYouTubeVideo => _currentYouTubeVideo != null;
  String? get lastError => _lastError;
  bool get isPlayingYouTube => _currentYouTubeVideo != null;

  void init(MusiAudioHandler handler) {
    _audioHandler = handler;

    // Connect skip callbacks from Android media notification to PlayerService
    _audioHandler!.onSkipToNext = () async => next();
    _audioHandler!.onSkipToPrevious = () async => previous();

    final player = _audioHandler!.player;

    _posSub?.cancel();
    _posSub = player.positionStream.listen((pos) {
      _currentPosition = pos;
      notifyListeners();
    });

    _bufferedSub?.cancel();
    _bufferedSub = player.bufferedPositionStream.listen((buf) {
      _bufferedPosition = buf;
      notifyListeners();
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
  }

  void _handleSongCompletion() {
    switch (_repeatMode) {
      case PlayerRepeatMode.one:
        seek(Duration.zero);
        play();
        break;
      case PlayerRepeatMode.all:
        next();
        break;
      case PlayerRepeatMode.off:
        // Auto-advance if there is a next track, otherwise wrap to beginning
        final queueLen = _ytQueue.isNotEmpty
            ? _ytQueue.length
            : (_mixedQueue.isNotEmpty ? _mixedQueue.length : _queue.length);
        if (queueLen > 0) {
          // Always advance — wraps to first song at end of queue
          next();
        } else {
          pause();
          seek(Duration.zero);
        }
        break;
    }
  }

  /// Play a [Song] object (local file or remote stream).
  Future<void> playSong(
    Song song, {
    List<Song>? contextQueue,
    List<PlaylistItem>? mixedContextQueue,
    Function(String error)? onError,
  }) async {
    _lastError = null;

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
      _currentIndex = _mixedQueue.indexWhere(
        (item) => item.isAuthorized && item.songId == song.id,
      );
      if (_currentIndex == -1) {
        _mixedQueue.insert(
          0,
          PlaylistItem.fromSong(playlistId: '', song: song, position: 0),
        );
        _currentIndex = 0;
      }
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
    } else if (!_queue.any((s) => s.id == song.id)) {
      _queue.add(song);
      _currentIndex = _queue.length - 1;
    } else {
      _currentIndex = _queue.indexWhere((s) => s.id == song.id);
    }

    _currentSong = song;
    _currentPosition = Duration.zero;
    _totalDuration = Duration(seconds: song.duration > 0 ? song.duration : 180);
    notifyListeners();

    try {
      if (_audioHandler != null) {
        await _audioHandler!.playSongItem(song);
      }
      await _songDao.addRecentlyPlayed(song);
    } catch (e, st) {
      debugPrint('PlayerService: playSongItem failed: $e\n$st');
      // Retry with a freshly resolved stream URL for YouTube songs
      final videoId = YouTubeAudioService.extractVideoId(song);
      if (videoId != null) {
        try {
          debugPrint('PlayerService: Retrying fresh stream for $videoId');
            _youtubeAudioService.invalidateCache(videoId);
          final freshUrl = await _youtubeAudioService.getAudioStreamUrl(
            videoId,
            forceRefresh: true,
          );
          if (freshUrl != null && freshUrl.isNotEmpty && _audioHandler != null) {
            final refreshedSong = song.copyWith(streamUrl: freshUrl);
            _currentSong = refreshedSong;
            notifyListeners();
            // Stop only the audio player (not the media session) to clear
            // any ExoPlayer error state before retrying with fresh URL.
            await _audioHandler!.player.stop();
            await _audioHandler!.playSongItem(refreshedSong);
            await _songDao.addRecentlyPlayed(refreshedSong);
            return;
          }
        } catch (retryError) {
          debugPrint('PlayerService: Retry failed: $retryError');
        }
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
  Future<void> playYouTubeAudio(
    YouTubeMusicResult video, {
    List<YouTubeMusicResult>? contextQueue,
    List<PlaylistItem>? mixedContextQueue,
    Function(String error)? onError,
  }) async {
    _lastError = null;

    // Stop any previous playback to clear decoder error state
    try {
      if (_audioHandler != null) {
        await _audioHandler!.player.stop();
      }
    } catch (e) {
      debugPrint('PlayerService: stop before playYouTubeAudio failed: $e');
    }

    _isBuffering = true;
    _currentYouTubeVideo = video;
    notifyListeners();

    // Store YouTube context queue for next/previous navigation
    if (contextQueue != null && contextQueue.isNotEmpty) {
      _ytQueue = List.from(contextQueue);
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
      _currentIndex = _mixedQueue.indexWhere(
        (item) => item.isYouTube && item.youtubeVideoId == video.videoId,
      );
      if (_currentIndex == -1) _currentIndex = 0;
    } else if (_ytQueue.isEmpty) {
      // Single video — no queue context
      _ytQueue = [video];
      _currentIndex = 0;
    }

    Song? song;
    try {
      song = await _youtubeAudioService.resolveToSong(video);
      if (song == null || song.streamUrl.isEmpty) {
        _isBuffering = false;
        const msg =
            'Unable to resolve YouTube audio. Check connection or try another song.';
        _lastError = msg;
        onError?.call(msg);
        notifyListeners();
        return;
      }

      _currentSong = song;
      _currentYouTubeVideo = video; // Keep video reference after playSong sets it
      _currentPosition = Duration.zero;
      _totalDuration = Duration(
        seconds: video.durationSeconds != null && video.durationSeconds! > 0
            ? video.durationSeconds!
            : 180,
      );
      notifyListeners();

      if (_audioHandler != null) {
        await _audioHandler!.playSongItem(song);
      }
      // Restore video reference (playSongItem doesn't clear it)
      _currentYouTubeVideo = video;
      _isBuffering = false;
      notifyListeners();

      await _songDao.addRecentlyPlayed(song);
    } catch (e) {
      // Retry with a freshly resolved stream URL (handles 403 from expired CDN URLs)
      final videoId = video.videoId;
      try {
        debugPrint('PlayerService: Retrying fresh stream for $videoId');
        _youtubeAudioService.invalidateCache(videoId);
        final freshUrl = await _youtubeAudioService.getAudioStreamUrl(
          videoId,
          forceRefresh: true,
        );
        if (freshUrl != null && freshUrl.isNotEmpty && song != null && _audioHandler != null) {
          final refreshedSong = song.copyWith(streamUrl: freshUrl);
          _currentSong = refreshedSong;
          notifyListeners();
          // Stop first to clear any ExoPlayer/AAC decoder error state
          await _audioHandler!.player.stop();
          await _audioHandler!.playSongItem(refreshedSong);
          _isBuffering = false;
          notifyListeners();
          await _songDao.addRecentlyPlayed(refreshedSong);
          return;
        }
      } catch (retryError) {
        debugPrint('PlayerService: Retry failed: $retryError');
      }

      _isBuffering = false;
      final msg = 'Failed to play YouTube track: $e';
      _lastError = msg;
      onError?.call(msg);
      notifyListeners();
    }
  }

  Future<void> togglePlayPause() async {
    if (_currentSong == null && _currentYouTubeVideo == null) return;
    if (_isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> play() async {
    if (_audioHandler != null) {
      await _audioHandler!.play();
    } else {
      _isPlaying = true;
      notifyListeners();
    }
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

  /// Navigate to the next track in the queue.
  ///
  /// FIX: For YouTube queues, uses _ytQueue directly instead of going through
  /// the resolver — avoids re-resolving playlist items that may not have the
  /// full YouTubeMusicResult metadata, which caused "next not loading" bugs.
  /// Uses a while loop instead of recursive next() calls to avoid
  /// _isNavigating guard blocking navigation when a track fails to resolve.
  Future<void> next() async {
    if (_isNavigating) {
      debugPrint('PlayerService.next: already navigating, skipping');
      return;
    }
    _isNavigating = true;

    // Ensure buffering state is reset before navigation
    _isBuffering = false;

    try {
      // Loop to find the next playable track, skipping unplayable ones
      // without recursive calls
      for (int attempt = 0; attempt < 20; attempt++) {
        if (_ytQueue.isNotEmpty) {
          int nextIndex;
          if (_isShuffle && _ytQueue.length > 1) {
            final random = Random();
            do {
              nextIndex = random.nextInt(_ytQueue.length);
            } while (nextIndex == _currentIndex && _ytQueue.length > 1);
          } else if (_currentIndex + 1 < _ytQueue.length) {
            nextIndex = _currentIndex + 1;
          } else {
            if (_repeatMode == PlayerRepeatMode.all) {
              nextIndex = 0;
            } else {
              _isBuffering = false;
              pause();
              _isNavigating = false;
              return;
            }
          }
          _currentIndex = nextIndex;

          // Stop any error state from the previous player
          if (_audioHandler != null) {
            await _audioHandler!.player.stop();
          }
          await playYouTubeAudio(_ytQueue[_currentIndex]);
          // If playback failed, continue to the next track (loop continues)
          if (_lastError != null) {
            debugPrint(
              'PlayerService.next: YouTube track failed, trying next: $_lastError',
            );
            continue;
          }
          return;
        }

        final List<dynamic> effectiveQueue =
            _mixedQueue.isNotEmpty ? _mixedQueue : _queue;
        if (effectiveQueue.isEmpty) {
          _isBuffering = false;
          _isNavigating = false;
          return;
        }

        int nextIndex;
        if (_isShuffle && effectiveQueue.length > 1) {
          final random = Random();
          do {
            nextIndex = random.nextInt(effectiveQueue.length);
          } while (nextIndex == _currentIndex && effectiveQueue.length > 1);
        } else if (_currentIndex + 1 < effectiveQueue.length) {
          nextIndex = _currentIndex + 1;
        } else {
          if (_repeatMode == PlayerRepeatMode.all) {
            nextIndex = 0;
          } else {
            _isBuffering = false;
            _isNavigating = false;
            return;
          }
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
      _isNavigating = false;
    }
  }

  Future<void> previous() async {
    if (_isNavigating) {
      debugPrint('PlayerService.previous: already navigating, skipping');
      return;
    }
    _isNavigating = true;
    _isBuffering = false;

    try {
      // If more than 3 seconds in, restart current song
      if (_currentPosition.inSeconds > 3) {
        await seek(Duration.zero);
        return;
      }

      if (_ytQueue.isNotEmpty) {
        int prevIndex;
        if (_currentIndex > 0) {
          prevIndex = _currentIndex - 1;
        } else if (_repeatMode == PlayerRepeatMode.all) {
          prevIndex = _ytQueue.length - 1;
        } else {
          _isBuffering = false;
          await seek(Duration.zero);
          return;
        }
        _currentIndex = prevIndex;

        if (_audioHandler != null) {
          await _audioHandler!.player.stop();
        }
        await playYouTubeAudio(_ytQueue[_currentIndex]);
        return;
      }

      final List<dynamic> effectiveQueue =
          _mixedQueue.isNotEmpty ? _mixedQueue : _queue;
      if (effectiveQueue.isEmpty) {
        _isBuffering = false;
        return;
      }

      int prevIndex;
      if (_currentIndex > 0) {
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
      _isNavigating = false;
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

  Future<void> setQueue(List<Song> songs, {int startIndex = 0}) async {
    if (songs.isEmpty) return;
    _queue = List.from(songs);
    _ytQueue = [];
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
    super.dispose();
  }
}

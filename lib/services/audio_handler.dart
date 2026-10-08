import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/song.dart';

class MusiAudioHandler extends BaseAudioHandler with SeekHandler {
  /// Most Android headset buttons report every click as the same generic
  /// media-button event. Delay its single-click action briefly so a rapid
  /// double/triple click can be interpreted as Next/Previous. Notification,
  /// lock-screen, and dedicated headset Next/Previous actions bypass this
  /// timer and remain immediate.
  static const Duration _mediaButtonMultiTapWindow = Duration(
    milliseconds: 400,
  );

  /// YouTube CDN User-Agent that matches the androidSdkless client tokens.
  /// Must be set so YouTube CDN does not block the stream request.
  static const String youtubeUserAgent =
      'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip';

  // YouTube CDN User-Agent set directly on ExoPlayer via AudioPlayer.userAgent.
  // useProxyForRequestHeaders is set to false because the local proxy mechanism
  // (used when true) fails on some OnePlus devices with Media3/ExoPlayer 1.4.1,
  // causing 403 errors. With false, headers from AudioSource.uri are passed
  // directly to DefaultHttpDataSource via buildDataSourceFactory.
  final AudioPlayer _player = AudioPlayer(
    userAgent: youtubeUserAgent,
    useProxyForRequestHeaders: false,
  );

  // Callbacks for skip actions that PlayerService will set
  Future<void> Function()? onPlay;
  Future<void> Function()? onSkipToNext;
  Future<void> Function()? onSkipToPrevious;
  Future<void> Function()? onToggleLike;
  bool Function()? onIsCurrentLiked;
  Future<void> Function()? onPreviousMediaTrack;
  Future<void> Function()? onTaskRemovedCallback;
  Future<void> Function()? onPauseCallback;
  void Function(ProcessingState state)? onPlaybackStateChanged;
  Timer? _mediaButtonTapTimer;
  int _mediaButtonTapCount = 0;
  String? _currentMediaItemId;
  bool _currentIsLiked = false;

  AudioPlayer get player => _player;

  MusiAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    // 1. Configure audio session for music playback and ducking
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    // NOTE: Do NOT call session.setActive(true) here. just_audio activates the
    // session itself inside play(), and reverts `playing` to false when that
    // activation returns false. Claiming focus eagerly at startup (with nothing
    // playing) makes the later activation fail, so a loaded track never
    // advances past 0:00.

    // Pause when headphones are unplugged
    session.becomingNoisyEventStream.listen((_) {
      pause();
    });

    // 2. Broadcast playback state changes to Android MediaSession
    _player.playbackEventStream.listen((PlaybackEvent event) {
      final playing = _player.playing;
      playbackState.add(
        playbackState.value.copyWith(
          controls: [
            MediaControl.skipToPrevious,
            _likeControl,
            if (playing) MediaControl.pause else MediaControl.play,
            MediaControl.skipToNext,
          ],
          systemActions: const {
            MediaAction.seek,
            MediaAction.seekForward,
            MediaAction.seekBackward,
          },
          androidCompactActionIndices: const [0, 1, 2],
          processingState: const {
            ProcessingState.idle: AudioProcessingState.idle,
            ProcessingState.loading: AudioProcessingState.loading,
            ProcessingState.buffering: AudioProcessingState.buffering,
            ProcessingState.ready: AudioProcessingState.ready,
            ProcessingState.completed: AudioProcessingState.completed,
          }[_player.processingState]!,
          playing: playing,
          updatePosition: _player.position,
          bufferedPosition: _player.bufferedPosition,
          speed: _player.speed,
          queueIndex: event.currentIndex,
        ),
      );

      onPlaybackStateChanged?.call(_player.processingState);
    });
  }

  /// Load and play a [Song], switching between:
  ///  - Local offline file (downloaded songs)
  ///  - YouTube stream via AudioSource.uri with User-Agent + YouTube headers
  ///    (useProxyForRequestHeaders: false passes headers directly to
  ///     DefaultHttpDataSource → no proxy dependency on OnePlus/Media3)
  ///  - Generic remote stream via AudioSource.uri
  Future<void> playSongItem(Song song, {Duration? startAt}) async {
    // Update system MediaItem for notification & lock screen
    _publishSongMetadata(song);

    try {
      if (song.localPath != null && await File(song.localPath!).exists()) {
        // Play local offline file — no network needed
        await _player.setAudioSource(AudioSource.file(song.localPath!));
      } else {
        final isYouTube =
            song.id.startsWith('yt_') || song.providerId == 'youtube';

        // Use song-specific headers if provided (e.g. matching the extractor client),
        // otherwise fall back to matching YouTube User-Agent.
        // Do NOT send browser CORS headers (Origin/Referer) to googlevideo.com CDN.
        final headers =
            song.headers ??
            (isYouTube ? const {'User-Agent': youtubeUserAgent} : null);

        await _player.setAudioSource(
          AudioSource.uri(Uri.parse(song.streamUrl), headers: headers),
        );
      }
      if (startAt != null && startAt > Duration.zero) {
        await _player.seek(startAt);
      }
      // Deliberately NOT awaited.
      //
      // just_audio's play() returns a Future that completes only when playback
      // COMPLETES, so awaiting it here blocked this call — and therefore
      // PlayerService.playYouTubeAudio, and therefore the whole navigation
      // queue — for the entire duration of the track it had just started. Every
      // Next pressed during that time could only log "queued (N pending)" and
      // never executed. It also deferred addRecentlyPlayed and the next-track
      // pre-warm until the song ended, so nothing was ever stored ahead of time.
      unawaited(
        _player.play().catchError((Object e, StackTrace st) {
          // Swallowed on purpose: this future completes when playback ends, and
          // source errors are already surfaced through playbackEventStream.
          debugPrint('MusiAudioHandler: play() completed with error: $e');
        }),
      );
    } catch (e) {
      rethrow;
    }
  }

  /// Refreshes notification and lock-screen metadata after a title is resolved.
  void updateSongMetadata(Song song) {
    if (_currentMediaItemId != null && _currentMediaItemId != song.id) return;
    _publishSongMetadata(song);
  }

  void _publishSongMetadata(Song song) {
    _currentMediaItemId = song.id;
    _currentIsLiked = onIsCurrentLiked?.call() ?? false;
    final item = MediaItem(
      id: song.id,
      album: song.album ?? 'Musi',
      title: song.title,
      artist: song.artist,
      duration: song.duration > 0 ? Duration(seconds: song.duration) : null,
      artUri: song.artworkUrl != null ? Uri.tryParse(song.artworkUrl!) : null,
      extras: {'sourceUrl': song.sourceUrl, 'isDownloaded': song.isDownloaded},
    );
    mediaItem.add(item);
    _publishLikeControlState();
  }

  MediaControl get _likeControl => MediaControl.custom(
    androidIcon: _currentIsLiked
        ? 'drawable/ic_musi_favorite_filled'
        : 'drawable/ic_musi_favorite_outline',
    label: _currentIsLiked ? 'Unlike' : 'Like',
    name: 'toggleLike',
  );

  /// Refresh the notification and lock-screen Like action when the current
  /// track changes or its saved state is toggled in the app.
  void updateLikeState(bool isLiked) {
    if (_currentIsLiked == isLiked) return;
    _currentIsLiked = isLiked;
    _publishLikeControlState();
  }

  void _publishLikeControlState() {
    final state = playbackState.value;
    playbackState.add(
      state.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          _likeControl,
          state.playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
        ],
        androidCompactActionIndices: const [0, 1, 2],
      ),
    );
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) {
    if (name == 'toggleLike') {
      final callback = onToggleLike;
      return callback == null ? Future<void>.value() : callback();
    }
    return super.customAction(name, extras);
  }

  @override
  // just_audio activates the audio session internally on play(); activating it
  // here as well makes the internal activation fail and reverts to paused.
  //
  // Also must not await: play() completes only when playback completes, so
  // awaiting it would block PlayerService.play() — and the Repeat One branch of
  // auto-advance — for the whole track.
  Future<void> play() {
    final handler = onPlay;
    if (handler != null) {
      return handler();
    }
    return resumePlayer();
  }

  /// Resume a loaded source without routing back through the PlayerService
  /// callback. PlayerService uses this only after it has checked whether a
  /// failed/idle source needs to be resolved and loaded again.
  Future<void> resumePlayer() {
    unawaited(
      _player.play().catchError((Object e, StackTrace st) {
        debugPrint('MusiAudioHandler: play() completed with error: $e');
      }),
    );
    return Future<void>.value();
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    await onPauseCallback?.call();
  }

  /// Publish a truthful non-playing state to the MediaSession.
  ///
  /// `player.stop()` deactivates the ExoPlayer platform, after which
  /// just_audio's pause()/play() early-return without emitting. If a subsequent
  /// step fails, the session is left frozen advertising "playing" while the
  /// AudioTrack is stopped — the notification and lock screen look alive but
  /// nothing progresses and no track change is possible. Pushing the state
  /// directly is the only way to unstick it.
  Future<void> publishIdleState() async {
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          _likeControl,
          MediaControl.pause,
          MediaControl.skipToNext,
        ],
        systemActions: const {},
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.idle,
        playing: false,
      ),
    );
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  /// A swipe-away from Android's recent-apps screen is an explicit app close.
  /// Stop the player and clear the MediaSession so its notification and lock
  /// screen controls do not remain after the user dismisses Musi. Pressing Home
  /// only backgrounds the Activity and does not call this lifecycle hook, so
  /// background playback controls continue to work normally.
  @override
  Future<void> onTaskRemoved() async {
    await onTaskRemovedCallback?.call();
    await stop();
    mediaItem.add(null);
    queue.add(const <MediaItem>[]);
    await super.onTaskRemoved();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  /// Android dispatches the notification, lock screen, headset button and
  /// Bluetooth controls here, and the in-app buttons call [PlayerService] the
  /// same way, so Previous/Next share one implementation across every surface.
  @override
  Future<void> skipToNext() async {
    final handler = onSkipToNext;
    if (handler == null) {
      debugPrint(
        'MusiAudioHandler: skipToNext ignored, PlayerService not attached yet',
      );
      return;
    }
    await handler();
  }

  @override
  Future<void> skipToPrevious() async {
    final handler = onSkipToPrevious;
    if (handler == null) {
      debugPrint(
        'MusiAudioHandler: skipToPrevious ignored, PlayerService not attached yet',
      );
      return;
    }
    await handler();
  }

  /// Count generic headset/Bluetooth button events while keeping explicit
  /// Next/Previous events and the visible Android transport controls immediate.
  @override
  Future<void> click([MediaButton button = MediaButton.media]) {
    if (button == MediaButton.next || button == MediaButton.previous) {
      _mediaButtonTapTimer?.cancel();
      _mediaButtonTapTimer = null;
      _mediaButtonTapCount = 0;
      return button == MediaButton.next ? skipToNext() : _previousMediaTrack();
    }

    _mediaButtonTapCount++;
    _mediaButtonTapTimer?.cancel();
    _mediaButtonTapTimer = Timer(_mediaButtonMultiTapWindow, () {
      final taps = _mediaButtonTapCount;
      _mediaButtonTapCount = 0;
      _mediaButtonTapTimer = null;
      unawaited(
        _dispatchMediaButtonTaps(taps).catchError((
          Object error,
          StackTrace st,
        ) {
          debugPrint('MusiAudioHandler: media-button action failed: $error');
        }),
      );
    });
    return Future<void>.value();
  }

  Future<void> _dispatchMediaButtonTaps(int taps) async {
    if (taps == 1) {
      if (_player.playing) {
        await pause();
      } else {
        await play();
      }
    } else if (taps == 2) {
      await skipToNext();
    } else if (taps >= 3) {
      await _previousMediaTrack();
    }
  }

  Future<void> _previousMediaTrack() {
    // A headset triple click or a dedicated hardware Previous key means move
    // to the prior track. The notification/lock-screen Previous button still
    // calls skipToPrevious(), preserving its familiar restart-current rule.
    final handler = onPreviousMediaTrack;
    return handler == null ? skipToPrevious() : handler();
  }

  Future<void> dispose() async {
    _mediaButtonTapTimer?.cancel();
    await _player.dispose();
  }
}

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/song.dart';

class MusiAudioHandler extends BaseAudioHandler with SeekHandler {
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
  Future<void> Function()? onSkipToNext;
  Future<void> Function()? onSkipToPrevious;
  void Function(ProcessingState state)? onPlaybackStateChanged;

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
            if (playing) MediaControl.pause else MediaControl.play,
            MediaControl.skipToNext,
            MediaControl.stop,
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
  Future<void> playSongItem(Song song) async {
    // Update system MediaItem for notification & lock screen
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

  @override
  // just_audio activates the audio session internally on play(); activating it
  // here as well makes the internal activation fail and reverts to paused.
  //
  // Also must not await: play() completes only when playback completes, so
  // awaiting it would block PlayerService.play() — and the Repeat One branch of
  // auto-advance — for the whole track.
  Future<void> play() {
    unawaited(
      _player.play().catchError((Object e, StackTrace st) {
        debugPrint('MusiAudioHandler: play() completed with error: $e');
      }),
    );
    return Future<void>.value();
  }

  @override
  Future<void> pause() => _player.pause();

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
        controls: const [
          MediaControl.skipToPrevious,
          MediaControl.pause,
          MediaControl.skipToNext,
        ],
        systemActions: const {},
        androidCompactActionIndices: const [],
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

  Future<void> dispose() async {
    await _player.dispose();
  }
}

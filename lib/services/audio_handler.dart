import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
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
      final headers = song.headers ??
          (isYouTube
              ? const {
                  'User-Agent': youtubeUserAgent,
                }
              : null);

      await _player.setAudioSource(
        AudioSource.uri(
          Uri.parse(song.streamUrl),
          headers: headers,
        ),
      );
    }
    await _player.play();
    } catch (e) {
      rethrow;
    }
  }

  @override
  // just_audio activates the audio session internally on play(); activating it
  // here as well makes the internal activation fail and reverts to paused.
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() async {
    if (onSkipToNext != null) {
      await onSkipToNext!();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (onSkipToPrevious != null) {
      await onSkipToPrevious!();
    }
  }

  Future<void> dispose() async {
    await _player.dispose();
  }
}

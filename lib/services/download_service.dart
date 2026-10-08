import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/song_dao.dart';
import '../models/song.dart';
import 'music_provider_manager.dart';
import 'youtube_audio_service.dart';
import 'youtube_music_api_service.dart';

class DownloadService extends ChangeNotifier {
  static final DownloadService _instance = DownloadService._internal();
  factory DownloadService() => _instance;
  DownloadService._internal()
    : _clientFactory = http.Client.new,
      _downloadsDirectoryProvider = _defaultDownloadsDirectory;

  DownloadService._testing(
    this._clientFactory,
    this._downloadsDirectoryProvider,
  );

  @visibleForTesting
  static DownloadService forTesting({
    required http.Client Function() clientFactory,
    required Future<Directory> Function() downloadsDirectoryProvider,
  }) => DownloadService._testing(clientFactory, downloadsDirectoryProvider);

  final SongDao _songDao = SongDao();
  final MusicProviderManager _providerManager = MusicProviderManager();
  final http.Client Function() _clientFactory;
  final Future<Directory> Function() _downloadsDirectoryProvider;
  final Map<String, http.Client> _clients = {};
  final Map<String, double> _progress = {};
  final Set<String> _activeDownloads = {};
  final Set<String> _knownProgressTotals = {};
  final Set<String> _cancelledDownloads = {};

  double getProgress(String songId) => _progress[songId] ?? 0.0;
  bool isDownloading(String songId) => _activeDownloads.contains(songId);
  bool hasKnownProgress(String songId) =>
      _knownProgressTotals.contains(songId);

  static Future<Directory> _defaultDownloadsDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final downloadDir = Directory(p.join(appDir.path, 'musi_downloads'));
    if (!await downloadDir.exists()) {
      await downloadDir.create(recursive: true);
    }
    return downloadDir;
  }

  Future<Directory> getDownloadsDirectory() => _downloadsDirectoryProvider();

  Future<bool> isDownloaded(Song song) async {
    final stored = await _songDao.getSongById(song.id);
    final localPath = stored?.localPath ?? song.localPath;
    if (localPath == null || localPath.isEmpty) return false;
    final file = File(localPath);
    return await file.exists() && await file.length() > 0;
  }

  bool canDownloadSong(Song song) {
    if (YouTubeAudioService.isYouTubeSong(song)) {
      return YouTubeAudioService.extractVideoId(song)?.isNotEmpty == true;
    }
    return _providerManager.canDownload(song);
  }

  Future<bool> downloadSong(
    Song song, {
    Function(String error)? onError,
  }) async {
    if (!canDownloadSong(song)) {
      onError?.call(
        'Download unavailable for this source. The provider does not permit downloading.',
      );
      return false;
    }
    if (_activeDownloads.contains(song.id)) return false;

    final stored = await _songDao.getSongById(song.id);
    final existingPath = stored?.localPath ?? song.localPath;
    if (existingPath != null && existingPath.isNotEmpty) {
      final existing = File(existingPath);
      if (await existing.exists() && await existing.length() > 0) return true;
    }

    _activeDownloads.add(song.id);
    _cancelledDownloads.remove(song.id);
    _progress[song.id] = 0;
    _knownProgressTotals.remove(song.id);
    notifyListeners();

    File? partialFile;
    IOSink? sink;
    http.Client? client;
    try {
      var audioUrl = song.streamUrl;
      var headers = Map<String, String>.from(song.headers ?? const {});

      if (YouTubeAudioService.isYouTubeSong(song)) {
        final videoId = YouTubeAudioService.extractVideoId(song);
        if (videoId == null || videoId.isEmpty) {
          throw Exception('This YouTube song has no video ID.');
        }
        // URLs returned by search/playback are short-lived. Resolve a fresh
        // audio URL at download time using yt_flutter_musicapi's fast method.
        final stream = await YouTubeMusicApiService().getStreamWithHeaders(
          videoId,
        );
        audioUrl = stream?['url'] as String? ?? '';
        final resolvedHeaders = stream?['headers'];
        if (resolvedHeaders is Map) {
          headers.addAll(
            resolvedHeaders.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            ),
          );
        }
        // The plugin's fast yt-dlp path can fail on Android builds where its
        // Python subprocess helper is unavailable. Preserve getAudioUrlFast as
        // the first choice, then retry through the same resolver used for
        // playback to obtain another fresh URL.
        if (audioUrl.isEmpty) {
          final fallback = await YouTubeAudioService().resolveStream(
            videoId,
            forceRefresh: true,
          );
          audioUrl = fallback?.url ?? '';
          if (fallback?.headers case final resolvedHeaders?) {
            headers.addAll(resolvedHeaders);
          }
        }
      }
      final uri = Uri.tryParse(audioUrl);
      if (uri == null || !uri.hasScheme || audioUrl.isEmpty) {
        throw Exception('Could not get a valid audio URL for this song.');
      }

      final request = http.Request('GET', uri)..headers.addAll(headers);
      client = _clientFactory();
      _clients[song.id] = client;
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 45));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Audio server returned ${response.statusCode}.');
      }

      final downloadDir = await getDownloadsDirectory();
      final extension = _extensionFor(response.headers['content-type'], uri);
      final fileId = YouTubeAudioService.extractVideoId(song) ?? song.id;
      final safeId = fileId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
      final target = File(p.join(downloadDir.path, '$safeId.$extension'));
      partialFile = File('${target.path}.part');
      sink = partialFile.openWrite();

      var received = 0;
      final total = response.contentLength ?? 0;
      if (total > 0) _knownProgressTotals.add(song.id);
      await for (final chunk in response.stream.timeout(
        const Duration(minutes: 3),
      )) {
        if (_cancelledDownloads.contains(song.id)) {
          throw const _DownloadCancelled();
        }
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          _progress[song.id] = (received / total).clamp(0.0, 1.0);
          notifyListeners();
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (_cancelledDownloads.contains(song.id)) {
        throw const _DownloadCancelled();
      }
      if (!await partialFile.exists() || await partialFile.length() == 0) {
        throw Exception('Downloaded audio was empty.');
      }
      if (await target.exists()) await target.delete();
      final completedFile = await partialFile.rename(target.path);
      partialFile = null;

      await _songDao.setDownloadStatus(
        song.id,
        isDownloaded: true,
        localPath: completedFile.path,
      );
      _progress[song.id] = 1;
      return true;
    } catch (error) {
      try {
        await sink?.close();
      } catch (_) {}
      if (partialFile != null && await partialFile.exists()) {
        try {
          await partialFile.delete();
        } catch (_) {}
      }
      if (error is! _DownloadCancelled &&
          !_cancelledDownloads.contains(song.id)) {
        debugPrint('DownloadService: download failed for ${song.id}: $error');
        onError?.call(
          error is TimeoutException
              ? 'Download timed out. Please try again.'
              : 'Download failed. Please check your connection and try again.',
        );
      }
      _progress.remove(song.id);
      _knownProgressTotals.remove(song.id);
      return false;
    } finally {
      client?.close();
      _clients.remove(song.id);
      _activeDownloads.remove(song.id);
      _cancelledDownloads.remove(song.id);
      notifyListeners();
    }
  }

  String _extensionFor(String? contentType, Uri uri) {
    final mimeType = contentType?.split(';').first.trim().toLowerCase();
    switch (mimeType) {
      case 'audio/mp4':
      case 'audio/x-m4a':
      case 'audio/aac':
        return 'm4a';
      case 'audio/mpeg':
        return 'mp3';
      case 'audio/webm':
      case 'audio/webm; codecs="opus"':
        return 'webm';
      case 'audio/ogg':
      case 'application/ogg':
        return 'ogg';
      case 'audio/opus':
        return 'opus';
    }

    final pathExtension = p
        .extension(uri.path)
        .replaceFirst('.', '')
        .toLowerCase();
    if (const {
      'm4a',
      'mp4',
      'mp3',
      'webm',
      'ogg',
      'opus',
      'aac',
    }.contains(pathExtension)) {
      return pathExtension == 'mp4' ? 'm4a' : pathExtension;
    }
    return 'm4a';
  }

  void cancelDownload(String songId) {
    if (!_activeDownloads.contains(songId)) return;
    _cancelledDownloads.add(songId);
    _clients[songId]?.close();
    notifyListeners();
  }

  Future<bool> deleteDownload(Song song) async {
    try {
      final stored = await _songDao.getSongById(song.id);
      final localPath = stored?.localPath ?? song.localPath;
      if (localPath != null && localPath.isNotEmpty) {
        final file = File(localPath);
        if (await file.exists()) await file.delete();

        // Interrupted downloads are written beside the final file. Clean up
        // that partial payload as well so removing a download actually frees
        // its app-private storage, even after a previous cancellation/crash.
        final partialFile = File('$localPath.part');
        if (await partialFile.exists()) await partialFile.delete();
      }
      await _songDao.setDownloadStatus(
        song.id,
        isDownloaded: false,
        localPath: null,
      );
      _progress.remove(song.id);
      _knownProgressTotals.remove(song.id);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<int> getDownloadedBytes() async {
    try {
      final dir = await getDownloadsDirectory();
      var totalSize = 0;
      await for (final file in dir.list(recursive: true, followLinks: false)) {
        if (file is File && !file.path.endsWith('.part')) {
          totalSize += await file.length();
        }
      }
      return totalSize;
    } catch (_) {
      return 0;
    }
  }
}

class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}

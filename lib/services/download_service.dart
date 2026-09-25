import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../models/song.dart';
import '../database/song_dao.dart';
import '../services/music_provider_manager.dart';

class DownloadService extends ChangeNotifier {
  static final DownloadService _instance = DownloadService._internal();
  factory DownloadService() => _instance;
  DownloadService._internal();

  final Dio _dio = Dio();
  final SongDao _songDao = SongDao();
  final MusicProviderManager _providerManager = MusicProviderManager();
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, double> _progress = {}; // 0.0 to 1.0
  final Set<String> _activeDownloads = {};

  double getProgress(String songId) => _progress[songId] ?? 0.0;
  bool isDownloading(String songId) => _activeDownloads.contains(songId);

  // Get application-private downloads directory
  Future<Directory> getDownloadsDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final downloadDir = Directory(p.join(appDir.path, 'musi_downloads'));
    if (!await downloadDir.exists()) {
      await downloadDir.create(recursive: true);
    }
    return downloadDir;
  }

  // Check if a song's local file actually exists on disk
  Future<bool> isDownloaded(Song song) async {
    if (song.localPath == null || song.localPath!.isEmpty) return false;
    final file = File(song.localPath!);
    return await file.exists();
  }

  // Check if download is permitted for this song
  bool canDownloadSong(Song song) {
    return _providerManager.canDownload(song);
  }

  // Download a song
  Future<bool> downloadSong(
    Song song, {
    Function(String error)? onError,
  }) async {
    // Check if download is permitted
    if (!canDownloadSong(song)) {
      onError?.call(
        'Download unavailable for this source. The provider does not permit downloading.',
      );
      return false;
    }

    if (_activeDownloads.contains(song.id)) return false;

    // Check if already downloaded
    if (await isDownloaded(song)) {
      return true;
    }

    final downloadDir = await getDownloadsDirectory();
    // Sanitize filename
    final safeId = song.id.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    final filePath = p.join(downloadDir.path, '$safeId.mp3');
    final targetFile = File(filePath);

    final cancelToken = CancelToken();
    _cancelTokens[song.id] = cancelToken;
    _activeDownloads.add(song.id);
    _progress[song.id] = 0.0;
    notifyListeners();

    try {
      await _dio.download(
        song.streamUrl,
        filePath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            _progress[song.id] = (received / total).clamp(0.0, 1.0);
            notifyListeners();
          }
        },
      );

      // Verify downloaded file exists and is not empty
      if (await targetFile.exists() && await targetFile.length() > 0) {
        // Update database
        await _songDao.setDownloadStatus(
          song.id,
          isDownloaded: true,
          localPath: filePath,
        );

        _activeDownloads.remove(song.id);
        _cancelTokens.remove(song.id);
        _progress[song.id] = 1.0;
        notifyListeners();
        return true;
      } else {
        throw Exception('Downloaded file was empty or corrupted');
      }
    } catch (e) {
      // Clean up incomplete file
      if (await targetFile.exists()) {
        try {
          await targetFile.delete();
        } catch (_) {}
      }

      _activeDownloads.remove(song.id);
      _cancelTokens.remove(song.id);
      _progress.remove(song.id);
      notifyListeners();

      if (e is DioException && CancelToken.isCancel(e)) {
        // Download was cancelled by user
        return false;
      }

      onError?.call(
        'Download failed. Please check your network and try again.',
      );
      return false;
    }
  }

  // Cancel ongoing download
  void cancelDownload(String songId) {
    if (_cancelTokens.containsKey(songId)) {
      _cancelTokens[songId]?.cancel();
      _cancelTokens.remove(songId);
      _activeDownloads.remove(songId);
      _progress.remove(songId);
      notifyListeners();
    }
  }

  // Delete downloaded song
  Future<bool> deleteDownload(Song song) async {
    try {
      if (song.localPath != null && song.localPath!.isNotEmpty) {
        final file = File(song.localPath!);
        if (await file.exists()) {
          await file.delete();
        }
      }

      await _songDao.setDownloadStatus(
        song.id,
        isDownloaded: false,
        localPath: null,
      );

      _progress.remove(song.id);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  // Total size of downloaded music in bytes
  Future<int> getDownloadedBytes() async {
    try {
      final dir = await getDownloadsDirectory();
      int totalSize = 0;
      await for (final file in dir.list(recursive: true, followLinks: false)) {
        if (file is File) {
          totalSize += await file.length();
        }
      }
      return totalSize;
    } catch (_) {
      return 0;
    }
  }
}

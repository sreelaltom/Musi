import 'package:flutter/foundation.dart';

import '../models/song.dart';
import '../models/playlist.dart';
import '../models/playlist_item.dart';
import '../models/youtube_music_result.dart';
import '../database/song_dao.dart';
import '../database/playlist_dao.dart';
import '../database/youtube_likes_dao.dart';
import 'download_service.dart';
import 'music_item_resolver.dart';

class LibraryService extends ChangeNotifier {
  static final LibraryService _instance = LibraryService._internal();
  factory LibraryService() => _instance;
  LibraryService._internal();

  final SongDao _songDao = SongDao();
  final PlaylistDao _playlistDao = PlaylistDao();
  final YouTubeLikesDao _youtubeLikesDao = YouTubeLikesDao();
  final DownloadService _downloadService = DownloadService();
  final MusicItemResolver _resolver = MusicItemResolver();

  final Set<String> _likedSongIds = {};
  final Set<String> _downloadedSongIds = {};
  final Set<String> _likedYouTubeVideoIds = {};
  List<Song> _recentlyPlayed = [];
  final List<YouTubeMusicResult> _recentlyPlayedYouTube = [];
  List<Playlist> _playlists = [];
  final List<PlaylistItem> _allPlaylistItems = [];
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;
  List<Song> _likedSongs = [];
  List<Song> _downloadedSongs = [];
  List<YouTubeMusicResult> _likedYouTubeVideos = [];

  List<Song> get likedSongs => List.unmodifiable(_likedSongs);
  List<Song> get downloadedSongs => List.unmodifiable(_downloadedSongs);
  List<Song> get recentlyPlayed => List.unmodifiable(_recentlyPlayed);
  List<YouTubeMusicResult> get recentlyPlayedYouTube =>
      List.unmodifiable(_recentlyPlayedYouTube);
  List<YouTubeMusicResult> get likedYouTubeVideos =>
      List.unmodifiable(_likedYouTubeVideos);
  List<Playlist> get playlists => List.unmodifiable(_playlists);

  // Initialize and load persistent data from SQLite
  Future<void> init() async {
    try {
      // 1. Load Liked Songs
      _likedSongs = await _songDao.getLikedSongs();
      _likedSongIds.clear();
      for (final s in _likedSongs) {
        _likedSongIds.add(s.id);
      }

      // 2. Load Liked YouTube Videos
      _likedYouTubeVideos = await _youtubeLikesDao.getLikedYouTubeVideos();
      _likedYouTubeVideoIds.clear();
      for (final v in _likedYouTubeVideos) {
        _likedYouTubeVideoIds.add(v.videoId);
      }

      // 3. Load Downloads & verify files
      final dbDownloads = await _songDao.getDownloadedSongs();
      _downloadedSongs = [];
      _downloadedSongIds.clear();
      for (final s in dbDownloads) {
        if (await _downloadService.isDownloaded(s)) {
          _downloadedSongs.add(s);
          _downloadedSongIds.add(s.id);
        } else {
          // File missing or corrupted -> update database
          await _songDao.setDownloadStatus(
            s.id,
            isDownloaded: false,
            localPath: null,
          );
        }
      }

      // 4. Load Recently Played
      _recentlyPlayed = await _songDao.getRecentlyPlayed();

      // 5. Load Playlists
      _playlists = await _playlistDao.getAllPlaylists();

      // 6. Load all playlist items (songs + YouTube) and update item counts
      for (int i = 0; i < _playlists.length; i++) {
        final items = await _playlistDao.getPlaylistItems(_playlists[i].id);
        _allPlaylistItems.addAll(items);
        // Update playlist with accurate item count (includes YouTube videos)
        _playlists[i] = _playlists[i].copyWith(itemCount: items.length);
      }

      // If first launch and playlists empty, create default playlist
      if (_playlists.isEmpty) {
        final defaultPl = Playlist(
          id: 'pl-favorites',
          name: 'My Favorites',
          createdAt: DateTime.now(),
          songs: [],
        );
        await _playlistDao.createPlaylist(defaultPl);
        _playlists = [defaultPl];
      }

      _isInitialized = true;
      notifyListeners();
    } catch (_) {
      _isInitialized = true;
      notifyListeners();
    }
  }

  bool isLiked(String songId) {
    if (songId.startsWith('yt_')) {
      final videoId = songId.substring(3);
      return _likedYouTubeVideoIds.contains(videoId) ||
          _likedSongIds.contains(songId);
    }
    return _likedSongIds.contains(songId);
  }

  bool isDownloaded(String songId) => _downloadedSongIds.contains(songId);
  bool isYouTubeLiked(String videoId) =>
      _likedYouTubeVideoIds.contains(videoId);

  // Toggle Like with immediate SQLite persistence
  Future<void> toggleLike(Song song) async {
    if (song.providerId == 'youtube' || song.id.startsWith('yt_')) {
      final videoId = song.id.startsWith('yt_')
          ? song.id.substring(3)
          : song.id;
      final video = YouTubeMusicResult(
        videoId: videoId,
        title: song.title,
        channelTitle: song.artist,
        thumbnailUrl: song.artworkUrl ?? '',
        youtubeUrl:
            song.sourceUrl ?? 'https://www.youtube.com/watch?v=$videoId',
        durationSeconds: song.duration,
      );
      await toggleYouTubeLike(video);
      if (_likedYouTubeVideoIds.contains(videoId)) {
        _likedSongIds.add(song.id);
      } else {
        _likedSongIds.remove(song.id);
      }
      notifyListeners();
      return;
    }

    final willLike = !_likedSongIds.contains(song.id);
    if (willLike) {
      _likedSongIds.add(song.id);
      _likedSongs.insert(0, song.copyWith(isLiked: true));
    } else {
      _likedSongIds.remove(song.id);
      _likedSongs.removeWhere((s) => s.id == song.id);
    }
    notifyListeners();

    await _songDao.setLiked(song, willLike);
  }

  // Toggle YouTube Like
  Future<void> toggleYouTubeLike(YouTubeMusicResult video) async {
    final willLike = !_likedYouTubeVideoIds.contains(video.videoId);
    if (willLike) {
      _likedYouTubeVideoIds.add(video.videoId);
      _likedYouTubeVideos.insert(0, video);
    } else {
      _likedYouTubeVideoIds.remove(video.videoId);
      _likedYouTubeVideos.removeWhere((v) => v.videoId == video.videoId);
    }
    notifyListeners();

    if (willLike) {
      await _youtubeLikesDao.likeYouTubeVideo(video);
    } else {
      await _youtubeLikesDao.unlikeYouTubeVideo(video.videoId);
    }
  }

  // Toggle Download with real file download and verification
  Future<void> toggleDownload(Song song, {Function(String)? onError}) async {
    final alreadyDownloaded = await _downloadService.isDownloaded(song);
    if (alreadyDownloaded) {
      await _downloadService.deleteDownload(song);
      _downloadedSongIds.remove(song.id);
      _downloadedSongs.removeWhere((s) => s.id == song.id);
      notifyListeners();
    } else {
      // Upsert song metadata in database
      await _songDao.upsertSong(song);
      final success = await _downloadService.downloadSong(
        song,
        onError: onError,
      );
      if (success) {
        final updated = song.copyWith(
          isDownloaded: true,
          localPath: (await _songDao.getSongById(song.id))?.localPath,
        );
        _downloadedSongIds.add(song.id);
        _downloadedSongs.removeWhere((s) => s.id == song.id);
        _downloadedSongs.insert(0, updated);
        notifyListeners();
      }
    }
  }

  // Add to Recently Played (authorized song)
  Future<void> addRecentlyPlayed(Song song) async {
    _recentlyPlayed.removeWhere((s) => s.id == song.id);
    _recentlyPlayed.insert(0, song);
    if (_recentlyPlayed.length > 50) {
      _recentlyPlayed.removeLast();
    }
    notifyListeners();

    await _songDao.addRecentlyPlayed(song);
  }

  // Add to Recently Played (YouTube video)
  Future<void> addRecentlyPlayedYouTube(YouTubeMusicResult video) async {
    _recentlyPlayedYouTube.removeWhere((v) => v.videoId == video.videoId);
    _recentlyPlayedYouTube.insert(0, video);
    if (_recentlyPlayedYouTube.length > 50) {
      _recentlyPlayedYouTube.removeLast();
    }
    notifyListeners();

    // Update cache last_played_at
    await _resolver.resolveYouTubeVideo(video);
  }

  // Create Playlist
  Future<void> createPlaylist(String name) async {
    if (name.trim().isEmpty) return;
    final newPlaylist = Playlist(
      id: 'pl-${DateTime.now().millisecondsSinceEpoch}',
      name: name.trim(),
      createdAt: DateTime.now(),
      songs: [],
    );
    _playlists.insert(0, newPlaylist);
    notifyListeners();

    await _playlistDao.createPlaylist(newPlaylist);
  }

  // Rename Playlist
  Future<void> renamePlaylist(String playlistId, String newName) async {
    if (newName.trim().isEmpty) return;
    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index != -1) {
      _playlists[index] = _playlists[index].copyWith(name: newName.trim());
      notifyListeners();
      await _playlistDao.renamePlaylist(playlistId, newName.trim());
    }
  }

  // Delete Playlist
  Future<void> deletePlaylist(String playlistId) async {
    _playlists.removeWhere((p) => p.id == playlistId);
    _allPlaylistItems.removeWhere((item) => item.playlistId == playlistId);
    notifyListeners();
    await _playlistDao.deletePlaylist(playlistId);
  }

  // Add Song to Playlist
  Future<void> addSongToPlaylist(String playlistId, Song song) async {
    if (song.providerId == 'youtube' || song.id.startsWith('yt_')) {
      final videoId = song.id.startsWith('yt_')
          ? song.id.substring(3)
          : song.id;
      final video = YouTubeMusicResult(
        videoId: videoId,
        title: song.title,
        channelTitle: song.artist,
        thumbnailUrl: song.artworkUrl ?? '',
        youtubeUrl:
            song.sourceUrl ?? 'https://www.youtube.com/watch?v=$videoId',
        durationSeconds: song.duration,
      );
      await addYouTubeToPlaylist(playlistId, video);
      return;
    }

    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index != -1) {
      final playlist = _playlists[index];
      if (!playlist.songs.any((s) => s.id == song.id)) {
        final updatedSongs = List<Song>.from(playlist.songs)..add(song);
        // Reload items from DB to get accurate count
        await _playlistDao.addSongToPlaylist(playlistId, song);
        final items = await _playlistDao.getPlaylistItems(playlistId);
        _allPlaylistItems.removeWhere((item) => item.playlistId == playlistId);
        _allPlaylistItems.addAll(items);
        _playlists[index] = playlist.copyWith(
          songs: updatedSongs,
          itemCount: items.length,
        );
        notifyListeners();
      }
    }
  }

  // Add YouTube Video to Playlist
  Future<void> addYouTubeToPlaylist(
    String playlistId,
    YouTubeMusicResult video,
  ) async {
    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index != -1) {
      // Check if YouTube item already in playlist via items
      final existingItems = _allPlaylistItems.where(
        (item) => item.playlistId == playlistId,
      );
      if (!existingItems.any(
        (item) => item.isYouTube && item.youtubeVideoId == video.videoId,
      )) {
        await _playlistDao.addYouTubeToPlaylist(playlistId, video);
        // Reload playlist items and update itemCount in playlist
        final items = await _playlistDao.getPlaylistItems(playlistId);
        _allPlaylistItems.removeWhere((item) => item.playlistId == playlistId);
        _allPlaylistItems.addAll(items);
        _playlists[index] = _playlists[index].copyWith(itemCount: items.length);
        notifyListeners();
      }
    }
  }

  // Remove Song from Playlist
  Future<void> removeSongFromPlaylist(String playlistId, String songId) async {
    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index != -1) {
      final playlist = _playlists[index];
      final updatedSongs = playlist.songs.where((s) => s.id != songId).toList();
      _playlists[index] = playlist.copyWith(songs: updatedSongs);
      notifyListeners();
      await _playlistDao.removeSongFromPlaylist(playlistId, songId);
    }
  }

  // Remove YouTube from Playlist
  Future<void> removeYouTubeFromPlaylist(
    String playlistId,
    String videoId,
  ) async {
    notifyListeners();
    await _playlistDao.removeItemFromPlaylist(
      playlistId,
      videoId,
      PlaylistItemSourceType.youtube,
    );
    // Reload playlist items
    final items = await _playlistDao.getPlaylistItems(playlistId);
    _allPlaylistItems.removeWhere((item) => item.playlistId == playlistId);
    _allPlaylistItems.addAll(items);
  }

  // Reorder Songs in Playlist
  Future<void> reorderPlaylistSongs(
    String playlistId,
    int oldIndex,
    int newIndex,
  ) async {
    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index != -1) {
      final playlist = _playlists[index];
      final songs = List<Song>.from(playlist.songs);
      final item = songs.removeAt(oldIndex);
      final targetIndex = newIndex.clamp(0, songs.length);
      songs.insert(targetIndex, item);
      _playlists[index] = playlist.copyWith(songs: songs);
      notifyListeners();

      await _playlistDao.reorderPlaylistSongs(
        playlistId,
        songs.map((s) => s.id).toList(),
      );
    }
  }

  // Reorder playlist items (mixed Song and YouTube)
  Future<void> reorderPlaylistItems(
    String playlistId,
    List<String> orderedSourceIds,
    List<PlaylistItemSourceType> orderedSourceTypes,
  ) async {
    notifyListeners();
    await _playlistDao.reorderPlaylistItems(
      playlistId,
      orderedSourceIds,
      orderedSourceTypes,
    );
    // Reload playlist items
    final items = await _playlistDao.getPlaylistItems(playlistId);
    _allPlaylistItems.removeWhere((item) => item.playlistId == playlistId);
    _allPlaylistItems.addAll(items);
  }

  // Get playlist items including YouTube videos
  Future<List<PlaylistItem>> getPlaylistItems(String playlistId) async {
    return _playlistDao.getPlaylistItems(playlistId);
  }
}

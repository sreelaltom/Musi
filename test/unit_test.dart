import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:musi/database/song_dao.dart';
import 'package:musi/database/playlist_dao.dart';
import 'package:musi/database/settings_dao.dart';
import 'package:musi/database/music_cache_dao.dart';
import 'package:musi/database/search_history_dao.dart';
import 'package:musi/database/youtube_likes_dao.dart';
import 'package:musi/models/song.dart';
import 'package:musi/models/playlist.dart';
import 'package:musi/models/playlist_item.dart';
import 'package:musi/models/youtube_music_result.dart';
import 'package:musi/models/music_cache_entry.dart';
import 'package:musi/services/player_service.dart';
import 'package:musi/services/library_service.dart';
import 'package:musi/services/jamendo_music_service.dart';
import 'package:musi/services/music_item_resolver.dart';
import 'package:musi/services/youtube_audio_service.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('SQLite DAOs Unit Tests', () {
    final songDao = SongDao();
    final playlistDao = PlaylistDao();
    final settingsDao = SettingsDao();

    const testSong = Song(
      id: 'test-unit-1',
      title: 'Unit Test Melody',
      artist: 'Dart Test Band',
      album: 'Unit Tests',
      streamUrl: 'https://example.com/stream.mp3',
      duration: 210,
    );

    test('SongDao: upsertSong and retrieve by ID', () async {
      await songDao.upsertSong(testSong);
      final retrieved = await songDao.getSongById('test-unit-1');
      expect(retrieved, isNotNull);
      expect(retrieved!.title, 'Unit Test Melody');
      expect(retrieved.artist, 'Dart Test Band');
    });

    test('SongDao: like and unlike song persistence', () async {
      await songDao.setLiked(testSong, true);
      expect(await songDao.isLiked('test-unit-1'), isTrue);

      final likedList = await songDao.getLikedSongs();
      expect(likedList.any((s) => s.id == 'test-unit-1'), isTrue);

      await songDao.setLiked(testSong, false);
      expect(await songDao.isLiked('test-unit-1'), isFalse);
    });

    test('SongDao: recently played history and limit', () async {
      await songDao.addRecentlyPlayed(testSong);
      final recent = await songDao.getRecentlyPlayed();
      expect(recent.any((s) => s.id == 'test-unit-1'), isTrue);
    });

    test(
      'PlaylistDao: create, rename, add songs, reorder and delete',
      () async {
        final playlist = Playlist(
          id: 'test-pl-1',
          name: 'Unit Playlist',
          createdAt: DateTime.now(),
          songs: [],
        );

        // Create
        await playlistDao.createPlaylist(playlist);
        var all = await playlistDao.getAllPlaylists();
        expect(all.any((p) => p.id == 'test-pl-1'), isTrue);

        // Rename
        await playlistDao.renamePlaylist('test-pl-1', 'Renamed Playlist');
        all = await playlistDao.getAllPlaylists();
        final renamed = all.firstWhere((p) => p.id == 'test-pl-1');
        expect(renamed.name, 'Renamed Playlist');

        // Add song
        await playlistDao.addSongToPlaylist('test-pl-1', testSong);
        all = await playlistDao.getAllPlaylists();
        final withSong = all.firstWhere((p) => p.id == 'test-pl-1');
        expect(withSong.songs.length, 1);
        expect(withSong.songs.first.id, 'test-unit-1');

        // Remove song
        await playlistDao.removeSongFromPlaylist('test-pl-1', 'test-unit-1');
        all = await playlistDao.getAllPlaylists();
        final emptyPl = all.firstWhere((p) => p.id == 'test-pl-1');
        expect(emptyPl.songs.isEmpty, isTrue);

        // Delete
        await playlistDao.deletePlaylist('test-pl-1');
        all = await playlistDao.getAllPlaylists();
        expect(all.any((p) => p.id == 'test-pl-1'), isFalse);
      },
    );

    test(
      'SettingsDao: get and set offline mode, audio quality, volume normalize',
      () async {
        await settingsDao.setOfflineMode(true);
        expect(await settingsDao.getOfflineMode(), isTrue);
        await settingsDao.setOfflineMode(false);
        expect(await settingsDao.getOfflineMode(), isFalse);

        await settingsDao.setAudioQuality('Extreme (320 kbps)');
        expect(await settingsDao.getAudioQuality(), 'Extreme (320 kbps)');

        await settingsDao.setNormalizeVolume(false);
        expect(await settingsDao.getNormalizeVolume(), isFalse);
        await settingsDao.setNormalizeVolume(true);
        expect(await settingsDao.getNormalizeVolume(), isTrue);
      },
    );
  });

  group('PlayerService Logic Tests', () {
    final playerService = PlayerService();

    test('Queue, repeat modes, and shuffle controls', () {
      playerService.clearQueue();
      expect(playerService.queue.isEmpty, isTrue);

      expect(playerService.repeatMode, PlayerRepeatMode.off);
      playerService.cycleRepeatMode();
      expect(playerService.repeatMode, PlayerRepeatMode.all);
      playerService.cycleRepeatMode();
      expect(playerService.repeatMode, PlayerRepeatMode.one);
      playerService.cycleRepeatMode();
      expect(playerService.repeatMode, PlayerRepeatMode.off);

      expect(playerService.isShuffle, isFalse);
      playerService.toggleShuffle();
      expect(playerService.isShuffle, isTrue);
      playerService.toggleShuffle();
      expect(playerService.isShuffle, isFalse);
    });

    test('Previous restarts only past the restart threshold', () async {
      // seek() updates currentPosition even without an audio handler, so the
      // restart decision is observable without a real player.
      await playerService.seek(Duration.zero);
      expect(playerService.shouldRestartOnPrevious, isFalse);

      await playerService.seek(const Duration(milliseconds: 1500));
      expect(playerService.shouldRestartOnPrevious, isFalse);

      // Exactly at the threshold counts as "a few seconds in", so it restarts.
      await playerService.seek(PlayerService.previousRestartThreshold);
      expect(playerService.shouldRestartOnPrevious, isTrue);

      await playerService.seek(const Duration(seconds: 30));
      expect(playerService.shouldRestartOnPrevious, isTrue);

      // restartCurrent() returns to the start without leaving the restart zone.
      await playerService.restartCurrent();
      expect(playerService.currentPosition, Duration.zero);
      expect(playerService.shouldRestartOnPrevious, isFalse);
    });

    test('shuffleAndPlay queues every song exactly once', () async {
      final songs = List.generate(
        8,
        (i) => Song(
          id: 'shuffle-$i',
          title: 'Track $i',
          artist: 'Shuffle Band',
          album: null,
          streamUrl: 'https://example.com/$i.mp3',
          duration: 180,
        ),
      );

      await playerService.shuffleAndPlay(songs);

      // Shuffling must be a permutation: nothing dropped, nothing duplicated,
      // so every song plays once before any repeat.
      final queued = playerService.queue.map((s) => s.id).toList();
      expect(queued.length, songs.length);
      expect(queued.toSet().length, songs.length);
      expect(queued.toSet(), songs.map((s) => s.id).toSet());

      // Playback began on a song from that shuffled order.
      expect(playerService.currentSong?.id, queued[playerService.currentIndex]);

      // Random-per-advance must be off, otherwise next() can replay a track
      // before the rest of the playlist has been heard.
      expect(playerService.isShuffle, isFalse);

      // The order must actually be reordered, not merely a valid permutation.
      // Re-shuffling 5 times makes the chance of every run coincidentally
      // matching the input order negligible, so this cannot flake.
      final original = songs.map((s) => s.id).toList();
      var sawDifferentOrder = false;
      for (var i = 0; i < 5; i++) {
        await playerService.shuffleAndPlay(songs);
        final order = playerService.queue.map((s) => s.id).toList();
        expect(order.length, songs.length);
        expect(order.toSet().length, songs.length);
        if (order.join(',') != original.join(',')) {
          sawDifferentOrder = true;
        }
      }
      expect(sawDifferentOrder, isTrue);
    });

    test('rapid next presses are all queued and processed, none dropped', () async {
      const skipCount = 5;
      final songs = List.generate(
        6,
        (i) => Song(
          id: 'nav-$i',
          title: 'Nav $i',
          artist: 'Nav Band',
          album: null,
          streamUrl: 'https://example.com/$i.mp3',
          duration: 180,
          canStream: true,
        ),
      );
      // Next resolves playlist items through MusicItemResolver, which requires
      // the song to exist in the songs table and be streamable.
      await SongDao().upsertSongs(songs);

      await playerService.shuffleAndPlay(songs);
      final startIndex = playerService.currentIndex;

      // Skips fired back to back without awaiting in between. Each must be
      // honoured: if any were dropped or coalesced the final index would differ.
      final pending = List.generate(skipCount, (_) => playerService.next());
      await Future.wait(pending);

      expect(
        playerService.currentIndex,
        (startIndex + skipCount) % songs.length,
      );
      // Compare against the queue's own order — shuffleAndPlay permutes a copy,
      // so currentIndex indexes the shuffled queue, not the input list.
      final queueIds = playerService.queue.map((s) => s.id).toList();
      expect(
        playerService.currentSong?.id,
        queueIds[playerService.currentIndex],
      );
    });

    test(
      'saved collections are finite queues that never grow with related tracks',
      () async {
        // Liked Songs, playlists, downloads and recents are all finite: Next
        // must stay inside the collection rather than appending unrelated
        // videos, which used to happen on every song.
        final songs = List.generate(
          3,
          (i) => Song(
            id: 'finite-$i',
            title: 'Finite $i',
            artist: 'Band',
            album: null,
            streamUrl: 'https://example.com/$i.mp3',
            duration: 120,
            canStream: true,
          ),
        );
        await SongDao().upsertSongs(songs);

        await playerService.setQueue(songs);
        expect(playerService.allowsRelatedExtension, isFalse);

        await playerService.shuffleAndPlay(songs);
        expect(playerService.allowsRelatedExtension, isFalse);

        await playerService.setMixedQueue([
          PlaylistItem.fromSong(playlistId: '', song: songs.first, position: 0),
        ]);
        expect(playerService.allowsRelatedExtension, isFalse);
      },
    );

    test(
      'discovery queues keep related-track extension, liked songs do not',
      () async {
        final results = [
          YouTubeMusicResult(
            videoId: 'fin-a',
            title: 'A',
            channelTitle: 'Chan',
            thumbnailUrl: '',
            youtubeUrl: '',
          ),
          YouTubeMusicResult(
            videoId: 'fin-b',
            title: 'B',
            channelTitle: 'Chan',
            thumbnailUrl: '',
            youtubeUrl: '',
          ),
        ];

        // A search/trending/recently-played context is a discovery queue:
        // related continuation is the expected behaviour.
        await playerService.playYouTubeAudio(
          results.first,
          contextQueue: List.of(results),
        );
        expect(playerService.allowsRelatedExtension, isTrue);

        // Liked Songs is a saved collection, so it opts out explicitly.
        await playerService.playYouTubeAudio(
          results.first,
          contextQueue: List.of(results),
          allowRelatedExtension: false,
        );
        expect(playerService.allowsRelatedExtension, isFalse);

        // Queue-less navigation inside that finite queue must not silently flip
        // it back on — that would make the next skip leave the collection.
        await playerService.playYouTubeAudio(results.last);
        expect(playerService.allowsRelatedExtension, isFalse);
      },
    );

    test('a song played outside any playlist rebuilds the queue it navigates', () async {
      // Regression: playing a track with no queue context kept whatever queue
      // was already loaded, so _currentIndex pointed at a different song than
      // the one playing and Next walked from the wrong place — appearing to do
      // nothing on the second track.
      final queue = List.generate(
        3,
        (i) => YouTubeMusicResult(
          videoId: 'stale-$i',
          title: 'Stale $i',
          channelTitle: 'Chan',
          thumbnailUrl: '',
          youtubeUrl: '',
        ),
      );
      await playerService.playYouTubeAudio(
        queue.first,
        contextQueue: List.of(queue),
      );
      expect(playerService.currentIndex, 0);
      expect(playerService.ytQueue.length, 3);

      // A track that is not in the queue at all: the queue must be rebuilt
      // around it rather than left stale.
      final outsider = YouTubeMusicResult(
        videoId: 'outsider-1',
        title: 'Outsider',
        channelTitle: 'Chan',
        thumbnailUrl: '',
        youtubeUrl: '',
      );
      await playerService.playYouTubeAudio(outsider);

      expect(playerService.ytQueue.length, 1);
      expect(playerService.ytQueue.single.videoId, 'outsider-1');
      expect(playerService.currentIndex, 0);
      // Rebuilt as a discovery queue, so it can roll on to related songs.
      expect(playerService.allowsRelatedExtension, isTrue);
      // The mixed view must match, or the Up Next list shows the stale queue.
      expect(playerService.mixedQueue.length, 1);
      expect(playerService.mixedQueue.single.youtubeVideoId, 'outsider-1');
    });

    test(
      'playing a queued track with no context moves the pointer to it',
      () async {
        final queue = List.generate(
          4,
          (i) => YouTubeMusicResult(
            videoId: 'ptr-$i',
            title: 'Ptr $i',
            channelTitle: 'Chan',
            thumbnailUrl: '',
            youtubeUrl: '',
          ),
        );
        await playerService.playYouTubeAudio(
          queue[0],
          contextQueue: List.of(queue),
        );
        expect(playerService.currentIndex, 0);

        // An "Up Next" tap passes no context queue but the track is already in
        // it. The pointer must follow the audio, so the next skip continues
        // from the track now playing instead of from the old position.
        await playerService.playYouTubeAudio(queue[2]);

        expect(playerService.currentIndex, 2);
        expect(playerService.ytQueue.length, 4);
      },
    );

    test('a single video with no queue context is a discovery queue', () async {
      await playerService.setQueue([
        Song(
          id: 'seed',
          title: 'Seed',
          artist: 'Band',
          album: null,
          streamUrl: 'https://example.com/seed.mp3',
          duration: 120,
          canStream: true,
        ),
      ]);

      await playerService.playYouTubeAudio(
        YouTubeMusicResult(
          videoId: 'single-x',
          title: 'Single',
          channelTitle: 'Chan',
          thumbnailUrl: '',
          youtubeUrl: '',
        ),
      );
      expect(playerService.allowsRelatedExtension, isTrue);
    });

    test(
      'a pre-warmed stream is used instead of the related-endpoint URL',
      () async {
        final service = YouTubeAudioService();
        const videoId = 'prewarm-check';
        const warmedUrl = 'https://r1---sn-prewarmed.googlevideo.com/audio';
        const endpointUrl = 'https://endpoint/related/audioUrl';

        // The related endpoint hands back an unverified audioUrl on the result.
        // If that won, the pre-warmed cache entry would be ignored and Next
        // would pay a resolve — or 403 on the critical path.
        final video = YouTubeMusicResult(
          videoId: videoId,
          title: 'Prewarm',
          channelTitle: 'Chan',
          thumbnailUrl: '',
          youtubeUrl: '',
          streamUrl: endpointUrl,
        );

        // Nothing cached yet: falls back to the endpoint URL, as before.
        var song = await service.resolveToSong(video);
        expect(song?.streamUrl, endpointUrl);

        // Simulate the background pre-warm filling the cache.
        service.cacheStreamForTesting(videoId, warmedUrl);

        // Now the verified, audio-only pre-warmed URL must win.
        song = await service.resolveToSong(video);
        expect(song?.streamUrl, warmedUrl);

        // Invalidating must clear it again, so a 403 falls back to a re-resolve
        // instead of replaying the dead URL.
        expect(service.peekCachedStream(videoId), isNotNull);
        service.invalidateCache(videoId);
        expect(service.peekCachedStream(videoId), isNull);
      },
    );
  });

  group('LibraryService YouTube Like Tests', () {
    test('isLiked stays consistent when unliking from either screen', () async {
      final library = LibraryService();
      const videoId = 'audit-like-1';
      const songId = 'yt_$videoId';

      final video = YouTubeMusicResult(
        videoId: videoId,
        title: 'Like Audit',
        channelTitle: 'Channel',
        thumbnailUrl: '',
        youtubeUrl: 'https://www.youtube.com/watch?v=$videoId',
      );
      final song = Song(
        id: songId,
        title: 'Like Audit',
        artist: 'Channel',
        album: 'YouTube Music',
        streamUrl: '',
        sourceUrl: 'https://www.youtube.com/watch?v=$videoId',
        duration: 200,
        providerId: 'youtube',
        providerName: 'YouTube',
      );

      // Liked from a screen that goes through toggleLike (Home tiles).
      await library.toggleLike(song);
      expect(library.isLiked(songId), isTrue);

      // Unliked from a screen that goes through toggleYouTubeLike (Search
      // tiles). That path must clear the mirrored id too — otherwise isLiked()
      // still reports true from _likedSongIds, leaving the heart lit and making
      // the next tap re-like instead of unliking.
      await library.toggleYouTubeLike(video);
      expect(library.isLiked(songId), isFalse);
    });
  });

  group('Music Provider Tests', () {
    test('JamendoMusicService returns results or fallback cleanly', () async {
      final service = JamendoMusicService();
      final results = await service.search('chill');
      expect(results, isNotEmpty);
      expect(results.first.title.isNotEmpty, isTrue);
    });
  });

  group('MusicCacheDao Tests', () {
    final cacheDao = MusicCacheDao();

    test('MusicCacheDao: upsert and retrieve cache entry', () async {
      final entry = MusicCacheEntry.fromYouTube(
        video: const YouTubeMusicResult(
          videoId: 'test-video-1',
          title: 'Test Video',
          channelTitle: 'Test Channel',
          thumbnailUrl: 'https://example.com/thumb.jpg',
          youtubeUrl: 'https://www.youtube.com/watch?v=test-video-1',
        ),
      );

      await cacheDao.upsertCacheEntry(entry);
      final retrieved = await cacheDao.getCacheEntry(
        CachedSourceType.youtube,
        'test-video-1',
      );
      expect(retrieved, isNotNull);
      expect(retrieved!.title, 'Test Video');
      expect(retrieved.sourceType, CachedSourceType.youtube);
    });

    test('MusicCacheDao: search cache', () async {
      final entry = MusicCacheEntry.fromSong(
        song: const Song(
          id: 'test-song-1',
          title: 'Searchable Song',
          artist: 'Search Artist',
          streamUrl: 'https://example.com/stream.mp3',
          duration: 180,
        ),
        provider: 'test',
      );

      await cacheDao.upsertCacheEntry(entry);
      final results = await cacheDao.searchCache('searchable');
      expect(results.any((e) => e.title.contains('Searchable')), isTrue);
    });

    test('MusicCacheDao: update last played', () async {
      final entry = MusicCacheEntry.fromYouTube(
        video: const YouTubeMusicResult(
          videoId: 'test-video-2',
          title: 'Test Video 2',
          channelTitle: 'Test Channel',
          thumbnailUrl: '',
          youtubeUrl: 'https://www.youtube.com/watch?v=test-video-2',
        ),
      );

      await cacheDao.upsertCacheEntry(entry);
      await cacheDao.updateLastPlayed(CachedSourceType.youtube, 'test-video-2');

      final retrieved = await cacheDao.getCacheEntry(
        CachedSourceType.youtube,
        'test-video-2',
      );
      expect(retrieved, isNotNull);
      expect(retrieved!.lastPlayedAt, isNotNull);
    });
  });

  group('SearchHistoryDao Tests', () {
    final historyDao = SearchHistoryDao();

    test('SearchHistoryDao: save and retrieve search queries', () async {
      await historyDao.saveSearchQuery('test query 1');
      await historyDao.saveSearchQuery('test query 2');
      await historyDao.saveSearchQuery(
        'test query 1',
      ); // Duplicate should update timestamp

      final searches = await historyDao.getRecentSearches(limit: 10);
      expect(searches.length, 2);
      expect(searches.contains('test query 1'), isTrue);
      expect(searches.contains('test query 2'), isTrue);
    });

    test('SearchHistoryDao: clear history', () async {
      await historyDao.saveSearchQuery('query to clear');
      await historyDao.clearSearchHistory();
      final searches = await historyDao.getRecentSearches();
      expect(searches.isEmpty, isTrue);
    });
  });

  group('YouTubeLikesDao Tests', () {
    final likesDao = YouTubeLikesDao();

    test('YouTubeLikesDao: like and unlike YouTube video', () async {
      final video = const YouTubeMusicResult(
        videoId: 'test-like-1',
        title: 'Like Test',
        channelTitle: 'Like Channel',
        thumbnailUrl: '',
        youtubeUrl: 'https://www.youtube.com/watch?v=test-like-1',
      );

      await likesDao.likeYouTubeVideo(video);
      expect(await likesDao.isYouTubeLiked('test-like-1'), isTrue);

      final liked = await likesDao.getLikedYouTubeVideos();
      expect(liked.any((v) => v.videoId == 'test-like-1'), isTrue);

      await likesDao.unlikeYouTubeVideo('test-like-1');
      expect(await likesDao.isYouTubeLiked('test-like-1'), isFalse);
    });
  });

  group('PlaylistItem Model Tests', () {
    test('PlaylistItem: fromSong and fromYouTube factories', () {
      const song = Song(
        id: 'song-1',
        title: 'Playlist Song',
        artist: 'Playlist Artist',
        streamUrl: 'https://example.com/stream.mp3',
        duration: 200,
        artworkUrl: 'https://example.com/art.jpg',
      );

      final item1 = PlaylistItem.fromSong(
        playlistId: 'pl-1',
        song: song,
        position: 0,
      );

      expect(item1.sourceType, PlaylistItemSourceType.authorized);
      expect(item1.songId, 'song-1');
      expect(item1.title, 'Playlist Song');

      const video = YouTubeMusicResult(
        videoId: 'video-1',
        title: 'Playlist Video',
        channelTitle: 'Playlist Channel',
        thumbnailUrl: 'https://example.com/thumb.jpg',
        youtubeUrl: 'https://www.youtube.com/watch?v=video-1',
      );

      final item2 = PlaylistItem.fromYouTube(
        playlistId: 'pl-1',
        video: video,
        position: 1,
      );

      expect(item2.sourceType, PlaylistItemSourceType.youtube);
      expect(item2.youtubeVideoId, 'video-1');
      expect(item2.title, 'Playlist Video');
    });

    test('PlaylistItem: copyWith', () {
      const song = Song(
        id: 'song-2',
        title: 'Original',
        artist: 'Artist',
        streamUrl: 'https://example.com/stream.mp3',
        duration: 200,
      );

      final item = PlaylistItem.fromSong(
        playlistId: 'pl-1',
        song: song,
        position: 0,
      );

      final updated = item.copyWith(title: 'Updated Title');
      expect(updated.title, 'Updated Title');
      expect(updated.sourceId, item.sourceId);
    });
  });

  group('MusicItemResolver Tests', () {
    test('MusicItemResolver: singleton instance', () {
      final resolver1 = MusicItemResolver();
      final resolver2 = MusicItemResolver();
      expect(identical(resolver1, resolver2), isTrue);
    });
  });

  group('YouTube Audio Service and Background Playback Integration Tests', () {
    test('YouTubeAudioService: isYouTubeSong identification', () {
      const ytSong1 = Song(
        id: 'yt_abc123',
        title: 'YT Test',
        artist: 'YT Artist',
        streamUrl: 'https://example.com/audio.m4a',
        duration: 180,
      );
      const ytSong2 = Song(
        id: 'custom_id',
        title: 'YT Test 2',
        artist: 'YT Artist 2',
        streamUrl: 'https://example.com/audio.m4a',
        duration: 180,
        providerId: 'youtube',
      );
      const regularSong = Song(
        id: 'jamendo_999',
        title: 'Normal Song',
        artist: 'Jamendo Artist',
        streamUrl: 'https://example.com/stream.mp3',
        duration: 200,
        providerId: 'jamendo',
      );

      expect(YouTubeAudioService.isYouTubeSong(ytSong1), isTrue);
      expect(YouTubeAudioService.isYouTubeSong(ytSong2), isTrue);
      expect(YouTubeAudioService.isYouTubeSong(regularSong), isFalse);
    });

    test('YouTubeAudioService: extractVideoId', () {
      const song1 = Song(
        id: 'yt_dQw4w9WgXcQ',
        title: 'Never Gonna Give You Up',
        artist: 'Rick Astley',
        streamUrl: 'https://example.com/stream',
        duration: 212,
      );
      const song2 = Song(
        id: 'custom_rick',
        title: 'Never Gonna Give You Up',
        artist: 'Rick Astley',
        streamUrl: 'https://example.com/stream',
        sourceUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        duration: 212,
      );

      expect(YouTubeAudioService.extractVideoId(song1), 'dQw4w9WgXcQ');
      expect(YouTubeAudioService.extractVideoId(song2), 'dQw4w9WgXcQ');
    });

    test('LibraryService: YouTube like and isLiked sync', () async {
      final library = LibraryService();
      await library.init();

      final video = YouTubeMusicResult(
        videoId: 'yt-unit-test-vid',
        title: 'Unit Test Video',
        channelTitle: 'Channel Test',
        thumbnailUrl: 'https://example.com/thumb.jpg',
        youtubeUrl: 'https://www.youtube.com/watch?v=yt-unit-test-vid',
      );

      // Initially not liked
      expect(library.isYouTubeLiked('yt-unit-test-vid'), isFalse);
      expect(library.isLiked('yt_yt-unit-test-vid'), isFalse);

      // Toggle like
      await library.toggleYouTubeLike(video);
      expect(library.isYouTubeLiked('yt-unit-test-vid'), isTrue);
      expect(library.isLiked('yt_yt-unit-test-vid'), isTrue);

      // Unlike
      await library.toggleYouTubeLike(video);
      expect(library.isYouTubeLiked('yt-unit-test-vid'), isFalse);
      expect(library.isLiked('yt_yt-unit-test-vid'), isFalse);
    });

    test('LibraryService: addSongToPlaylist with YouTube song converts to YouTube item', () async {
      final library = LibraryService();
      await library.init();

      // Create test playlist
      await library.createPlaylist('YT Test Playlist');
      final playlist = library.playlists.firstWhere(
        (p) => p.name == 'YT Test Playlist',
      );

      const ytSong = Song(
        id: 'yt_unit_playlist_vid',
        title: 'Playlist Song YT',
        artist: 'Channel 1',
        streamUrl: 'https://example.com/stream.m4a',
        duration: 200,
        providerId: 'youtube',
      );

      await library.addSongToPlaylist(playlist.id, ytSong);

      final items = await library.getPlaylistItems(playlist.id);
      expect(
        items.any(
          (i) => i.isYouTube && i.youtubeVideoId == 'unit_playlist_vid',
        ),
        isTrue,
      );
    });
  });
}

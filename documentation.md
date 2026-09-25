# Musi — Android Music Player Documentation

## 1. Project Overview

**Musi** is a standalone Android music player built with Flutter and Dart. It combines locally persisted library features with a multi-source music pipeline:

1. **Musi-authorized audio** from Jamendo and the built-in open-licensed catalog — streamed or downloaded through `just_audio` and `audio_service` for full background playback.
2. **YouTube discovery and audio playback** through `yt_flutter_musicapi` (ytmusicapi via Chaquopy Python bridge) and `youtube_explode_dart` for search. YouTube audio streams are extracted and routed through Musi's background audio pipeline.

The application does not use a backend service. User library data, playlists, preferences, and permitted downloaded audio remain on the device.

### Core goals

- Preserve the existing Musi audio player, queue, downloads, playlists, liked songs, recently played history, offline mode, and background playback.
- Let users search authorized Musi sources and YouTube from the same search screen.
- Route YouTube audio through Musi's background audio pipeline (lock screen controls, media notifications).
- Use supported player tooling (`youtube_explode_dart`, `yt_flutter_musicapi`).
- Keep YouTube visually labeled and separate from downloadable Musi songs.
- Never download YouTube audio to persistent offline storage; YouTube audio is streamed only.

---

## 2. Architecture Overview

```text
                       SearchScreen  /  HomeScreen
                               |
                               v
                    MusicProviderManager
                     /                  \
                    /                    \
      Authorized audio providers        YouTube
      Jamendo / Open Licensed          |
                    |                  |
                    v                  v
             MusicService   YouTubeMusicApiService
                    |                  |
                    |    (yt_flutter_musicapi     )
                    |    (youtube_explode_dart)     |
                    |                  |
                    v                  v
           SongSearchResult   YouTubeSearchResult
                    |                  |
                    |                  |
                    v                  v
              MusicItemResolver   YouTubeMusicApiService
                    |  \               |
              (resolve) (resolveToSong) |
                    |     |             |
                    v     v             v
           PlayerService  (Song with    YouTubeMusicResult
                |        streamUrl)
                v
           MusiAudioHandler
                |
                v
           just_audio
                |
                v
           audio_service
                |
                v
      Android background playback
```

The two source types are kept distinct:

- An authorized `Song` is played through `PlayerService`, `MusiAudioHandler`, `just_audio`, and `audio_service`.
- A `YouTubeMusicResult` is played as background audio only: `YouTubeAudioService` extracts an audio-only stream URL (MP4/AAC, itag 140) via `youtube_explode_dart`, converts the result to a `Song` (id `yt_<videoId>`), and routes it through `PlayerService` for background playback with lock screen controls.
- YouTube audio streams are cached in-memory for 90 minutes (not persisted to disk).

---

## 3. Technology Stack

| Area | Implementation |
|---|---|
| Framework | Flutter 3.47.5 stable |
| Language | Dart 3.13.4 |
| Target | Android, API 21+ |
| UI | Material 3 with Musi dark theme |
| State | Singleton `ChangeNotifier` services and `ListenableBuilder` widgets |
| Authorized audio | `just_audio` 0.10.6, `audio_service` 0.18.19, `audio_session` 0.2.4 |
| Local database | `sqflite` 2.4.4 and `path` 1.9.1 |
| HTTP and downloads | `http` 1.6.0, `dio` 5.11.1, `path_provider` 2.1.6 |
| YouTube audio extraction | `youtube_explode_dart` 3.1.0, `yt_flutter_musicapi` 3.4.4 |
| External links | `url_launcher` 6.3.1 |
| Tests | `flutter_test`, `sqflite_common_ffi`, Flutter analyzer |

### YouTube dependencies

`pubspec.yaml` contains the direct dependencies:

```yaml
# YouTube Music search and audio stream extraction
yt_flutter_musicapi: ^3.4.4
youtube_explode_dart: ^3.1.0

# URL launching
url_launcher: ^6.3.1
```

No compile-time YouTube API key or `.env` file is required. YouTube discovery and audio extraction work through `yt_flutter_musicapi` (which uses ytmusicapi under the hood) and `youtube_explode_dart` (pure-Dart stream extraction).

---

## 4. Project Structure

```text
musi/
├── android/
│   ├── app/
│   │   ├── build.gradle.kts
│   │   └── src/main/AndroidManifest.xml
│   └── Gradle project files
├── lib/
│   ├── main.dart
│   ├── models/
│   │   ├── music_provider.dart
│   │   ├── playlist.dart
│   │   ├── playlist_item.dart
│   │   ├── playlist_song.dart
│   │   ├── search_result.dart
│   │   ├── song.dart
│   │   ├── music_cache_entry.dart
│   │   └── youtube_music_result.dart
│   ├── database/
│   │   ├── musi_database.dart
│   │   ├── song_dao.dart
│   │   ├── playlist_dao.dart
│   │   ├── settings_dao.dart
│   │   ├── provider_dao.dart
│   │   ├── music_cache_dao.dart
│   │   ├── search_history_dao.dart
│   │   └── youtube_likes_dao.dart
│   ├── screens/
│   │   ├── home_screen.dart
│   │   ├── library_screen.dart
│   │   ├── main_navigation_scaffold.dart
│   │   ├── player_screen.dart
│   │   ├── playlist_screen.dart
│   │   ├── playlist_picker_sheet.dart
│   │   ├── search_screen.dart
│   │   ├── settings_screen.dart
│   ├── services/
│   │   ├── audio_handler.dart
│   │   ├── download_service.dart
│   │   ├── jamendo_music_service.dart
│   │   ├── library_service.dart
│   │   ├── mock_music_service.dart
│   │   ├── music_provider_manager.dart
│   │   ├── music_item_resolver.dart
│   │   ├── music_service.dart
│   │   ├── player_service.dart
│   │   ├── youtube_audio_service.dart
│   │   ├── youtube_music_api_service.dart
│   │   └── youtube_playback_service.dart
│   ├── theme/
│   │   └── app_theme.dart
│   └── widgets/
│       ├── mini_player.dart
│       ├── player_controls.dart
│       ├── playlist_tile.dart
│       ├── search_bar_widget.dart
│       ├── song_tile.dart
│       └── youtube_result_tile.dart
├── test/
│   ├── unit_test.dart
│   └── widget_test.dart
├── .gitignore
├── documentation.md
├── pubspec.yaml
└── pubspec.lock
```

---

## 5. Authorized Musi Audio Pipeline

### 5.1 Providers

`MusicService` is the interface used by authorized audio providers:

```dart
Future<List<Song>> search(String query);
Future<Song?> getSongDetails(String id);
Future<List<Song>> getFeaturedSongs();
Future<List<Song>> getTrendingSongs();
```

Implemented providers:

- `JamendoMusicService`: queries the Jamendo API for Creative Commons tracks and falls back to the local mock catalog when the API is unavailable.
- `MockMusicService`: supplies open-licensed development tracks and predictable UI/test data.

### 5.2 Song model

`Song` (in `lib/models/song.dart`) represents an authorized audio source and contains:

- `id`
- `title`
- `artist`
- `album`
- `artworkUrl`
- `streamUrl`
- `sourceUrl`
- `localPath`
- `duration`
- provider and license metadata (`providerId`, `providerName`, `license`, `canStream`, `canDownload`)
- download and offline status (`isDownloaded`)

### 5.3 Playback

`PlayerService` (in `lib/services/player_service.dart`) owns the Musi queue and playback state:

- current song and current YouTube video reference
- queue (authorized songs) and mixed queue (authorized + YouTube)
- play, pause, stop, seek, next, previous
- shuffle
- repeat off/all/one
- buffering and duration state
- recently played persistence

When initialized with `MusiAudioHandler`, it connects to the `just_audio` streams and the Android `audio_service` media session. Background playback provides Android media notifications and lock screen controls.

### 5.4 Downloads and offline mode

`DownloadService` (in `lib/services/download_service.dart`) downloads only authorized songs whose provider permits downloads. Files are stored in the app-private `musi_downloads` directory. Offline mode filters search and playback to locally available Musi tracks.

YouTube content has no download action and is unavailable in offline mode.

---

## 6. YouTube Integration

### 6.1 YouTube functionality

YouTube is integrated through two complementary pathways:

1. **Discovery & search** uses `yt_flutter_musicapi` (ytmusicapi via Chaquopy Python bridge on Android) with a pure-Dart `youtube_explode_dart` fallback for search and trending.
2. **Background audio** uses `youtube_explode_dart` to resolve audio-only stream URLs (preferring MP4/AAC itag 140 for native ExoPlayer support), which are routed through `just_audio` and `audio_service` for Musi's background playback pipeline.

### YouTube audio stream resolution

`lib/services/youtube_audio_service.dart` is responsible for resolving YouTube audio streams for native background playback:

**Dual-strategy approach:**

1. **Primary** — `YoutubeExplode` pure-Dart extractor trying multiple YouTube API clients in order: `android` → `androidSdkless` → `ios` → `mweb`, targeting native MP4/AAC audio streams (itag 140: 128 kbps AAC) for ExoPlayer playback. Falls back to highest-bitrate audio-only or muxed streams if MP4 is unavailable.
2. **Fallback** — `YouTubeMusicApiService.getStreamUrl()` via the `yt_flutter_musicapi` Python bridge (`getAudioUrlFast`).

**Stream URL validation:** Before caching a resolved URL, `YouTubeAudioService._validateStreamUrl()` issues a HEAD request with the YouTube User-Agent (`com.google.android.youtube/21.36.40`) and a `Range: bytes=0-0` header. If YouTube CDN returns 403, the URL is rejected and the next client is tried. This filters out unplayable stream URLs early, preventing ExoPlayer 403 errors.

**Pre-filter validation:** Before YouTube results are displayed on the search screen or home trending section, `MusicProviderManager` calls `YouTubeAudioService.filterPlayable()` which concurrently validates each result's stream URL via `validatePlayable()`. Only results that pass validation (have a resolvable, CDN-accessible stream URL) are shown to the user. This ensures no source errors reach the UI layer.

**Key methods:**

| Method | Purpose |
|---|---|
| `getAudioStreamUrl(videoId, forceRefresh)` | Resolves an audio-only stream URL with 90-minute in-memory cache |
| `resolveToSong(video)` | Converts a `YouTubeMusicResult` into a `Song` (id `yt_<videoId>`) with a resolved `streamUrl` |
| `_validateStreamUrl(url)` | HEAD-request validation with YouTube User-Agent before caching (filters 403 URLs) |
| `validatePlayable(videoId)` | Quick check if a video ID can resolve to a playable stream |
| `filterPlayable(results)` | Concurrently validates and filters a list of YouTube results, returning only playable ones |
| `isYouTubeSong(song)` | Static helper: checks `song.id.startsWith('yt_')` or `song.providerId == 'youtube'` |
| `extractVideoId(song)` | Static helper: extracts video ID from `yt_` prefix or `sourceUrl` query parameter |
| `invalidateCache(videoId)` | Clears cached stream URL for a video |
| `youtubeUserAgent` | YouTube app User-Agent string for CDN acceptance |

YouTube `Song` objects have:
- `id` = `yt_<videoId>`
- `providerId` = `'youtube'`
- `providerName` = `'YouTube'`
- `album` = `'YouTube Music'`

### 6.2 Audio handler configuration

`lib/services/audio_handler.dart` (`MusiAudioHandler`) configures `AudioPlayer` with:

- A YouTube mobile User-Agent: `'com.google.android.youtube/21.36.40 (Linux; U; Android 11) gzip'` — set directly on ExoPlayer via `AudioPlayer.userAgent` AND included as a header in `AudioSource.uri`
- `useProxyForRequestHeaders: false` — **critical**: disables `just_audio`'s local proxy mechanism which fails on OnePlus IV2201 / Android 13 with Media3/ExoPlayer 1.4.1. With `false`, headers from `AudioSource.uri` are passed directly to ExoPlayer's `DefaultHttpDataSource` via `buildDataSourceFactory`, which extracts `User-Agent` and sets it on `DefaultHttpDataSource.Factory().setUserAgent()`
- YouTube-specific headers on `AudioSource.uri`: `Origin: https://www.youtube.com`, `Referer: https://www.youtube.com/`, `X-YouTube-Client-Name: '3'`, `X-YouTube-Client-Id: 'c401c970a5780ad0'`, `User-Agent`
- `AudioSessionConfiguration.music()` for proper audio focus and ducking
- Media item extras (`sourceUrl`, `isDownloaded`) for notification and lock screen display

**403 fix summary:** The previous approach used `useProxyForRequestHeaders: true`, which wraps YouTube URLs in a local proxy (`http://127.0.0.1:port/...`). On OnePlus IV2201 with Media3 1.4.1, this proxy failed, causing ExoPlayer to get HTTP 403 from YouTube CDN. Setting `useProxyForRequestHeaders: false` bypasses the proxy entirely and passes headers (including User-Agent) directly to `DefaultHttpDataSource`, which `just_audio`'s Android code handles via `buildDataSourceFactory()`.

### 6.3 YouTube search service

`lib/services/youtube_music_api_service.dart` provides:

- `YouTubeMusicApiService.initialize()` — initializes the `yt_flutter_musicapi` bridge (Android-only, requires Chaquopy Python)
- `searchTracks(query, limit, cancelable)` — searches YouTube Music, returns all results without duration filtering
- `getTrendingHits(limit: 10)` — dual-strategy trending fetches for the HomeScreen
- `getStreamUrl(videoId)` — extracts an audio stream URL via the Python bridge
- `getVideoDetails(videoId)` — fetches metadata by searching and matching video ID

A `CancelableToken` class is provided for cancelling in-flight requests.

Search behavior:
- Trims empty queries
- Limits each request to the configured result count
- Deduplicates results by video ID
- Returns empty list on failure

### 6.4 YouTube result model

`lib/models/youtube_music_result.dart` defines `YouTubeMusicResult` separately from `Song`:

Important fields:

- `videoId`
- `title`
- `channelTitle`
- `thumbnailUrl`
- `description`
- `publishedAt`
- `youtubeUrl`
- `sourceType` — always `MusicSourceType.youtube`
- `streamUrl` — always `null` (set only when resolved to a `Song`)
- `durationSeconds`

The constructor always sets `streamUrl = null`. The official URL is constructed as `https://www.youtube.com/watch?v=<videoId>`.

The model includes:
- `fromApi(Map<String, dynamic>)` factory for mapping YouTube Data API responses
- `parseIso8601DurationSeconds` for parsing `contentDetails.duration`
- `toMap()` / `fromMap()` for persistence

### 6.5 Search result abstraction

`lib/models/search_result.dart` keeps source types distinct:

```text
SearchResult
├── SongSearchResult
│   └── Song
└── YouTubeSearchResult
    └── YouTubeMusicResult
```

### 6.6 Provider manager integration

`MusicProviderManager` registers three source entries:

| Provider ID | Name | Streaming | Downloading | Purpose |
|---|---|---:|---:|---|
| `jamendo` | Jamendo | Yes | Yes | Creative Commons audio |
| `mock` | Open Licensed Sources | Yes | Yes | Built-in development catalog |
| `youtube` | YouTube | No | No | YouTube Music discovery and audio/video playback |

The YouTube provider is seeded in the `providers` table with `can_stream = 0` and `can_download = 0`.

For a normal search, the manager:

1. initializes persisted provider settings;
2. searches enabled authorized providers with a 2-second timeout;
3. searches YouTube only when the YouTube setting is enabled;
4. waits for independent provider results;
5. deduplicates songs and YouTube video IDs;
6. returns a combined `List<SearchResult>`.

A YouTube failure is isolated from Jamendo and mock-provider failures.

### 6.7 Search UI

`SearchScreen` retains the existing 300 ms debounce behavior. It does not issue a YouTube request for every individual keystroke.

Results are split into:

- `_playableResults`: authorized songs with a valid stream URL;
- `_nonPlayableResults`: authorized results that cannot currently be played;
- `_youtubeResults`: YouTube search results.

The UI renders separate sections:

```text
PLAYABLE IN MUSI
[authorized song tiles]

OTHER AUTHORIZED SOURCES
[non-playable authorized tiles]

YOUTUBE MUSIC
[YouTube result tiles with inline play/pause]
```

If no authorized source is available, the screen explicitly states that no authorized source was found before showing YouTube results.

YouTube results support **in-place background audio playback** — tapping a YouTube result tile or pressing play resolves an audio stream and plays it through `PlayerService` without navigating away from the search screen. A loading indicator shows while the stream URL is being resolved.

Cache-first search:
- `SearchScreen` checks `MusicCacheDao.searchCache()` first for instant cached results
- Shows a "Showing cached results — fetching latest..." indicator
- Merges fresh network results with cached results
- Caches all fresh results for future fast lookups

Offline mode bypasses network searches and shows downloaded Musi tracks only. YouTube search and playback remain unavailable offline.

### 6.8 YouTube result tile

`lib/widgets/youtube_result_tile.dart` renders:

- a 56x56 YouTube thumbnail with duration pill overlay;
- title and channel in a flexible row with a fixed non-wrapping `YouTube` source badge;
- a prominent Play/Pause button with loading indicator (`CircularProgressIndicator`);
- a 3-dots `PopupMenuButton` with: *Like / Unlike*, *Add to Playlist*, and *Dismiss*;
- the tile uses the existing amber theme with `AppTheme.error` (red) emphasis for the YouTube badge and like state.

### 6.9 YouTube result tile tap and like behavior

`YouTubeResultTile` is a stateless widget that receives `isLiked`, `onLike`, and `onTap` as parameters. The like/unlike action is only accessible through the overflow menu (3-dot `PopupMenuButton`). Callers must pass both `isLiked` (computed from `LibraryService`) and `onLike` (typically `LibraryService.toggleYouTubeLike(video)`). Omitting either parameter disables the like button or shows an incorrect like state.

When `onTap` is provided, tapping the tile invokes it (e.g., to play background audio in-place). All YouTube tiles receive `onTap` — in the Library **Liked** and **Recently Played** tabs, `onTap` calls `PlayerService.playYouTubeAudio()`; in `SearchScreen`, `onTap` is also `_playYouTubeAudio()`.

### 6.12 YouTube background audio and `PlayerService.playYouTubeAudio()`

`PlayerService.playYouTubeAudio(video, contextQueue)` resolves a `YouTubeMusicResult` to a background-playable `Song` (id `yt_<videoId>`) via `YouTubeAudioService.resolveToSong()`, then routes it through `just_audio` and `audio_service` like any authorized track. The optional `contextQueue` parameter lets callers specify a pre-built mixed queue (authorized songs + YouTube videos) so that next/previous and shuffle operate on the full context. Before starting playback, the method calls `player.stop()` to clear any AAC decoder error state from a previous track. On a 403 from expired CDN URLs, the method invalidates the stream cache (via `_youtubeAudioService.invalidateCache()`) and retries with a fresh URL (`forceRefresh: true`). If resolution fails entirely, `_lastError` is set and the caller is notified via `onError` callback.

**Background playback reliability:**
- `next()` uses a `for` loop with retry attempts instead of recursive calls, preventing the `_isNavigating` guard from blocking navigation when tracks fail to resolve
- If `playYouTubeAudio()` fails on a YouTube queue track, `next()` continues to the next track automatically
- `_handleSongCompletion()` calls `next()` when a track finishes, which works even when the app is minimized since it's driven by the `playerStateStream` listener
- Media session skip buttons are wired to `PlayerService.next()` and `previous()` via `onSkipToNext`/`onSkipToPrevious` callbacks set in `init()`

### 6.14 Playback resolution

`MusicItemResolver` (in `lib/services/music_item_resolver.dart`) is a singleton service for routing playback:

| Method | Purpose |
|---|---|
| `resolvePlaylistItem(item)` | Resolves a `PlaylistItem` to either a `Song` (authorized, checks local file first then stream URL) or a YouTube video |
| `resolveSong(song)` | Resolves an authorized `Song` for playback |
| `resolveYouTubeVideo(video)` | Resolves a `YouTubeMusicResult` to background audio via `YouTubeAudioService.resolveToSong()` |
| `isYouTubeLiked(videoId)` | Checks like status |
| `toggleYouTubeLike(video)` | Toggles like in `liked_youtube` table |
| `getLikedYouTubeVideos()` | Returns liked YouTube videos |
| `getPlaylistItems(playlistId)` | Returns full playlist with mixed Song and YouTube items |

`PlaybackResolution` contains:
- `route` — `PlaybackRouteType.playerService` or `unavailable`
- `song` — resolved song if route is `playerService`
- `errorMessage` — error details if unavailable

When resolving a YouTube video, the resolver:
1. Updates the `music_cache` last-played timestamp
2. Attempts `YouTubeAudioService.resolveToSong()` to get a background audio stream
3. If successful, returns `PlaybackResolution.forPlayerService(song)` — audio plays via Musi's background player
4. If unsuccessful, returns `PlaybackResolution.unavailable` with an error message

### 6.15 External YouTube option

Removed — the app no longer opens YouTube video in an external browser or app.

---

## 7. Persistent SQLite Cache & Library Extensions

### 7.1 Database Migration (v1 → v4)

Database schema is at version 4 (`MusiDatabase._databaseVersion = 4`). Migrations:

- **v1 → v2**: Added `provider_id`, `provider_name`, `license`, `can_stream`, `can_download` columns to `songs`; created `providers` table.
- **v2 → v3**: Added `music_cache`, `search_history`, `liked_youtube`, `playlist_items` tables; migrated existing `playlist_songs` data into `playlist_items`.
- **v3 → v4**: Created v3 tables using `IF NOT EXISTS` for fresh installs that ran `onCreate` at v3 but missed v3 table creation.

### 7.2 Tables

| Table | Purpose |
|---|---|
| `songs` | Authorized song metadata with provider/license info |
| `liked_songs` | Junction table for liked authorized songs |
| `playlists` | Playlist metadata (id, name, created_at, cover_url) |
| `playlist_songs` | Legacy junction table (backward compatibility) |
| `playlist_items` | Polymorphic playlist items (authorized + YouTube) |
| `recently_played` | Recently played authorized songs |
| `settings` | Key-value settings |
| `providers` | Music provider metadata and enablement flags |
| `music_cache` | Persistent search result cache (7-day freshness) |
| `search_history` | Normalized search queries with timestamps |
| `liked_youtube` | Liked YouTube video metadata |

### 7.3 Music Cache

`MusicCacheDao` (in `lib/database/music_cache_dao.dart`) provides:

- `upsertCacheEntry(entry)` / `upsertCacheEntries(entries)` — batch insert/replace
- `getCacheEntry(sourceType, sourceId)` — lookup by source type and ID
- `searchCache(query)` — LIKE search on title, artist, album with ordering by last played
- `getRecentCached(limit)` — recently played cached items
- `updateLastPlayed(sourceType, sourceId)` — update timestamp
- `cleanupStaleCache()` — removes entries older than 30 days with no plays
- `getCacheCount()` — total cached entries

`MusicCacheEntry` (in `lib/models/music_cache_entry.dart`) stores: `sourceType`, `sourceId`, title, artist, album, thumbnail URL, source URL, YouTube video ID, provider, duration, cached timestamp, and last-played timestamp. Has a 7-day staleness threshold (`isStale()`).

### 7.4 Search History

`SearchHistoryDao` (in `lib/database/search_history_dao.dart`) stores normalized (lowercased, trimmed) queries with timestamps:

- `saveSearchQuery(query)` — inserts or replaces (deduplicates by query text)
- `getRecentSearches(limit)` — ordered by searched_at DESC
- `clearSearchHistory()`
- `getSearchCount()`

### 7.5 YouTube Likes

`YouTubeLikesDao` (in `lib/database/youtube_likes_dao.dart`) stores: `video_id`, title, channel_title, thumbnail_url, youtube_url, created_at. No audio URLs, stream URLs, or download paths are stored.

### 7.6 Polymorphic Playlist Items

`PlaylistItem` (in `lib/models/playlist_item.dart`) with `source_type` (authorized/youtube) and `source_id`:

- `PlaylistItem.fromSong()` factory — creates an authorized item
- `PlaylistItem.fromYouTube()` factory — creates a YouTube item
- `resolveSong()` — resolves to a `Song` if authorized
- `resolveYouTube()` — resolves to a `YouTubeMusicResult` if YouTube

`PlaylistDao` uses the `playlist_items` table with backward compatibility to `playlist_songs`. Playlists can contain mixed Musi songs and YouTube videos.

### 7.7 Library Service Extensions

`LibraryService` (in `lib/services/library_service.dart`) provides:

- `init()` — loads all persistent data from SQLite
- `likedSongs`, `downloadedSongs`, `recentlyPlayed`, `likedYouTubeVideos`, `recentlyPlayedYouTube`, `playlists`
- `isLiked(songId)` — transparent handling of `yt_` prefix song IDs
- `isDownloaded(songId)`
- `toggleLike(song)` — transparent handling of YouTube songs
- `toggleYouTubeLike(video)`
- `toggleDownload(song, onError)`
- `addRecentlyPlayed(song)`
- `addRecentlyPlayedYouTube(video)`
- `createPlaylist(name)`, `renamePlaylist(id, name)`, `deletePlaylist(id)`
- `addSongToPlaylist(playlistId, song)` — automatically detects YouTube songs and routes to `addYouTubeToPlaylist`
- `addYouTubeToPlaylist(playlistId, video)`
- `removeSongFromPlaylist(playlistId, songId)`
- `removeYouTubeFromPlaylist(playlistId, videoId)`
- `reorderPlaylistSongs(playlistId, orderedSongIds)`
- `reorderPlaylistItems(playlistId, orderedSourceIds, orderedSourceTypes)` — for mixed playlists
- `getPlaylistItems(playlistId)` — returns full playlist with YouTube items

---

## 8. User Flows

### 8.1 Search for a song

1. User opens **Search**.
2. User enters `Starboy` or `Starboy The Weeknd`.
3. The UI waits 300 ms after typing stops.
4. `SearchScreen` checks `MusicCacheDao.searchCache()` for cached results (shows "Showing cached results" indicator if found).
5. `MusicProviderManager.searchAll()` searches authorized providers and YouTube independently.
6. Authorized songs appear under **Playable in Musi**.
7. YouTube videos appear under **YouTube Music** with a source badge, inline play/pause, and action menu.
8. Tapping a YouTube result plays audio in-place via `PlayerService.playYouTubeAudio()`.

### 8.2 Play authorized Musi audio

1. User taps an authorized song tile.
2. `SongTile` calls `PlayerService.playSong()`.
3. `PlayerService` updates the queue and state.
4. `MusiAudioHandler` loads the permitted stream through `just_audio`.
5. `audio_service` provides the Android media session and background playback.

### 8.3 Play YouTube audio (background)

1. User taps a YouTube result tile or presses play.
2. `SearchScreen` calls `PlayerService.playYouTubeAudio(video)`.
3. `PlayerService` calls `YouTubeAudioService.resolveToSong(video)` to extract an audio stream URL.
4. The video is converted to a `Song` (id `yt_<videoId>`).
5. `MusiAudioHandler` plays the stream through `just_audio` with YouTube User-Agent headers.
6. `audio_service` provides Android media notification and lock screen controls.
7. The MiniPlayer shows the YouTube track with progress and controls.

### 8.4 Offline mode

When offline mode is enabled:

- downloaded authorized tracks remain searchable and playable;
- network provider searches are skipped;
- YouTube search and playback are unavailable.

---

## 9. Home Screen

`lib/screens/home_screen.dart` is a `StatefulWidget` with:

- **Top 10 YouTube Trending Hits** — fetched via `YouTubeMusicApiService.getTrendingHits(limit: 10)` with dual-strategy fallback (Chaquopy Python bridge + `YoutubeExplode`). Rendered as `YouTubeResultTile` widgets with inline play/pause buttons and a **Play All** button to queue all 10 tracks.
- **Liked Songs** spotlight banner with play-all action. The banner count and play-all queue now include liked YouTube videos (from `LibraryService.likedYouTubeVideos`) converted to `yt_<videoId>` `Song` objects and routed through `PlayerService.playYouTubeAudio()`.
- **Recently Played** section (only shown when real history exists in SQLite).
- **Your Playlists** horizontal carousel.
- **Downloads & Offline** section (only shown when downloads exist).
- Pull-to-refresh (`RefreshIndicator`) for trending tracks.
- Shimmer skeleton placeholder while trending tracks load.

The mock catalog (`MockMusicService.mockCatalog`) is used as a fallback for Jamendo searches but is no longer displayed as a homepage section.

### 9.1 Library Screen

`lib/screens/library_screen.dart` provides 5 tabs: Playlists, Liked, Recent, YouTube, and Downloads.

The **Liked** and **Recently Played** tabs render mixed content using `YouTubeResultTile` widgets for YouTube items. These tiles receive:

- `isLiked` — computed from `LibraryService.isLiked(video.videoId)` to reflect correct like state
- `onLike` — bound to `LibraryService.toggleYouTubeLike(video)` for immediate persistence toggle
- `onTap` — plays audio in-place via `PlayerService.playYouTubeAudio(video)`

When a user likes/unlikes a YouTube video from these tabs, the `liked_youtube` table is updated and the `YouTubeVideo` model's like state reflects correctly in `isLiked()` checks.

The **YouTube** tab shows all liked YouTube videos.

---

## 10. Files Created or Added for YouTube

| File | Responsibility |
|---|---|
| `lib/services/youtube_music_api_service.dart` | YouTube Music search, trending, stream URL fetching via `yt_flutter_musicapi` and `YoutubeExplode` |
| `lib/services/youtube_audio_service.dart` | Audio stream URL resolution (itag 140 MP4/AAC, fallbacks), in-memory caching, `Song` conversion |
| `lib/models/youtube_music_result.dart` | Separate YouTube metadata model with `streamUrl = null` |
| `lib/services/youtube_playback_service.dart` | Audio playback active-state indicator |
| `lib/widgets/youtube_result_tile.dart` | YouTube-specific search result tile with inline play, like, playlist, and overflow actions |
| `lib/models/music_cache_entry.dart` | Cache entry model with `sourceType`, `CachedSourceType` enum, factories |
| `lib/models/playlist_item.dart` | Polymorphic playlist item model with `fromSong`/`fromYouTube` factories |
| `lib/database/music_cache_dao.dart` | Search result caching DAO |
| `lib/database/search_history_dao.dart` | Search history DAO |
| `lib/database/youtube_likes_dao.dart` | YouTube likes persistence DAO |
| `lib/database/musi_database.dart` | Database schema (v4) with all tables and migrations |
| `lib/database/playlist_dao.dart` | Updated with polymorphic playlist items, backward compatibility |
| `lib/database/provider_dao.dart` | Provider seeding and enablement |
| `lib/database/song_dao.dart` | Song persistence (upsert, like, recent, download status) |
| `lib/database/settings_dao.dart` | Settings including `youtube_enabled`, `offline_mode`, audio quality |
| `lib/services/music_item_resolver.dart` | Central playback routing service |
| `lib/screens/playlist_picker_sheet.dart` | Bottom sheet for adding YouTube videos to playlists |

---

## 11. Files Modified for YouTube

| File | Change |
|---|---|
| `pubspec.yaml` | Added `yt_flutter_musicapi`, `youtube_explode_dart`, `url_launcher`; removed `youtube_player_iframe` (video player features removed) |
| `lib/services/youtube_audio_service.dart` | Multi-client fallback (`android` → `androidSdkless` → `ios` → `mweb`), `_validateStreamUrl()` HEAD-request validation, 90-minute cache, `validatePlayable()`, `filterPlayable()`, `youtubeUserAgent` constant |
| `lib/services/audio_handler.dart` | YouTube User-Agent via `AudioPlayer.userAgent` + `AudioSource.uri` headers, `useProxyForRequestHeaders: false` (bypasses failing proxy on OnePlus/Media3), YouTube origin/referer/client headers |
| `lib/services/player_service.dart` | `playYouTubeAudio()` with cache-invalidation retry on 403, player stop before playback to clear decoder errors, `_isBuffering` state, mixed queue support, `next()`/`previous()` use while-loop retry instead of recursion, auto-skip on track failure |
| `lib/services/music_item_resolver.dart` | `PlaybackResolution` with `playerService`/`unavailable` routes only (removed `youtubePlayer` route); YouTube resolution returns `unavailable` if stream validation fails for all clients |
| `lib/services/music_provider_manager.dart` | YouTube provider registration, `YouTubeMusicApiService` integration, `isYouTubeConfigured`, `filterPlayable()` pre-filtering for search and featured results |
| `lib/services/library_service.dart` | YouTube likes, playlist integration, `yt_` prefix handling in `isLiked`/`toggleLike`/`addSongToPlaylist`, `likedYouTubeVideos` and `recentlyPlayedYouTube` exposed |
| `lib/models/search_result.dart` | Added `YouTubeSearchResult` |
| `lib/screens/search_screen.dart` | Cache-first search, inline YouTube audio playback, merged result caching |
| `lib/screens/home_screen.dart` | YouTube trending hits section with Play All; pre-filters results via `filterPlayable()` to ensure only playable tracks displayed; liked songs banner includes YouTube videos in count and play-all queue via `playYouTubeAudio` |
| `lib/screens/player_screen.dart` | Removed "Watch Video" button for YouTube songs; Add to Playlist in action row |
| `lib/screens/library_screen.dart` | 5 tabs (Playlists, Liked, Recent, YouTube, Downloads); Liked and Recently Played tabs play audio for YouTube tiles; `tabIndexNotifier` for deep-linking to Liked tab |
| `lib/screens/playlist_screen.dart` | Mixed Song/YouTube playlist items with reorder and dismiss |
| `lib/widgets/youtube_result_tile.dart` | Inline play/pause with loading spinner, action menu; supports `isLiked`/`onLike` parameters for like state |
| `lib/widgets/song_tile.dart` | Provider badge, playability labels, download states |
| `lib/widgets/mini_player.dart` | Music playback indicator |
| `lib/models/playlist_item.dart` | PlaylistItem model with `fromYouTube`, `isAuthorized` flag |
| `lib/models/playlist.dart` | Playlist model with `coverUrl`, `totalDurationFormatted` |
| `lib/models/song.dart` | Added `providerId`, `providerName`, `canStream`, `canDownload`, `copyWith` |
| `lib/theme/app_theme.dart` | Warm amber/dark charcoal theme (amber primary/accent, warm charcoal backgrounds) |
| `lib/screens/youtube_player_screen.dart` | **Deleted** — iframe-based YouTube video player removed |
| `lib/services/youtube_playback_service.dart` | **Deleted** — YouTube video playback service removed |
| `documentation.md` | Updated throughout to reflect audio-only approach, removed video player references
| `.gitignore` | Ignores `.env` and related local environment files |

---

## 13. Theme & Colors

`lib/theme/app_theme.dart` defines the warm amber Musi dark aesthetic — glowing amber against deep charcoal, inspired by warm studio lighting.

| Variable | Color | Usage |
|---|---|---|
| `background` | `#0E0B07` (Deep warm charcoal) | Scaffold / app background |
| `surface` | `#161209` (Warm dark surface) | Navigation / tab backgrounds |
| `surfaceLight` | `#251D0F` (Lifted warm card) | Elevated surface variant |
| `surfaceCard` | `#1C1509` (Warm dark card) | Cards / tiles |
| `borderColor` | `#2E2410` (Warm border) | Subtle borders |
| `primary` | `#F59E0B` (Vivid amber) | Primary brand color, notification bar |
| `primaryLight` | `#FBBF24` (Gold) | Accents, highlights, bottom nav selected |
| `accent` | `#FBBF24` (Gold) | Like icons, accent buttons, mini player progress bar |
| `accentVibrant` | `#D97706` (Deep amber) | Gradients |
| `accentOrange` | `#EA580C` (Burnt orange) | Amber gradient highlights |
| `youtubeRed` | `#EF4444` | YouTube-specific badge and like emphasis |
| `error` | `#EF4444` | Error states, YouTube badge text/icons |
| `success` | `#34D399` (Teal) | Positive states |
| `textPrimary` | `#FFF8F0` (Warm white) | Primary text |
| `textSecondary` | `#B8A790` (Warm silver) | Secondary text |
| `textMuted` | `#7C6A52` (Warm muted) | Muted/disabled text |

### 13.1 Theme gradient and header colors

| Element | Color | File |
|---|---|---|
| Liked Songs banner | `#2C1A00` (amber gradient) | `home_screen.dart:331` |
| Player screen gradient | `#1E1200` → background (amber-tint) | `player_screen.dart:64` |
| Playlist header gradient | `#3D2200` → background (amber-brown) | `playlist_screen.dart:63` |
| Playlist tile gradient (cover) | `#3D2200` → background (amber-brown) | `playlist_tile.dart:33` |

---

## 14. Testing

### Automated tests

`test/unit_test.dart` covers:

- Song persistence (upsert, retrieve, like/unlike, recently played, downloads)
- Playlist create/rename/add/remove/reorder/delete (including polymorphic YouTube items)
- Settings persistence (offline mode, audio quality, volume normalization)
- Queue, repeat modes, and shuffle controls
- Jamendo fallback behavior
- MusicCacheDao (upsert, search, update last played)
- SearchHistoryDao (save, retrieve, clear, duplicates)
- YouTubeLikesDao (like, unlike, retrieve)
- PlaylistItem (fromSong/fromYouTube factories, copyWith)
- MusicItemResolver (singleton instance)
- YouTubeAudioService (isYouTubeSong, extractVideoId)
- LibraryService (YouTube like sync via `yt_` prefix, playlist item conversion)

`test/widget_test.dart` verifies app startup, navigation tabs, and search entry using a mock HTTP client.

### Verification status

| Check | Status | Notes |
|---|---|---|
| `dart format .` | **Pass** | All files formatted cleanly |
| `flutter analyze` | **Pass** | 0 issues found |
| `flutter test test/unit_test.dart` | **Pass** | All 21 unit tests pass |
| `flutter build apk --debug` | **Pass** | Debug APK built successfully |
| `flutter build apk --release` | **Pass** | Release APK built successfully |

### Test commands

```powershell
flutter test test/unit_test.dart
flutter test
```

---

## 15. Build and Development Commands

### Install dependencies

```powershell
flutter pub get
```

### Run

```powershell
flutter run
```

No special build defines are required. YouTube discovery and audio extraction work through `yt_flutter_musicapi` (Chaquopy Python bridge, Android-only) and `youtube_explode_dart` (pure Dart fallback).

### Analyze and format

```powershell
dart format .
flutter analyze
```

### Build APKs

```powershell
flutter build apk --debug
flutter build apk --release
```

---

## 16. Legal and Source Compliance

### Authorized Musi sources

- Jamendo provides Creative Commons music through its API.
- The built-in mock catalog uses public development/test audio sources (SoundHelix).
- Only provider-approved audio may be streamed or downloaded.

### YouTube

- YouTube is used for music discovery (YouTube Music search via `yt_flutter_musicapi`) and audio stream resolution (via `youtube_explode_dart`).
- YouTube audio is extracted as audio-only streams and routed through Musi's background audio pipeline (`just_audio` + `audio_service`) for lock screen controls and media notifications.
   - YouTube audio stream URLs are cached in-memory only (90-minute TTL) and never persisted to disk.
- YouTube content is never stored as a downloaded offline file and is unavailable in offline mode.
- YouTube content is always clearly labeled with the YouTube source badge and red accent color.

### No unauthorized behavior

Musi does not scrape unsupported services, bypass DRM, or use unofficial extraction tools beyond `youtube_explode_dart` (pure-Dart YouTube client) and `yt_flutter_musicapi` (ytmusicapi-based Python bridge).

---

## 17. Known Limitations

1. YouTube audio extraction uses `youtube_explode_dart` trying multiple API clients in order: `android` → `androidSdkless` → `ios` → `mweb`. This may break if YouTube changes its client tokens or CDN headers.
2. The `yt_flutter_musicapi` Python bridge (Chaquopy) is Android-only and may not initialize on all devices.
3. YouTube stream URLs expire; the service caches them for 90 minutes and retries with fresh resolution on playback failure.
4. ExoPlayer requires a mobile YouTube User-Agent header; without it, YouTube CDN returns HTTP 403. Headers are now passed directly via `DefaultHttpDataSource` (useProxyForRequestHeaders: false), bypassing the proxy mechanism that failed on OnePlus/Media3. Pre-validation via HEAD requests (`_validateStreamUrl`) provides an additional safety layer.
5. MP4/AAC streams (itag 140) are prioritized for native ExoPlayer support; WebM/Opus fallback may have reduced compatibility.
6. YouTube search depends on network availability and the Python bridge initialization.
7. YouTube search results are persisted in cache and liked videos are stored, but full playlist-style YouTube references require the `playlist_items` table.
8. The audio-quality setting is persisted in the UI but the current YouTube extraction does not select different stream qualities based on this setting.
9. Volume normalization is stored as a setting but is not connected to an audio effect.
10. YouTube playback is intentionally not available in offline mode.
11. The full widget test (`test/widget_test.dart`) uses a mock HTTP client and may require careful settling for `pumpAndSettle` on slower systems.
12. YouTube search no longer applies duration filtering (180–420 second limits removed); all search results are returned without duration constraints.
13. Pre-filter validation (`filterPlayable`) resolves stream URLs for all YouTube results before display, adding latency to initial result loading (concurrency-mitigated by validating up to 25 results in parallel).
14. Next/skip navigation uses a retry loop (max 20 attempts) to skip unplayable tracks; if all tracks fail, playback stops.

---

## 18. Final Acceptance Checklist

- [x] Search screen uses a 300 ms debounce.
- [x] Authorized providers and YouTube are searched through `MusicProviderManager`.
- [x] YouTube music search uses `yt_flutter_musicapi` with `youtube_explode_dart` fallback.
- [x] YouTube results are audio-only (no video player); played via background player.
- [x] YouTube results have `streamUrl = null` on the `YouTubeMusicResult` model.
- [x] YouTube results are visually labeled with source badge.
- [x] YouTube result tap plays audio in-place via background player.
- [x] YouTube audio is extracted as audio-only and routed through Musi's background audio pipeline.
- [x] YouTube has no download action.
- [x] YouTube is excluded from offline search.
- [x] YouTube audio is routed through `just_audio` with YouTube User-Agent.
- [x] YouTube audio is routed through `audio_service` for lock screen controls.
- [x] Existing authorized background playback remains supported.
- [x] YouTube provider can be disabled in settings.
- [x] YouTube search/audio failures fail gracefully.
- [x] YouTube API/search failures do not crash the app.
- [x] `music_cache`, `search_history`, `liked_youtube`, `playlist_items` tables are created.
- [x] Cache-first search with "Showing cached results" indicator.
- [x] Mixed playlists (Song + YouTube) supported.
- [x] 5-tab Library screen with YouTube liked videos.
- [x] Liked Songs banner on home screen includes YouTube videos in count and playback.
- [x] YouTube like actions work from library liked/recently played tabs (onLike and isLiked passed correctly).
- [x] All 21 unit tests pass.
- [x] Debug and release APK builds successful.
- [x] `dart format .` clean.
- [x] `flutter analyze` — 0 issues.
- [x] No hardcoded `Colors.purple`, `Colors.pinkAccent`, or `Colors.red` / `Colors.redAccent` remain in `lib/` (all replaced with `AppTheme` values).

---

## 19. Maintenance Notes

### YouTube audio stream resolution troubleshooting

If YouTube audio does not play in the background:

1. Confirm the device is Android (the Python bridge and stream extraction are Android-focused).
2. Confirm `yt_flutter_musicapi` and `youtube_explode_dart` are installed (`flutter pub get`).
3. Check the stream resolution logs for itag 140 (MP4/AAC) or fallback streams.
4. Check that `audio_handler.dart` sets the YouTube mobile User-Agent header.
5. Verify YouTube is enabled in **Settings → Music Sources**.
 6. Play a YouTube result and confirm background audio plays through the lock screen player.

### YouTube search troubleshooting

If YouTube results do not appear in search:

1. Confirm YouTube is enabled in **Settings → Music Sources**.
2. Confirm network connectivity.
3. The `yt_flutter_musicapi` bridge initializes on app startup; check logs for "YouTubeMusicApiService: initialized successfully".
4. If the Python bridge fails, the `youtube_explode_dart` fallback should still return results.
5. Confirm authorized providers (Jamendo) still work if only YouTube fails.

### General app troubleshooting

Inspect the current source files rather than searching for hardcoded credentials. No API keys or secrets are stored in the source code.

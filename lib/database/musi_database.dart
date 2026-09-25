import 'dart:async';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class MusiDatabase {
  static final MusiDatabase instance = MusiDatabase._init();
  static Database? _database;

  static const int _databaseVersion = 4;

  MusiDatabase._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('musi.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _createDB,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    // 1. Songs table
    await db.execute('''
      CREATE TABLE songs (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        artist TEXT NOT NULL,
        album TEXT,
        artwork_url TEXT,
        stream_url TEXT NOT NULL,
        source_url TEXT,
        local_path TEXT,
        duration INTEGER NOT NULL DEFAULT 0,
        is_liked INTEGER NOT NULL DEFAULT 0,
        is_downloaded INTEGER NOT NULL DEFAULT 0,
        provider_id TEXT,
        provider_name TEXT,
        license TEXT,
        can_stream INTEGER NOT NULL DEFAULT 1,
        can_download INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // 2. Liked Songs table
    await db.execute('''
      CREATE TABLE liked_songs (
        song_id TEXT PRIMARY KEY,
        created_at TEXT NOT NULL,
        FOREIGN KEY (song_id) REFERENCES songs (id) ON DELETE CASCADE
      )
    ''');

    // 3. Playlists table
    await db.execute('''
      CREATE TABLE playlists (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at TEXT NOT NULL,
        cover_url TEXT
      )
    ''');

    // 4. Playlist Songs junction table
    await db.execute('''
      CREATE TABLE playlist_songs (
        playlist_id TEXT NOT NULL,
        song_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        PRIMARY KEY (playlist_id, song_id),
        FOREIGN KEY (playlist_id) REFERENCES playlists (id) ON DELETE CASCADE,
        FOREIGN KEY (song_id) REFERENCES songs (id) ON DELETE CASCADE
      )
    ''');

    // 5. Recently Played table
    await db.execute('''
      CREATE TABLE recently_played (
        song_id TEXT PRIMARY KEY,
        played_at TEXT NOT NULL,
        FOREIGN KEY (song_id) REFERENCES songs (id) ON DELETE CASCADE
      )
    ''');

    // 6. Settings table
    await db.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    // 7. Providers table
    await db.execute('''
      CREATE TABLE providers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT NOT NULL,
        attribution_url TEXT,
        can_stream INTEGER NOT NULL DEFAULT 1,
        can_download INTEGER NOT NULL DEFAULT 0,
        enabled INTEGER NOT NULL DEFAULT 1
      )
    ''');

    // 8. Music Cache table (v3)
    await db.execute('''
      CREATE TABLE music_cache (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_type TEXT NOT NULL,
        source_id TEXT NOT NULL,
        title TEXT NOT NULL,
        artist TEXT,
        album TEXT,
        thumbnail_url TEXT,
        source_url TEXT,
        youtube_video_id TEXT,
        provider TEXT,
        duration INTEGER NOT NULL DEFAULT 0,
        cached_at TEXT NOT NULL,
        last_played_at TEXT,
        UNIQUE(source_type, source_id)
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_music_cache_source ON music_cache(source_type, source_id)
    ''');

    await db.execute('''
      CREATE INDEX idx_music_cache_last_played ON music_cache(last_played_at)
    ''');

    // 9. Search History table (v3)
    await db.execute('''
      CREATE TABLE search_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        query TEXT NOT NULL,
        searched_at TEXT NOT NULL,
        UNIQUE(query)
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_search_history_searched_at ON search_history(searched_at)
    ''');

    // 10. Liked YouTube table (v3)
    await db.execute('''
      CREATE TABLE liked_youtube (
        video_id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        channel_title TEXT NOT NULL,
        thumbnail_url TEXT,
        youtube_url TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');

    // 11. Playlist Items table (v3) - polymorphic playlist support
    await db.execute('''
      CREATE TABLE playlist_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        playlist_id TEXT NOT NULL,
        source_type TEXT NOT NULL,
        source_id TEXT NOT NULL,
        song_id TEXT,
        youtube_video_id TEXT,
        title TEXT NOT NULL,
        artist_channel TEXT,
        artwork_url TEXT,
        position INTEGER NOT NULL,
        added_at TEXT NOT NULL,
        FOREIGN KEY (playlist_id) REFERENCES playlists (id) ON DELETE CASCADE,
        FOREIGN KEY (song_id) REFERENCES songs (id) ON DELETE SET NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_playlist_items_playlist ON playlist_items(playlist_id)
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Migration from v1 to v2: add provider/license columns to songs table
      await db.execute('ALTER TABLE songs ADD COLUMN provider_id TEXT');
      await db.execute('ALTER TABLE songs ADD COLUMN provider_name TEXT');
      await db.execute('ALTER TABLE songs ADD COLUMN license TEXT');
      await db.execute(
        'ALTER TABLE songs ADD COLUMN can_stream INTEGER NOT NULL DEFAULT 1',
      );
      await db.execute(
        'ALTER TABLE songs ADD COLUMN can_download INTEGER NOT NULL DEFAULT 0',
      );

      // Create providers table
      await db.execute('''
        CREATE TABLE providers (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          description TEXT NOT NULL,
          attribution_url TEXT,
          can_stream INTEGER NOT NULL DEFAULT 1,
          can_download INTEGER NOT NULL DEFAULT 0,
          enabled INTEGER NOT NULL DEFAULT 1
        )
      ''');
    }
    if (oldVersion < 3) {
      // Migration from v2 to v3: add music_cache, search_history, liked_youtube, and playlist_items tables
      await db.execute('''
        CREATE TABLE music_cache (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          source_type TEXT NOT NULL,
          source_id TEXT NOT NULL,
          title TEXT NOT NULL,
          artist TEXT,
          album TEXT,
          thumbnail_url TEXT,
          source_url TEXT,
          youtube_video_id TEXT,
          provider TEXT,
          duration INTEGER NOT NULL DEFAULT 0,
          cached_at TEXT NOT NULL,
          last_played_at TEXT,
          UNIQUE(source_type, source_id)
        )
      ''');

      await db.execute('''
        CREATE INDEX idx_music_cache_source ON music_cache(source_type, source_id)
      ''');

      await db.execute('''
        CREATE INDEX idx_music_cache_last_played ON music_cache(last_played_at)
      ''');

      await db.execute('''
        CREATE TABLE search_history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          query TEXT NOT NULL,
          searched_at TEXT NOT NULL,
          UNIQUE(query)
        )
      ''');

      await db.execute('''
        CREATE INDEX idx_search_history_searched_at ON search_history(searched_at)
      ''');

      await db.execute('''
        CREATE TABLE liked_youtube (
          video_id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          channel_title TEXT NOT NULL,
          thumbnail_url TEXT,
          youtube_url TEXT NOT NULL,
          created_at TEXT NOT NULL
        )
      ''');

      // Create new playlist_items table to replace playlist_songs (supports both Song and YouTube)
      await db.execute('''
        CREATE TABLE playlist_items (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          playlist_id TEXT NOT NULL,
          source_type TEXT NOT NULL,
          source_id TEXT NOT NULL,
          song_id TEXT,
          youtube_video_id TEXT,
          title TEXT NOT NULL,
          artist_channel TEXT,
          artwork_url TEXT,
          position INTEGER NOT NULL,
          added_at TEXT NOT NULL,
          FOREIGN KEY (playlist_id) REFERENCES playlists (id) ON DELETE CASCADE,
          FOREIGN KEY (song_id) REFERENCES songs (id) ON DELETE SET NULL
        )
      ''');

      await db.execute('''
        CREATE INDEX idx_playlist_items_playlist ON playlist_items(playlist_id)
      ''');

      // Migrate existing playlist_songs data to playlist_items
      await db.execute('''
        INSERT INTO playlist_items (playlist_id, source_type, source_id, song_id, title, artist_channel, artwork_url, position, added_at)
        SELECT ps.playlist_id, 'authorized' as source_type, s.id as source_id, s.id as song_id, s.title, s.artist as artist_channel, s.artwork_url as artwork_url, ps.position, datetime('now') as added_at
        FROM playlist_songs ps
        INNER JOIN songs s ON ps.song_id = s.id
      ''');

      // Keep the old playlist_songs table for backward compatibility during transition
      // We'll remove it in a future version after confirming migration works
    }
    if (oldVersion < 4) {
      // Migration from v3 to v4: create tables that were missing from onCreate in v3
      // This handles fresh installs where onCreate ran at v3 but didn't have v3 tables
      await db.execute('''
        CREATE TABLE IF NOT EXISTS music_cache (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          source_type TEXT NOT NULL,
          source_id TEXT NOT NULL,
          title TEXT NOT NULL,
          artist TEXT,
          album TEXT,
          thumbnail_url TEXT,
          source_url TEXT,
          youtube_video_id TEXT,
          provider TEXT,
          duration INTEGER NOT NULL DEFAULT 0,
          cached_at TEXT NOT NULL,
          last_played_at TEXT,
          UNIQUE(source_type, source_id)
        )
      ''');

      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_music_cache_source ON music_cache(source_type, source_id)
      ''');

      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_music_cache_last_played ON music_cache(last_played_at)
      ''');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS search_history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          query TEXT NOT NULL,
          searched_at TEXT NOT NULL,
          UNIQUE(query)
        )
      ''');

      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_search_history_searched_at ON search_history(searched_at)
      ''');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS liked_youtube (
          video_id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          channel_title TEXT NOT NULL,
          thumbnail_url TEXT,
          youtube_url TEXT NOT NULL,
          created_at TEXT NOT NULL
        )
      ''');

      // Create new playlist_items table to replace playlist_songs (supports both Song and YouTube)
      await db.execute('''
        CREATE TABLE IF NOT EXISTS playlist_items (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          playlist_id TEXT NOT NULL,
          source_type TEXT NOT NULL,
          source_id TEXT NOT NULL,
          song_id TEXT,
          youtube_video_id TEXT,
          title TEXT NOT NULL,
          artist_channel TEXT,
          artwork_url TEXT,
          position INTEGER NOT NULL,
          added_at TEXT NOT NULL,
          FOREIGN KEY (playlist_id) REFERENCES playlists (id) ON DELETE CASCADE,
          FOREIGN KEY (song_id) REFERENCES songs (id) ON DELETE SET NULL
        )
      ''');

      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_playlist_items_playlist ON playlist_items(playlist_id)
      ''');
    }
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }
}

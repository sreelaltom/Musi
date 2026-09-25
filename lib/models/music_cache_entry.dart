import 'package:flutter/foundation.dart';

import 'youtube_music_result.dart';
import 'song.dart';

enum CachedSourceType { authorized, youtube }

extension CachedSourceTypeX on CachedSourceType {
  String get value {
    switch (this) {
      case CachedSourceType.authorized:
        return 'authorized';
      case CachedSourceType.youtube:
        return 'youtube';
    }
  }

  static CachedSourceType fromString(String value) {
    switch (value) {
      case 'authorized':
        return CachedSourceType.authorized;
      case 'youtube':
        return CachedSourceType.youtube;
      default:
        return CachedSourceType.authorized;
    }
  }
}

@immutable
class MusicCacheEntry {
  final int? id;
  final CachedSourceType sourceType;
  final String sourceId;
  final String title;
  final String? artist;
  final String? album;
  final String? thumbnailUrl;
  final String? sourceUrl;
  final String? youtubeVideoId;
  final String? provider;
  final int duration;
  final DateTime cachedAt;
  final DateTime? lastPlayedAt;

  const MusicCacheEntry({
    this.id,
    required this.sourceType,
    required this.sourceId,
    required this.title,
    this.artist,
    this.album,
    this.thumbnailUrl,
    this.sourceUrl,
    this.youtubeVideoId,
    this.provider,
    this.duration = 0,
    required this.cachedAt,
    this.lastPlayedAt,
  });

  bool get isAuthorized => sourceType == CachedSourceType.authorized;
  bool get isYouTube => sourceType == CachedSourceType.youtube;

  String get cacheKey => '${sourceType.value}:$sourceId';

  bool isStale({Duration maxAge = const Duration(days: 7)}) {
    return DateTime.now().difference(cachedAt) > maxAge;
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'source_type': sourceType.value,
      'source_id': sourceId,
      'title': title,
      'artist': artist,
      'album': album,
      'thumbnail_url': thumbnailUrl,
      'source_url': sourceUrl,
      'youtube_video_id': youtubeVideoId,
      'provider': provider,
      'duration': duration,
      'cached_at': cachedAt.toIso8601String(),
      'last_played_at': lastPlayedAt?.toIso8601String(),
    };
  }

  factory MusicCacheEntry.fromMap(Map<String, dynamic> map) {
    return MusicCacheEntry(
      id: map['id'] as int?,
      sourceType: CachedSourceTypeX.fromString(map['source_type'] as String),
      sourceId: map['source_id'] as String,
      title: map['title'] as String,
      artist: map['artist'] as String?,
      album: map['album'] as String?,
      thumbnailUrl: map['thumbnail_url'] as String?,
      sourceUrl: map['source_url'] as String?,
      youtubeVideoId: map['youtube_video_id'] as String?,
      provider: map['provider'] as String?,
      duration: (map['duration'] as num?)?.toInt() ?? 0,
      cachedAt:
          DateTime.tryParse(map['cached_at'] as String? ?? '') ??
          DateTime.now(),
      lastPlayedAt: map['last_played_at'] != null
          ? DateTime.tryParse(map['last_played_at'] as String)
          : null,
    );
  }

  factory MusicCacheEntry.fromSong({
    required Song song,
    required String provider,
  }) {
    return MusicCacheEntry(
      sourceType: CachedSourceType.authorized,
      sourceId: song.id,
      title: song.title,
      artist: song.artist,
      album: song.album,
      thumbnailUrl: song.artworkUrl,
      sourceUrl: song.sourceUrl,
      provider: provider,
      duration: song.duration,
      cachedAt: DateTime.now(),
    );
  }

  factory MusicCacheEntry.fromYouTube({required YouTubeMusicResult video}) {
    return MusicCacheEntry(
      sourceType: CachedSourceType.youtube,
      sourceId: video.videoId,
      title: video.title,
      artist: video.channelTitle,
      thumbnailUrl: video.thumbnailUrl,
      sourceUrl: video.youtubeUrl,
      youtubeVideoId: video.videoId,
      provider: 'youtube',
      duration: 0,
      cachedAt: DateTime.now(),
    );
  }

  MusicCacheEntry copyWith({
    int? id,
    CachedSourceType? sourceType,
    String? sourceId,
    String? title,
    String? artist,
    String? album,
    String? thumbnailUrl,
    String? sourceUrl,
    String? youtubeVideoId,
    String? provider,
    int? duration,
    DateTime? cachedAt,
    DateTime? lastPlayedAt,
  }) {
    return MusicCacheEntry(
      id: id ?? this.id,
      sourceType: sourceType ?? this.sourceType,
      sourceId: sourceId ?? this.sourceId,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      youtubeVideoId: youtubeVideoId ?? this.youtubeVideoId,
      provider: provider ?? this.provider,
      duration: duration ?? this.duration,
      cachedAt: cachedAt ?? this.cachedAt,
      lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MusicCacheEntry &&
          runtimeType == other.runtimeType &&
          sourceType == other.sourceType &&
          sourceId == other.sourceId;

  @override
  int get hashCode => Object.hash(sourceType, sourceId);

  @override
  String toString() =>
      'MusicCacheEntry(id: $id, sourceType: $sourceType, sourceId: $sourceId, title: $title, cachedAt: $cachedAt)';
}

import 'song.dart';
import 'youtube_music_result.dart';

enum PlaylistItemSourceType { authorized, youtube }

extension PlaylistItemSourceTypeX on PlaylistItemSourceType {
  String get value {
    switch (this) {
      case PlaylistItemSourceType.authorized:
        return 'authorized';
      case PlaylistItemSourceType.youtube:
        return 'youtube';
    }
  }

  static PlaylistItemSourceType fromString(String value) {
    switch (value) {
      case 'authorized':
        return PlaylistItemSourceType.authorized;
      case 'youtube':
        return PlaylistItemSourceType.youtube;
      default:
        return PlaylistItemSourceType.authorized;
    }
  }
}

class PlaylistItem {
  final int? id;
  final String playlistId;
  final PlaylistItemSourceType sourceType;
  final String sourceId;
  final String? songId;
  final String? youtubeVideoId;
  final String title;
  final String? artistChannel;
  final String? artworkUrl;
  final int position;
  final DateTime addedAt;

  const PlaylistItem({
    this.id,
    required this.playlistId,
    required this.sourceType,
    required this.sourceId,
    this.songId,
    this.youtubeVideoId,
    required this.title,
    this.artistChannel,
    this.artworkUrl,
    required this.position,
    required this.addedAt,
  });

  bool get isAuthorized => sourceType == PlaylistItemSourceType.authorized;
  bool get isYouTube => sourceType == PlaylistItemSourceType.youtube;

  Song? resolveSong() {
    if (isAuthorized && songId != null) {
      return Song(
        id: songId!,
        title: title,
        artist: artistChannel ?? '',
        artworkUrl: artworkUrl,
        streamUrl: '',
        duration: 0,
      );
    }
    return null;
  }

  YouTubeMusicResult? resolveYouTube() {
    if (isYouTube && youtubeVideoId != null) {
      return YouTubeMusicResult(
        videoId: youtubeVideoId!,
        title: title,
        channelTitle: artistChannel ?? '',
        thumbnailUrl: artworkUrl ?? '',
        youtubeUrl: 'https://www.youtube.com/watch?v=$youtubeVideoId',
      );
    }
    return null;
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'playlist_id': playlistId,
      'source_type': sourceType.value,
      'source_id': sourceId,
      'song_id': songId,
      'youtube_video_id': youtubeVideoId,
      'title': title,
      'artist_channel': artistChannel,
      'artwork_url': artworkUrl,
      'position': position,
      'added_at': addedAt.toIso8601String(),
    };
  }

  factory PlaylistItem.fromMap(Map<String, dynamic> map) {
    return PlaylistItem(
      id: map['id'] as int?,
      playlistId: map['playlist_id'] as String,
      sourceType: PlaylistItemSourceTypeX.fromString(
        map['source_type'] as String,
      ),
      sourceId: map['source_id'] as String,
      songId: map['song_id'] as String?,
      youtubeVideoId: map['youtube_video_id'] as String?,
      title: map['title'] as String,
      artistChannel: map['artist_channel'] as String?,
      artworkUrl: map['artwork_url'] as String?,
      position: (map['position'] as num?)?.toInt() ?? 0,
      addedAt:
          DateTime.tryParse(map['added_at'] as String? ?? '') ?? DateTime.now(),
    );
  }

  factory PlaylistItem.fromSong({
    required String playlistId,
    required Song song,
    required int position,
  }) {
    return PlaylistItem(
      playlistId: playlistId,
      sourceType: PlaylistItemSourceType.authorized,
      sourceId: song.id,
      songId: song.id,
      title: song.title,
      artistChannel: song.artist,
      artworkUrl: song.artworkUrl,
      position: position,
      addedAt: DateTime.now(),
    );
  }

  factory PlaylistItem.fromYouTube({
    required String playlistId,
    required YouTubeMusicResult video,
    required int position,
  }) {
    return PlaylistItem(
      playlistId: playlistId,
      sourceType: PlaylistItemSourceType.youtube,
      sourceId: video.videoId,
      youtubeVideoId: video.videoId,
      title: video.title,
      artistChannel: video.channelTitle,
      artworkUrl: video.thumbnailUrl,
      position: position,
      addedAt: DateTime.now(),
    );
  }

  PlaylistItem copyWith({
    int? id,
    String? playlistId,
    PlaylistItemSourceType? sourceType,
    String? sourceId,
    String? songId,
    String? youtubeVideoId,
    String? title,
    String? artistChannel,
    String? artworkUrl,
    int? position,
    DateTime? addedAt,
  }) {
    return PlaylistItem(
      id: id ?? this.id,
      playlistId: playlistId ?? this.playlistId,
      sourceType: sourceType ?? this.sourceType,
      sourceId: sourceId ?? this.sourceId,
      songId: songId ?? this.songId,
      youtubeVideoId: youtubeVideoId ?? this.youtubeVideoId,
      title: title ?? this.title,
      artistChannel: artistChannel ?? this.artistChannel,
      artworkUrl: artworkUrl ?? this.artworkUrl,
      position: position ?? this.position,
      addedAt: addedAt ?? this.addedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaylistItem &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          playlistId == other.playlistId &&
          sourceId == other.sourceId;

  @override
  int get hashCode => Object.hash(id, playlistId, sourceId);

  @override
  String toString() =>
      'PlaylistItem(id: $id, playlistId: $playlistId, sourceType: $sourceType, sourceId: $sourceId, title: $title)';
}

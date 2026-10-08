import 'dart:convert';

import 'song.dart';
import 'youtube_music_result.dart';

class ArtistMixRecent {
  final String artist;
  final List<Song> songs;
  final List<YouTubeMusicResult> videos;
  final DateTime playedAt;

  const ArtistMixRecent({
    required this.artist,
    required this.songs,
    required this.videos,
    required this.playedAt,
  });

  factory ArtistMixRecent.fromMap(Map<String, Object?> map) {
    final tracks = jsonDecode(map['tracks_json']! as String) as Map;
    final songs = (tracks['songs'] as List? ?? const [])
        .whereType<Map>()
        .map((track) => _songFromJson(track))
        .toList();
    final videos = (tracks['videos'] as List? ?? const [])
        .whereType<Map>()
        .map((track) => _videoFromJson(track))
        .toList();
    return ArtistMixRecent(
      artist: map['artist']! as String,
      songs: songs,
      videos: videos,
      playedAt:
          DateTime.tryParse(map['played_at']! as String) ?? DateTime.now(),
    );
  }

  static Map<String, Object?> toMap({
    required String artist,
    required List<Song> songs,
    required List<YouTubeMusicResult> videos,
    required DateTime playedAt,
  }) => {
    'mix_id': artist
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim(),
    'artist': artist,
    'tracks_json': jsonEncode({
      'songs': songs.map(_songToJson).toList(),
      'videos': videos.map(_videoToJson).toList(),
    }),
    'played_at': playedAt.toIso8601String(),
  };

  static Map<String, Object?> _songToJson(Song song) => {
    'id': song.id,
    'title': song.title,
    'artist': song.artist,
    'album': song.album,
    'artworkUrl': song.artworkUrl,
    'streamUrl': song.streamUrl,
    'sourceUrl': song.sourceUrl,
    'duration': song.duration,
    'providerId': song.providerId,
    'providerName': song.providerName,
    'canStream': song.canStream,
    'canDownload': song.canDownload,
  };

  static Song _songFromJson(Map track) => Song(
    id: track['id'] as String? ?? '',
    title: track['title'] as String? ?? 'Unknown Title',
    artist: track['artist'] as String? ?? '',
    album: track['album'] as String?,
    artworkUrl: track['artworkUrl'] as String?,
    streamUrl: track['streamUrl'] as String? ?? '',
    sourceUrl: track['sourceUrl'] as String?,
    duration: (track['duration'] as num?)?.toInt() ?? 0,
    providerId: track['providerId'] as String?,
    providerName: track['providerName'] as String?,
    canStream: track['canStream'] as bool? ?? true,
    canDownload: track['canDownload'] as bool? ?? false,
  );

  static Map<String, Object?> _videoToJson(YouTubeMusicResult video) => {
    'videoId': video.videoId,
    'title': video.title,
    'channelTitle': video.channelTitle,
    'thumbnailUrl': video.thumbnailUrl,
    'description': video.description,
    'publishedAt': video.publishedAt?.toIso8601String(),
    'youtubeUrl': video.youtubeUrl,
    'durationSeconds': video.durationSeconds,
  };

  static YouTubeMusicResult _videoFromJson(Map track) {
    final id = track['videoId'] as String? ?? '';
    return YouTubeMusicResult(
      videoId: id,
      title: track['title'] as String? ?? 'Unknown Title',
      channelTitle: track['channelTitle'] as String? ?? '',
      thumbnailUrl: track['thumbnailUrl'] as String? ?? '',
      description: track['description'] as String?,
      publishedAt: DateTime.tryParse(track['publishedAt'] as String? ?? ''),
      youtubeUrl:
          track['youtubeUrl'] as String? ??
          'https://www.youtube.com/watch?v=$id',
      durationSeconds: (track['durationSeconds'] as num?)?.toInt(),
    );
  }
}

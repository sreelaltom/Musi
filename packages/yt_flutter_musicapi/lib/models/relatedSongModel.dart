/// Data class for Related Songs
class RelatedSong {
  final String title;
  final String artists;
  final String videoId;
  final String? duration;
  final String? albumArt;
  final String? audioUrl;
  final bool isOriginal;

  RelatedSong({
    required this.title,
    required this.artists,
    required this.videoId,
    this.duration,
    this.albumArt,
    this.audioUrl,
    this.isOriginal = false,
  });

  factory RelatedSong.fromMap(Map<String, dynamic> map) {
    return RelatedSong(
      title: map['title']?.toString() ?? 'Unknown',
      artists: map['artists']?.toString() ?? 'Unknown',
      videoId: map['videoId']?.toString() ?? '',
      duration: map['duration']?.toString(),
      albumArt: map['albumArt']?.toString(),
      audioUrl: map['audioUrl']?.toString(),
      isOriginal: map['isOriginal'] is bool
          ? map['isOriginal'] as bool
          : (map['isOriginal']?.toString().toLowerCase() == 'true'),
    );
  }
}

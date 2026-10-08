/// Data class for Artist Songs
class ArtistSong {
  final String title;
  final String artists;
  final String videoId;
  final String? duration;
  final String? albumArt;
  final String? audioUrl;
  final String artistName;

  ArtistSong({
    required this.title,
    required this.artists,
    required this.videoId,
    this.duration,
    this.albumArt,
    this.audioUrl,
    required this.artistName,
  });

  // Update ArtistSong model
  factory ArtistSong.fromMap(Map<String, dynamic> map) {
    return ArtistSong(
      title: map['title']?.toString() ?? 'Unknown',
      artists: map['artists']?.toString() ?? 'Unknown',
      videoId: map['videoId']?.toString() ?? '',
      duration: map['duration']?.toString(),
      albumArt: map['albumArt']?.toString(),
      audioUrl: map['audioUrl']?.toString(),
      artistName: map['artistName']?.toString() ??
          map['artists']?.toString() ??
          'Unknown',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'artists': artists,
      'videoId': videoId,
      'duration': duration,
      'albumArt': albumArt,
      'audioUrl': audioUrl,
      'artistName': artistName,
    };
  }

  @override
  String toString() {
    return 'ArtistSong(title: $title, artists: $artists, videoId: $videoId, duration: $duration, albumArt: $albumArt, audioUrl: $audioUrl, artistName: $artistName)';
  }
}

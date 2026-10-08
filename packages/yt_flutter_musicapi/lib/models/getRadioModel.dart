class RadioTrack {
  final String title;
  final String artists;
  final String videoId;
  final String duration;
  final String albumArt;
  final String audioUrl;
  final String artistName;
  final String year;

  RadioTrack({
    required this.title,
    required this.artists,
    required this.videoId,
    required this.duration,
    required this.albumArt,
    required this.audioUrl,
    required this.artistName,
    required this.year,
  });

  factory RadioTrack.fromMap(Map<String, dynamic> map) {
    return RadioTrack(
      title: map['title']?.toString() ?? 'Unknown',
      artists: map['artists']?.toString() ?? 'Unknown',
      videoId: map['videoId']?.toString() ?? '',
      duration: map['duration']?.toString() ?? '',
      albumArt: map['albumArt']?.toString() ?? '',
      audioUrl: map['audioUrl']?.toString() ?? '',
      artistName: map['artistName']?.toString() ?? 'Unknown',
      year: map['year']?.toString() ?? '',
    );
  }
}

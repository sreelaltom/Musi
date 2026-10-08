/// Data class for Search Results
class SearchResult {
  final String title;
  final String artists;
  final String videoId;
  final String? duration;
  final String? year;
  final String? albumArt;
  final String? audioUrl;

  SearchResult({
    required this.title,
    required this.artists,
    required this.videoId,
    this.duration,
    this.year,
    this.albumArt,
    this.audioUrl,
  });

  factory SearchResult.fromMap(Map<String, dynamic> map) {
    return SearchResult(
      title: map['title'] as String? ?? 'Unknown',
      artists: map['artists'] as String? ?? 'Unknown',
      videoId: map['videoId'] as String? ?? '',
      duration: map['duration'] as String?,
      year: map['year'] as String?,
      albumArt: map['albumArt'] as String?,
      audioUrl: map['audioUrl'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'artists': artists,
      'videoId': videoId,
      'duration': duration,
      'year': year,
      'albumArt': albumArt,
      'audioUrl': audioUrl,
    };
  }

  @override
  String toString() {
    return 'SearchResult(title: $title, artists: $artists, videoId: $videoId, duration: $duration, year: $year, albumArt: $albumArt, audioUrl: $audioUrl)';
  }
}

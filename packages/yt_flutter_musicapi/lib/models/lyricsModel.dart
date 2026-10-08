/// Data class for Lyrics
class Lyrics {
  final String text;
  final String source;
  final String? language;

  final String songName;
  final String artistName;

  Lyrics({
    required this.text,
    required this.source,
    this.language,
    required this.songName,
    required this.artistName,
  });

  factory Lyrics.fromMap(Map<String, dynamic> map) {
    return Lyrics(
      text: map['lyrics']?.toString() ?? '',
      source: map['source']?.toString() ?? 'YTMusic',
      language: map['language']?.toString(),
      songName: map['songName']?.toString() ?? 'Unknown',
      artistName: map['artistName']?.toString() ?? 'Unknown',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'lyrics': text,
      'source': source,
      'language': language,
      'songName': songName,
      'artistName': artistName,
    };
  }

  @override
  String toString() {
    return 'Lyrics(text: ${text.length > 20 ? '${text.substring(0, 20)}...' : text}, '
        'source: $source, language: $language'
        'songName: $songName, artistName: $artistName)';
  }
}

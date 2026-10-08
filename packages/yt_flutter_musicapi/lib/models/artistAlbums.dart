class ArtistAlbum {
  final String type;
  final String title;
  final String artist;
  final String year;
  final String albumArt;
  final List<AlbumTrack> tracks;

  ArtistAlbum({
    required this.type,
    required this.title,
    required this.artist,
    required this.year,
    required this.albumArt,
    required this.tracks,
  });

  factory ArtistAlbum.fromMap(Map<String, dynamic> map) {
    final tracksData = map['tracks'] as List<dynamic>? ?? [];
    final tracks = tracksData
        .map((trackData) =>
            AlbumTrack.fromMap(Map<String, dynamic>.from(trackData)))
        .toList();

    return ArtistAlbum(
      type: map['type']?.toString() ?? 'album',
      title: map['title']?.toString() ?? 'Unknown Album',
      artist: map['artist']?.toString() ?? 'Unknown',
      year: map['year']?.toString() ?? '',
      albumArt: map['albumArt']?.toString() ?? '',
      tracks: tracks,
    );
  }
}

class AlbumTrack {
  final String title;
  final String artists;
  final String videoId;
  final String duration;
  final String albumArt;
  final String audioUrl;
  final String artistName;
  final String year;

  AlbumTrack({
    required this.title,
    required this.artists,
    required this.videoId,
    required this.duration,
    required this.albumArt,
    required this.audioUrl,
    required this.artistName,
    required this.year,
  });

  factory AlbumTrack.fromMap(Map<String, dynamic> map) {
    return AlbumTrack(
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

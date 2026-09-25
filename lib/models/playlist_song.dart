class PlaylistSong {
  final String playlistId;
  final String songId;
  final int position;

  const PlaylistSong({
    required this.playlistId,
    required this.songId,
    required this.position,
  });

  Map<String, dynamic> toMap() {
    return {'playlist_id': playlistId, 'song_id': songId, 'position': position};
  }

  factory PlaylistSong.fromMap(Map<String, dynamic> map) {
    return PlaylistSong(
      playlistId: map['playlist_id'] as String,
      songId: map['song_id'] as String,
      position: (map['position'] as num?)?.toInt() ?? 0,
    );
  }
}

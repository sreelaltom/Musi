import 'song.dart';

class Playlist {
  final String id;
  final String name;
  final DateTime createdAt;
  final List<Song> songs;
  final String? coverUrl;
  // Total item count including YouTube videos (songs.length alone misses them)
  final int? _itemCount;

  const Playlist({
    required this.id,
    required this.name,
    required this.createdAt,
    this.songs = const [],
    this.coverUrl,
    int? itemCount,
  }) : _itemCount = itemCount;

  /// Total items in playlist: songs + YouTube videos.
  int get songCount => _itemCount ?? songs.length;

  int get totalDurationSeconds =>
      songs.fold(0, (sum, song) => sum + song.duration);

  String get totalDurationFormatted {
    final minutes = totalDurationSeconds ~/ 60;
    return '$minutes mins';
  }

  Playlist copyWith({
    String? id,
    String? name,
    DateTime? createdAt,
    List<Song>? songs,
    String? coverUrl,
    int? itemCount,
  }) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      songs: songs ?? this.songs,
      coverUrl: coverUrl ?? this.coverUrl,
      itemCount: itemCount ?? _itemCount,
    );
  }

  Map<String, dynamic> toMap() {
    return {'id': id, 'name': name, 'created_at': createdAt.toIso8601String()};
  }

  factory Playlist.fromMap(
    Map<String, dynamic> map, {
    List<Song> songs = const [],
    int? itemCount,
  }) {
    return Playlist(
      id: map['id'] as String,
      name: map['name'] as String,
      createdAt:
          DateTime.tryParse(map['created_at'] as String? ?? '') ??
          DateTime.now(),
      songs: songs,
      itemCount: itemCount,
    );
  }
}

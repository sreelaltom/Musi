import 'package:flutter/foundation.dart';

import '../models/song.dart';
import '../models/youtube_music_result.dart';

@immutable
abstract class SearchResult {
  const SearchResult();
}

@immutable
class SongSearchResult extends SearchResult {
  final Song song;

  const SongSearchResult(this.song);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SongSearchResult &&
          runtimeType == other.runtimeType &&
          song == other.song;

  @override
  int get hashCode => song.hashCode;

  @override
  String toString() => 'SongSearchResult(${song.title})';
}

@immutable
class YouTubeSearchResult extends SearchResult {
  final YouTubeMusicResult video;

  const YouTubeSearchResult(this.video);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is YouTubeSearchResult &&
          runtimeType == other.runtimeType &&
          video == other.video;

  @override
  int get hashCode => video.hashCode;

  @override
  String toString() => 'YouTubeSearchResult(${video.title})';
}

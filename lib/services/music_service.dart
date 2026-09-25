import '../models/song.dart';

abstract class MusicService {
  Future<List<Song>> search(String query);
  Future<Song?> getSongDetails(String id);
  Future<List<Song>> getFeaturedSongs();
  Future<List<Song>> getTrendingSongs();
}

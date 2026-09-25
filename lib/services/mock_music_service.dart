import '../models/song.dart';
import 'music_service.dart';

class MockMusicService implements MusicService {
  static final List<Song> mockCatalog = [
    const Song(
      id: 'mock-1',
      title: 'Midnight Horizon',
      artist: 'Aetheric Sound',
      album: 'Neon Dreams',
      artworkUrl: 'https://images.unsplash.com/photo-1511671782779-c97d3d27a1d4?w=500&auto=format&fit=crop&q=80',
      streamUrl:
          'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3',
      sourceUrl: 'https://www.soundhelix.com',
      duration: 372,
      isLiked: true,
      isDownloaded: false,
    ),
    const Song(
      id: 'mock-2',
      title: 'Solar Eclipse',
      artist: 'Lunar Pulse',
      album: 'Cosmic Journey',
      artworkUrl: 'https://images.unsplash.com/photo-1470225620780-dba8ba36b745?w=500&auto=format&fit=crop&q=80',
      streamUrl:
          'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-2.mp3',
      sourceUrl: 'https://www.soundhelix.com',
      duration: 423,
      isLiked: false,
      isDownloaded: false,
    ),
    const Song(
      id: 'mock-3',
      title: 'Cybernetic Echoes',
      artist: 'Synthwave Odyssey',
      album: 'Retro Future',
      artworkUrl: 'https://images.unsplash.com/photo-1514525253161-7a46d19cd819?w=500&auto=format&fit=crop&q=80',
      streamUrl:
          'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-3.mp3',
      sourceUrl: 'https://www.soundhelix.com',
      duration: 345,
      isLiked: true,
      isDownloaded: false,
    ),
    const Song(
      id: 'mock-4',
      title: 'Ocean Breeze Serenade',
      artist: 'Chillout Waves',
      album: 'Isle of Peace',
      artworkUrl: 'https://images.unsplash.com/photo-1459749411175-04bf5292ceea?w=500&auto=format&fit=crop&q=80',
      streamUrl:
          'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-4.mp3',
      sourceUrl: 'https://www.soundhelix.com',
      duration: 300,
      isLiked: false,
      isDownloaded: false,
    ),
    const Song(
      id: 'mock-5',
      title: 'Starlight Symphony',
      artist: 'Celestial Orchestra',
      album: 'Astral Echoes',
      artworkUrl: 'https://images.unsplash.com/photo-1501386761578-eac5c94b800a?w=500&auto=format&fit=crop&q=80',
      streamUrl:
          'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-8.mp3',
      sourceUrl: 'https://www.soundhelix.com',
      duration: 320,
      isLiked: true,
      isDownloaded: false,
    ),
    const Song(
      id: 'mock-6',
      title: 'Velvet Groove',
      artist: 'Soulstice Quintet',
      album: 'Blue Note Sessions',
      artworkUrl: 'https://images.unsplash.com/photo-1487180144351-b8472da7d491?w=500&auto=format&fit=crop&q=80',
      streamUrl:
          'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-9.mp3',
      sourceUrl: 'https://www.soundhelix.com',
      duration: 288,
      isLiked: false,
      isDownloaded: false,
    ),
    const Song(
      id: 'mock-7',
      title: 'Rainforest Awakening',
      artist: 'Terra Resonance',
      album: 'Biosphere',
      artworkUrl: 'https://images.unsplash.com/photo-1445985543470-41fba5c3144a?w=500&auto=format&fit=crop&q=80',
      streamUrl:
          'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-10.mp3',
      sourceUrl: 'https://www.soundhelix.com',
      duration: 410,
      isLiked: false,
      isDownloaded: false,
    ),
    const Song(
      id: 'mock-8',
      title: 'Pulse of the City',
      artist: 'Urban Flow',
      album: 'Metropolis Night',
      artworkUrl: 'https://images.unsplash.com/photo-1518609878373-06d740f60d8b?w=500&auto=format&fit=crop&q=80',
      streamUrl:
          'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-11.mp3',
      sourceUrl: 'https://www.soundhelix.com',
      duration: 315,
      isLiked: false,
      isDownloaded: false,
    ),
  ];

  @override
  Future<List<Song>> search(String query) async {
    final clean = query.trim().toLowerCase();
    if (clean.isEmpty) {
      return mockCatalog;
    }
    return mockCatalog.where((song) {
      return song.title.toLowerCase().contains(clean) ||
          song.artist.toLowerCase().contains(clean) ||
          (song.album != null && song.album!.toLowerCase().contains(clean));
    }).toList();
  }

  @override
  Future<Song?> getSongDetails(String id) async {
    try {
      return mockCatalog.firstWhere((s) => s.id == id);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<Song>> getFeaturedSongs() async {
    return mockCatalog.take(5).toList();
  }

  @override
  Future<List<Song>> getTrendingSongs() async {
    return mockCatalog.skip(2).take(6).toList();
  }
}

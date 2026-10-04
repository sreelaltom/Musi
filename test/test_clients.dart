import 'dart:io';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() async {
  final yt = YoutubeExplode();
  final testClients = [
    (YoutubeApiClient.tv, 'tv'),
    (YoutubeApiClient.safari, 'safari'),
    (YoutubeApiClient.ios, 'ios'),
    (YoutubeApiClient.androidMusic, 'androidMusic'),
    (YoutubeApiClient.mediaConnect, 'mediaConnect'),
  ];

  for (final (client, name) in testClients) {
    stdout.writeln('\n================ Trying client: $name ================');
    try {
      final manifest = await yt.videos.streamsClient.getManifest(
        'BmRX2g6-iQI',
        ytClients: [client],
        requireWatchPage: false,
      );
      stdout.writeln('Success! Found ${manifest.streams.length} total streams, ${manifest.audioOnly.length} audioOnly');
      if (manifest.audioOnly.isNotEmpty) {
        final audio = manifest.audioOnly.first;
        stdout.writeln('Best audio itag: ${audio.tag}, container: ${audio.container.name}, size: ${audio.size.totalBytes}');
        
        // Test requesting Range 0- (unbounded range!)
        final httpClient = HttpClient();
        final req = await httpClient.getUrl(audio.url);
        req.headers.set('Range', 'bytes=0-');
        if (client.headers.containsKey('Origin')) {
          req.headers.set('Origin', client.headers['Origin']!);
        }
        final res = await req.close();
        stdout.writeln('Unbounded Range bytes=0- -> Status: ${res.statusCode}');
        if (res.statusCode == 206 || res.statusCode == 200) {
          stdout.writeln('🎉 SUCCESS! Client $name supports unbounded range playback!');
        }
        await res.drain();
      }
    } catch (e) {
      stdout.writeln('Failed for $name: $e');
    }
  }
  yt.close();
}

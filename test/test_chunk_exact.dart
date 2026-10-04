import 'dart:io';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() async {
  final yt = YoutubeExplode();
  try {
    final manifest = await yt.videos.streamsClient.getManifest(
      'BmRX2g6-iQI',
      ytClients: [YoutubeApiClient.androidSdkless],
      requireWatchPage: false,
    );
    final a = manifest.audioOnly.first;
    final client = HttpClient();
    
    for (final size in [131072, 196608, 262144, 327680, 393216, 458752]) {
      final req = await client.getUrl(a.url);
      req.headers.set('User-Agent', 'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip');
      req.headers.set('Range', 'bytes=0-${size - 1}');
      final res = await req.close();
      stdout.writeln('Range bytes=0-${size - 1} ($size bytes) -> Status: ${res.statusCode}');
      await res.drain();
    }

  } catch (e, st) {
    stdout.writeln('Error: $e\n$st');
  } finally {
    yt.close();
  }
}

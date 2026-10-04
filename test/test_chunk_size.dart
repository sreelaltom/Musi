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
    
    for (final end in [512, 1024, 4096, 16384, 65536, 131072, 524288, 1048576]) {
      final req = await client.getUrl(a.url);
      req.headers.set('User-Agent', 'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip');
      req.headers.set('Range', 'bytes=0-$end');
      final res = await req.close();
      stdout.writeln('Range bytes=0-$end -> Status: ${res.statusCode}');
      await res.drain();
    }

  } catch (e, st) {
    stdout.writeln('Error: $e\n$st');
  } finally {
    yt.close();
  }
}

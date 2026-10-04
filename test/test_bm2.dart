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
    final client = HttpClient();
    for (final stream in manifest.audioOnly) {
      stdout.writeln('\n--- Testing itag ${stream.tag} (${stream.container.name}, ${stream.bitrate.kiloBitsPerSecond} kbps) ---');
      
      // Test A: Range 0-1024
      var req = await client.getUrl(stream.url);
      req.headers.set('Range', 'bytes=0-1024');
      var res = await req.close();
      stdout.writeln('Range 0-1024 -> Status: ${res.statusCode}');
      await res.drain();

      // Test B: Range 0-
      req = await client.getUrl(stream.url);
      req.headers.set('Range', 'bytes=0-');
      res = await req.close();
      stdout.writeln('Range 0- -> Status: ${res.statusCode}');
      if (res.statusCode == 403) {
        final body = await res.transform(SystemEncoding().decoder).join();
        stdout.writeln('403 Response body: $body');
      }
      await res.drain();

      // Test C: Range 0-1048575 (1MB chunk)
      req = await client.getUrl(stream.url);
      req.headers.set('Range', 'bytes=0-1048575');
      res = await req.close();
      stdout.writeln('Range 0-1048575 -> Status: ${res.statusCode}');
      await res.drain();
    }
  } catch (e, st) {
    stdout.writeln('Error: $e\n$st');
  } finally {
    yt.close();
  }
}

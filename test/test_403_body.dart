import 'dart:convert';
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
    
    // 1. Range bytes=0-
    final req = await client.getUrl(a.url);
    req.headers.set('Range', 'bytes=0-');
    final res = await req.close();
    stdout.writeln('Status: ${res.statusCode}');
    stdout.writeln('Headers:');
    res.headers.forEach((name, values) => stdout.writeln('$name: $values'));
    final body = await utf8.decoder.bind(res).join();
    stdout.writeln('Body: $body');

  } catch (e, st) {
    stdout.writeln('Error: $e\n$st');
  } finally {
    yt.close();
  }
}

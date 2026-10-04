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
    final totalBytes = a.size.totalBytes;
    stdout.writeln('Total bytes: $totalBytes');
    final client = HttpClient();
    
    // Test 1: Bounded Range to full length bytes=0-(totalBytes-1)
    var req = await client.getUrl(a.url);
    req.headers.set('Range', 'bytes=0-${totalBytes - 1}');
    var res = await req.close();
    stdout.writeln('1. Bounded to full size bytes=0-${totalBytes - 1} -> Status: ${res.statusCode}');
    await res.drain();

    // Test 2: Bounded Range chunk bytes=0-1048575 (1MB)
    req = await client.getUrl(a.url);
    req.headers.set('Range', 'bytes=0-1048575');
    res = await req.close();
    stdout.writeln('2. Bounded chunk bytes=0-1048575 -> Status: ${res.statusCode}');
    await res.drain();

    // Test 3: URL with &rn=1 or &range=0-${totalBytes-1}
    final uriWithRange = a.url.replace(queryParameters: {
      ...a.url.queryParameters,
      'range': '0-${totalBytes - 1}',
    });
    req = await client.getUrl(uriWithRange);
    res = await req.close();
    stdout.writeln('3. URL with range param (no Range header) -> Status: ${res.statusCode}');
    await res.drain();

    // Test 4: WebM stream itag 251 (Opus) with Range bytes=0-
    final webm = manifest.audioOnly.firstWhere((s) => s.container.name.toLowerCase().contains('webm'));
    stdout.writeln('\nWebM (itag ${webm.tag}) total bytes: ${webm.size.totalBytes}');
    req = await client.getUrl(webm.url);
    req.headers.set('Range', 'bytes=0-');
    res = await req.close();
    stdout.writeln('4. WebM with Range bytes=0- -> Status: ${res.statusCode}');
    await res.drain();

    req = await client.getUrl(webm.url);
    req.headers.set('Range', 'bytes=0-${webm.size.totalBytes - 1}');
    res = await req.close();
    stdout.writeln('5. WebM with Range bytes=0-${webm.size.totalBytes - 1} -> Status: ${res.statusCode}');
    await res.drain();

  } catch (e, st) {
    stdout.writeln('Error: $e\n$st');
  } finally {
    yt.close();
  }
}

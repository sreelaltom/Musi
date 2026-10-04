import 'dart:io';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() async {
  final yt = YoutubeExplode();
  try {
    stdout.writeln('Testing BmRX2g6-iQI with androidSdkless...');
    final manifest = await yt.videos.streamsClient.getManifest(
      'BmRX2g6-iQI',
      ytClients: [YoutubeApiClient.androidSdkless],
      requireWatchPage: false,
    );
    stdout.writeln('Audio streams found: ${manifest.audioOnly.length}');
    for (final a in manifest.audioOnly) {
      stdout.writeln('tag: ${a.tag}, Container: ${a.container.name}, Bitrate: ${a.bitrate.kiloBitsPerSecond} kbps, codec: ${a.audioCodec}');
    }
    final a = manifest.audioOnly.first;
    final uri = a.url;
    stdout.writeln('Stream URL: $uri');
    
    // Test HTTP GET with various headers
    final client = HttpClient();
    
    // 1. Without any headers
    var req = await client.getUrl(uri);
    req.headers.set('Range', 'bytes=0-1024');
    var res = await req.close();
    stdout.writeln('1. No User-Agent -> Status: ${res.statusCode}');
    await res.drain();

    // 2. Default ExoPlayer / Media3 User-Agent
    req = await client.getUrl(uri);
    req.headers.set('User-Agent', 'AndroidXMedia3/1.4.1 (Linux;Android 13) ExoPlayerLib/1.4.1');
    req.headers.set('Range', 'bytes=0-1024');
    res = await req.close();
    stdout.writeln('2. ExoPlayer User-Agent -> Status: ${res.statusCode}');
    await res.drain();

    // 3. Android YouTube app User-Agent
    req = await client.getUrl(uri);
    req.headers.set('User-Agent', 'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip');
    req.headers.set('Range', 'bytes=0-1024');
    res = await req.close();
    stdout.writeln('3. YouTube Android UA -> Status: ${res.statusCode}');
    await res.drain();

    // 4. Test with android client (not androidSdkless)
    final manifestAndroid = await yt.videos.streamsClient.getManifest(
      'BmRX2g6-iQI',
      ytClients: [YoutubeApiClient.android],
      requireWatchPage: false,
    );
    final aAndroid = manifestAndroid.audioOnly.first;
    req = await client.getUrl(aAndroid.url);
    req.headers.set('Range', 'bytes=0-1024');
    res = await req.close();
    stdout.writeln('4. android client -> Status: ${res.statusCode}');
    await res.drain();

  } catch (e, st) {
    stdout.writeln('Error: $e\n$st');
  } finally {
    yt.close();
  }
}

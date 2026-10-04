import 'dart:io';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() async {
  final yt = YoutubeExplode();
  try {
    final sw = Stopwatch()..start();
    stdout.writeln('Getting manifest for BmRX2g6-iQI...');
    final manifest = await yt.videos.streamsClient.getManifest(
      'BmRX2g6-iQI',
      ytClients: [YoutubeApiClient.androidSdkless],
      requireWatchPage: false,
    );
    final audio = manifest.audioOnly.first;
    final totalBytes = audio.size.totalBytes;
    stdout.writeln('Manifest resolved in ${sw.elapsedMilliseconds}ms. Total size: $totalBytes bytes');

    final tempFile = File('${Directory.systemTemp.path}/test_bm_${DateTime.now().millisecondsSinceEpoch}.m4a');
    final sink = tempFile.openWrite();
    final client = HttpClient();
    
    // Chunk size: 256 KB
    const chunkSize = 256 * 1024;
    int currentOffset = 0;
    
    stdout.writeln('Downloading in 256KB chunks...');
    final downloadSw = Stopwatch()..start();
    
    while (currentOffset < totalBytes) {
      final chunkEnd = (currentOffset + chunkSize - 1) < totalBytes
          ? (currentOffset + chunkSize - 1)
          : totalBytes - 1;

      final req = await client.getUrl(audio.url);
      req.headers.set('User-Agent', 'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip');
      req.headers.set('Range', 'bytes=$currentOffset-$chunkEnd');
      final res = await req.close();

      if (res.statusCode != 206 && res.statusCode != 200) {
        stdout.writeln('Chunk $currentOffset-$chunkEnd failed with status ${res.statusCode}');
        break;
      }

      await res.forEach(sink.add);
      currentOffset = chunkEnd + 1;
    }
    
    await sink.flush();
    await sink.close();
    client.close();
    
    stdout.writeln('Downloaded ${tempFile.lengthSync()} bytes in ${downloadSw.elapsedMilliseconds}ms!');
    stdout.writeln('File exists: ${tempFile.existsSync()}, size matches: ${tempFile.lengthSync() == totalBytes}');
    
    if (tempFile.existsSync()) {
      tempFile.deleteSync();
    }
  } catch (e, st) {
    stdout.writeln('Error: $e\n$st');
  } finally {
    yt.close();
  }
}

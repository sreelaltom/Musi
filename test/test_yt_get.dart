import 'dart:io';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() async {
  final yt = YoutubeExplode();
  try {
    stdout.writeln('Getting manifest for BmRX2g6-iQI...');
    final manifest = await yt.videos.streamsClient.getManifest(
      'BmRX2g6-iQI',
      ytClients: [YoutubeApiClient.androidSdkless],
      requireWatchPage: false,
    );
    final audio = manifest.audioOnly.first;
    stdout.writeln('Testing streamsClient.get(audio)... totalBytes: ${audio.size.totalBytes}');
    
    final stream = yt.videos.streamsClient.get(audio);
    int receivedBytes = 0;
    final stopwatch = Stopwatch()..start();
    
    await for (final chunk in stream) {
      receivedBytes += chunk.length;
      if (receivedBytes > 100000) {
        stdout.writeln('SUCCESS! Streamed $receivedBytes bytes in ${stopwatch.elapsedMilliseconds}ms');
        break;
      }
    }
  } catch (e, st) {
    stdout.writeln('Error: $e\n$st');
  } finally {
    yt.close();
  }
}

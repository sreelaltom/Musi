import 'dart:io';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() async {
  final yt = YoutubeExplode();
  HttpServer? server;
  try {
    stdout.writeln('Resolving stream for BmRX2g6-iQI...');
    final manifest = await yt.videos.streamsClient.getManifest(
      'BmRX2g6-iQI',
      ytClients: [YoutubeApiClient.androidSdkless],
      requireWatchPage: false,
    );
    final audio = manifest.audioOnly.first;
    final totalBytes = audio.size.totalBytes;
    final streamUrl = audio.url;
    stdout.writeln('Stream URL obtained. Total bytes: $totalBytes');

    // 1. Start a local loopback server
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    stdout.writeln('Local streaming proxy started on port $port');

    server.listen((HttpRequest request) async {
      stdout.writeln('Proxy received request: ${request.method} ${request.uri}');
      request.headers.forEach((k, v) => stdout.writeln('  $k: $v'));

      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      int start = 0;
      int? end;
      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final parts = rangeHeader.substring(6).split('-');
        start = int.tryParse(parts[0]) ?? 0;
        if (parts.length > 1 && parts[1].isNotEmpty) {
          end = int.tryParse(parts[1]);
        }
      }
      end ??= totalBytes - 1;
      final contentLength = end - start + 1;

      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(HttpHeaders.contentTypeHeader, 'audio/mp4');
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$totalBytes',
      );
      request.response.headers.set(HttpHeaders.contentLengthHeader, contentLength.toString());
      request.response.bufferOutput = false;

      // Stream from YouTube CDN in 256KB chunks
      final client = HttpClient();
      const chunkSize = 256 * 1024;
      int currentOffset = start;

      try {
        while (currentOffset <= end) {
          final chunkEnd = (currentOffset + chunkSize - 1) < end
              ? (currentOffset + chunkSize - 1)
              : end;

          final req = await client.getUrl(streamUrl);
          req.headers.set('User-Agent', 'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip');
          req.headers.set('Range', 'bytes=$currentOffset-$chunkEnd');
          final res = await req.close();

          if (res.statusCode != HttpStatus.partialContent && res.statusCode != HttpStatus.ok) {
            stdout.writeln('Chunk fetch failed: ${res.statusCode}');
            await res.drain();
            break;
          }

          await for (final data in res) {
            request.response.add(data);
          }
          await request.response.flush();
          currentOffset = chunkEnd + 1;
        }
      } catch (e) {
        stdout.writeln('Streaming error: $e');
      } finally {
        client.close();
        await request.response.close();
      }
    });

    // 2. Simulate ExoPlayer: Request Range bytes=0- from the local proxy
    final testClient = HttpClient();
    final req = await testClient.getUrl(Uri.parse('http://127.0.0.1:$port/stream'));
    req.headers.set('Range', 'bytes=0-');
    req.headers.set('User-Agent', 'AndroidXMedia3/1.4.1 (Linux;Android 13) ExoPlayerLib/1.4.1');
    final res = await req.close();

    stdout.writeln('\nTest Client Response Status: ${res.statusCode}');
    stdout.writeln('Test Client Content-Range: ${res.headers.value(HttpHeaders.contentRangeHeader)}');
    stdout.writeln('Test Client Content-Length: ${res.headers.value(HttpHeaders.contentLengthHeader)}');

    int downloaded = 0;
    await for (final data in res) {
      downloaded += data.length;
      if (downloaded >= 500000) {
        stdout.writeln('Successfully streamed $downloaded bytes via local proxy without 403!');
        break;
      }
    }

  } catch (e, st) {
    stdout.writeln('Error: $e\n$st');
  } finally {
    await server?.close(force: true);
    yt.close();
  }
}

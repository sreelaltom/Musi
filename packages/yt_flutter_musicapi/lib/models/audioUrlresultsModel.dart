class AudioUrlResult {
  final bool success;
  final String? audioUrl;
  final String? title;
  final String? artist;
  final String? videoId;
  final String audioQuality;
  final String? message;
  final String? error;

  AudioUrlResult({
    required this.success,
    this.audioUrl,
    this.title,
    this.artist,
    this.videoId,
    required this.audioQuality,
    this.message,
    this.error,
  });

  factory AudioUrlResult.fromMap(Map<String, dynamic> map) {
    return AudioUrlResult(
      success: map['success'] ?? false,
      audioUrl: map['audioUrl']?.toString(),
      title: map['title']?.toString(),
      artist: map['artist']?.toString(),
      videoId: map['videoId']?.toString(),
      audioQuality: map['audioQuality']?.toString() ?? 'HIGH',
      message: map['message']?.toString(),
      error: map['error']?.toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'success': success,
      'audioUrl': audioUrl,
      'title': title,
      'artist': artist,
      'videoId': videoId,
      'audioQuality': audioQuality,
      'message': message,
      'error': error,
    };
  }

  @override
  String toString() {
    return 'AudioUrlResult(success: $success, audioUrl: ${audioUrl?.isNotEmpty == true ? '${audioUrl!.substring(0, 50)}...' : 'null'}, '
        'title: $title, artist: $artist, videoId: $videoId, audioQuality: $audioQuality, '
        'message: $message, error: $error)';
  }
}

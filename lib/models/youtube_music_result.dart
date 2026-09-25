/// Represents a YouTube video returned by the official YouTube Data API.
///
/// This model is intentionally separate from [Song]. It carries YouTube-only
/// metadata and never provides a direct audio stream URL.
class YouTubeMusicResult {
  final String videoId;
  final String title;
  final String channelTitle;
  final String thumbnailUrl;
  final String? description;
  final DateTime? publishedAt;
  final String youtubeUrl;
  final MusicSourceType sourceType;
  final String? streamUrl;
  final int? durationSeconds;

  const YouTubeMusicResult({
    required this.videoId,
    required this.title,
    required this.channelTitle,
    required this.thumbnailUrl,
    this.description,
    this.publishedAt,
    required this.youtubeUrl,
    this.sourceType = MusicSourceType.youtube,
    this.durationSeconds,
  }) : streamUrl = null;

  bool get isYouTube => sourceType == MusicSourceType.youtube;
  bool get hasStreamUrl => false;

  String? get durationFormatted {
    final seconds = durationSeconds;
    if (seconds == null || seconds <= 0) return null;
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    return '$minutes:${remainder.toString().padLeft(2, '0')}';
  }

  /// Builds a [YouTubeMusicResult] from a YouTube Data API search/video item.
  ///
  /// Throws [FormatException] when the item is missing required metadata
  /// (snippet or videoId). Callers are expected to catch and degrade gracefully.
  factory YouTubeMusicResult.fromApi(Map<String, dynamic> item) {
    final snippetValue = item['snippet'];
    if (snippetValue is! Map<String, dynamic>) {
      throw const FormatException(
        'YouTube response is missing snippet metadata',
      );
    }

    final idValue = item['id'];
    final videoId = switch (idValue) {
      Map<String, dynamic> id => id['videoId'] as String?,
      String id => id,
      _ => null,
    };
    if (videoId == null || videoId.trim().isEmpty) {
      throw const FormatException('YouTube response is missing a video ID');
    }

    final cleanVideoId = videoId.trim();
    final thumbnails = snippetValue['thumbnails'];
    String? thumbnailUrl;
    if (thumbnails is Map<String, dynamic>) {
      thumbnailUrl =
          _thumbnailUrl(thumbnails, 'standard') ??
          _thumbnailUrl(thumbnails, 'high') ??
          _thumbnailUrl(thumbnails, 'medium') ??
          _thumbnailUrl(thumbnails, 'default');
    }

    final publishedAtValue = snippetValue['publishedAt'];
    return YouTubeMusicResult(
      videoId: cleanVideoId,
      title: (snippetValue['title'] as String?)?.trim().isNotEmpty == true
          ? (snippetValue['title'] as String).trim()
          : 'Unknown Title',
      channelTitle:
          (snippetValue['channelTitle'] as String?)?.trim().isNotEmpty == true
          ? (snippetValue['channelTitle'] as String).trim()
          : 'Unknown Channel',
      thumbnailUrl: thumbnailUrl ?? '',
      description: snippetValue['description'] as String?,
      publishedAt: publishedAtValue is String
          ? DateTime.tryParse(publishedAtValue)
          : null,
      youtubeUrl: 'https://www.youtube.com/watch?v=$cleanVideoId',
      durationSeconds: parseIso8601DurationSeconds(
        _contentDetailsDuration(item),
      ),
    );
  }

  static String? _contentDetailsDuration(Map<String, dynamic> item) {
    final details = item['contentDetails'];
    if (details is Map<String, dynamic>) {
      return details['duration'] as String?;
    }
    if (details is Map) {
      return details['duration'] as String?;
    }
    return null;
  }

  static int? parseIso8601DurationSeconds(String? isoDuration) {
    if (isoDuration == null || isoDuration.trim().isEmpty) return null;
    final match = RegExp(
      r'^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$',
    ).firstMatch(isoDuration.trim());
    if (match == null) return null;
    final days = int.tryParse(match.group(1) ?? '') ?? 0;
    final hours = int.tryParse(match.group(2) ?? '') ?? 0;
    final minutes = int.tryParse(match.group(3) ?? '') ?? 0;
    final seconds = double.tryParse(match.group(4) ?? '') ?? 0;
    return (days * 86400) + (hours * 3600) + (minutes * 60) + seconds.round();
  }

  static String? _thumbnailUrl(
    Map<String, dynamic> thumbnails,
    String quality,
  ) {
    final thumbnail = thumbnails[quality];
    if (thumbnail is Map<String, dynamic>) {
      return thumbnail['url'] as String?;
    }
    return null;
  }

  Map<String, dynamic> toMap() {
    return {
      'video_id': videoId,
      'title': title,
      'channel_title': channelTitle,
      'thumbnail_url': thumbnailUrl,
      'description': description,
      'published_at': publishedAt?.toIso8601String(),
      'youtube_url': youtubeUrl,
      'source_type': sourceType.name,
      'stream_url': null,
    };
  }

  factory YouTubeMusicResult.fromMap(Map<String, dynamic> map) {
    final videoId = (map['video_id'] as String?)?.trim() ?? '';
    return YouTubeMusicResult(
      videoId: videoId,
      title: (map['title'] as String?)?.trim() ?? 'Unknown Title',
      channelTitle:
          (map['channel_title'] as String?)?.trim() ?? 'Unknown Channel',
      thumbnailUrl: (map['thumbnail_url'] as String?) ?? '',
      description: map['description'] as String?,
      publishedAt: map['published_at'] != null
          ? DateTime.tryParse(map['published_at'] as String)
          : null,
      youtubeUrl:
          (map['youtube_url'] as String?) ??
          'https://www.youtube.com/watch?v=$videoId',
      sourceType: MusicSourceType.youtube,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is YouTubeMusicResult &&
          runtimeType == other.runtimeType &&
          videoId == other.videoId;

  @override
  int get hashCode => videoId.hashCode;

  @override
  String toString() =>
      'YouTubeMusicResult(videoId: $videoId, title: $title, channel: $channelTitle)';
}

enum MusicSourceType { authorizedAudio, youtube }

extension MusicSourceTypeX on MusicSourceType {
  String get label {
    switch (this) {
      case MusicSourceType.authorizedAudio:
        return 'Musi';
      case MusicSourceType.youtube:
        return 'YouTube';
    }
  }
}

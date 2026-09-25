import 'music_provider.dart';

class Song {
  final String id;
  final String title;
  final String artist;
  final String? album;
  final String? artworkUrl;
  final String streamUrl;
  final String? sourceUrl;
  final String? localPath;
  final int duration; // in seconds
  final bool isLiked;
  final bool isDownloaded;

  // Provider & license metadata
  final String? providerId;
  final String? providerName;
  final LicenseInfo? license;
  final bool canStream;
  final bool canDownload;

  const Song({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    this.artworkUrl,
    required this.streamUrl,
    this.sourceUrl,
    this.localPath,
    this.duration = 0,
    this.isLiked = false,
    this.isDownloaded = false,
    this.providerId,
    this.providerName,
    this.license,
    this.canStream = true,
    this.canDownload = false,
  });

  bool get hasLocalFile => localPath != null && localPath!.isNotEmpty;

  String get durationFormatted {
    final minutes = duration ~/ 60;
    final seconds = duration % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  SourcePlayability get playability {
    if (!canStream) return SourcePlayability.notPlayableUnknownLicense;
    if (streamUrl.isEmpty) return SourcePlayability.notPlayableNoStreamUrl;
    return SourcePlayability.playable;
  }

  Song copyWith({
    String? id,
    String? title,
    String? artist,
    String? album,
    String? artworkUrl,
    String? streamUrl,
    String? sourceUrl,
    String? localPath,
    int? duration,
    bool? isLiked,
    bool? isDownloaded,
    String? providerId,
    String? providerName,
    LicenseInfo? license,
    bool? canStream,
    bool? canDownload,
  }) {
    return Song(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      artworkUrl: artworkUrl ?? this.artworkUrl,
      streamUrl: streamUrl ?? this.streamUrl,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      localPath: localPath ?? this.localPath,
      duration: duration ?? this.duration,
      isLiked: isLiked ?? this.isLiked,
      isDownloaded: isDownloaded ?? this.isDownloaded,
      providerId: providerId ?? this.providerId,
      providerName: providerName ?? this.providerName,
      license: license ?? this.license,
      canStream: canStream ?? this.canStream,
      canDownload: canDownload ?? this.canDownload,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'artwork_url': artworkUrl,
      'stream_url': streamUrl,
      'source_url': sourceUrl,
      'local_path': localPath,
      'duration': duration,
      'is_liked': isLiked ? 1 : 0,
      'is_downloaded': isDownloaded ? 1 : 0,
      'provider_id': providerId,
      'provider_name': providerName,
      'license': license?.toMap(),
      'can_stream': canStream ? 1 : 0,
      'can_download': canDownload ? 1 : 0,
    };
  }

  factory Song.fromMap(Map<String, dynamic> map) {
    return Song(
      id: map['id'] as String,
      title: map['title'] as String,
      artist: map['artist'] as String,
      album: map['album'] as String?,
      artworkUrl: map['artwork_url'] as String?,
      streamUrl: map['stream_url'] as String,
      sourceUrl: map['source_url'] as String?,
      localPath: map['local_path'] as String?,
      duration: (map['duration'] as num?)?.toInt() ?? 0,
      isLiked: (map['is_liked'] as int?) == 1,
      isDownloaded: (map['is_downloaded'] as int?) == 1,
      providerId: map['provider_id'] as String?,
      providerName: map['provider_name'] as String?,
      license: map['license'] != null
          ? LicenseInfo.fromMap(map['license'] as Map<String, dynamic>)
          : null,
      canStream: (map['can_stream'] as int?) == 1,
      canDownload: (map['can_download'] as int?) == 1,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Song && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

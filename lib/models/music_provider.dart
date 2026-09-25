class MusicProvider {
  final String id;
  final String name;
  final String description;
  final String? attributionUrl;
  final bool canStream;
  final bool canDownload;
  final bool enabled;

  const MusicProvider({
    required this.id,
    required this.name,
    required this.description,
    this.attributionUrl,
    this.canStream = true,
    this.canDownload = false,
    this.enabled = true,
  });

  MusicProvider copyWith({
    String? id,
    String? name,
    String? description,
    String? attributionUrl,
    bool? canStream,
    bool? canDownload,
    bool? enabled,
  }) {
    return MusicProvider(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      attributionUrl: attributionUrl ?? this.attributionUrl,
      canStream: canStream ?? this.canStream,
      canDownload: canDownload ?? this.canDownload,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'attribution_url': attributionUrl,
      'can_stream': canStream ? 1 : 0,
      'can_download': canDownload ? 1 : 0,
      'enabled': enabled ? 1 : 0,
    };
  }

  factory MusicProvider.fromMap(Map<String, dynamic> map) {
    return MusicProvider(
      id: map['id'] as String,
      name: map['name'] as String,
      description: map['description'] as String,
      attributionUrl: map['attribution_url'] as String?,
      canStream: (map['can_stream'] as int?) == 1,
      canDownload: (map['can_download'] as int?) == 1,
      enabled: (map['enabled'] as int?) == 1,
    );
  }
}

class LicenseInfo {
  final String name;
  final String? url;
  final String? description;
  final bool allowsStreaming;
  final bool allowsDownload;
  final bool requiresAttribution;

  const LicenseInfo({
    required this.name,
    this.url,
    this.description,
    this.allowsStreaming = false,
    this.allowsDownload = false,
    this.requiresAttribution = false,
  });

  LicenseInfo copyWith({
    String? name,
    String? url,
    String? description,
    bool? allowsStreaming,
    bool? allowsDownload,
    bool? requiresAttribution,
  }) {
    return LicenseInfo(
      name: name ?? this.name,
      url: url ?? this.url,
      description: description ?? this.description,
      allowsStreaming: allowsStreaming ?? this.allowsStreaming,
      allowsDownload: allowsDownload ?? this.allowsDownload,
      requiresAttribution: requiresAttribution ?? this.requiresAttribution,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'url': url,
      'description': description,
      'allows_streaming': allowsStreaming ? 1 : 0,
      'allows_download': allowsDownload ? 1 : 0,
      'requires_attribution': requiresAttribution ? 1 : 0,
    };
  }

  factory LicenseInfo.fromMap(Map<String, dynamic> map) {
    return LicenseInfo(
      name: map['name'] as String,
      url: map['url'] as String?,
      description: map['description'] as String?,
      allowsStreaming: (map['allows_streaming'] as int?) == 1,
      allowsDownload: (map['allows_download'] as int?) == 1,
      requiresAttribution: (map['requires_attribution'] as int?) == 1,
    );
  }
}

class MusicSource {
  final String providerId;
  final String providerName;
  final String streamUrl;
  final String? sourceUrl;
  final LicenseInfo? license;
  final bool canStream;
  final bool canDownload;
  final String? quality;
  final Map<String, dynamic>? metadata;

  const MusicSource({
    required this.providerId,
    required this.providerName,
    required this.streamUrl,
    this.sourceUrl,
    this.license,
    this.canStream = false,
    this.canDownload = false,
    this.quality,
    this.metadata,
  });

  MusicSource copyWith({
    String? providerId,
    String? providerName,
    String? streamUrl,
    String? sourceUrl,
    LicenseInfo? license,
    bool? canStream,
    bool? canDownload,
    String? quality,
    Map<String, dynamic>? metadata,
  }) {
    return MusicSource(
      providerId: providerId ?? this.providerId,
      providerName: providerName ?? this.providerName,
      streamUrl: streamUrl ?? this.streamUrl,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      license: license ?? this.license,
      canStream: canStream ?? this.canStream,
      canDownload: canDownload ?? this.canDownload,
      quality: quality ?? this.quality,
      metadata: metadata ?? this.metadata,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'provider_id': providerId,
      'provider_name': providerName,
      'stream_url': streamUrl,
      'source_url': sourceUrl,
      'license': license?.toMap(),
      'can_stream': canStream ? 1 : 0,
      'can_download': canDownload ? 1 : 0,
      'quality': quality,
      'metadata': metadata,
    };
  }

  factory MusicSource.fromMap(Map<String, dynamic> map) {
    return MusicSource(
      providerId: map['provider_id'] as String,
      providerName: map['provider_name'] as String,
      streamUrl: map['stream_url'] as String,
      sourceUrl: map['source_url'] as String?,
      license: map['license'] != null
          ? LicenseInfo.fromMap(map['license'] as Map<String, dynamic>)
          : null,
      canStream: (map['can_stream'] as int?) == 1,
      canDownload: (map['can_download'] as int?) == 1,
      quality: map['quality'] as String?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

enum SourcePlayability {
  playable,
  notPlayableUnknownLicense,
  notPlayableNoStreamUrl,
  notPlayableProviderDisabled,
  notPlayableOfflineMode,
}

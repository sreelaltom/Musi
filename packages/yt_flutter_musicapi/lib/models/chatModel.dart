// lib/models/chartsModel.dart

class ChartItem {
  final String title;
  final String artists;
  final String videoId;
  final String? duration;
  final String? albumArt;
  final String? audioUrl;
  final String country;
  final String chartType; // 'songs', 'videos', 'trending'
  final String? rank;
  final String trend; // 'up', 'down', 'neutral'
  final String? views;
  final bool isExplicit;
  final String? playlistId;
  final Map<String, dynamic>? album;

  ChartItem({
    required this.title,
    required this.artists,
    required this.videoId,
    this.duration,
    this.albumArt,
    this.audioUrl,
    required this.country,
    required this.chartType,
    this.rank,
    this.trend = 'neutral',
    this.views,
    this.isExplicit = false,
    this.playlistId,
    this.album,
  });

  factory ChartItem.fromMap(Map<String, dynamic> map) {
    return ChartItem(
      title: map['title']?.toString() ?? 'Unknown',
      artists: map['artists']?.toString() ?? 'Unknown',
      videoId: map['videoId']?.toString() ?? '',
      duration: map['duration']?.toString(),
      albumArt: map['albumArt']?.toString(),
      audioUrl: map['audioUrl']?.toString(),
      country: map['country']?.toString() ?? 'ZZ',
      chartType: map['chartType']?.toString() ?? 'unknown',
      rank: map['rank']?.toString(),
      trend: map['trend']?.toString() ?? 'neutral',
      views: map['views']?.toString(),
      isExplicit: map['isExplicit'] as bool? ?? false,
      playlistId: map['playlistId']?.toString(),
      album:
          map['album'] is Map ? Map<String, dynamic>.from(map['album']) : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'artists': artists,
      'videoId': videoId,
      'duration': duration,
      'albumArt': albumArt,
      'audioUrl': audioUrl,
      'country': country,
      'chartType': chartType,
      'rank': rank,
      'trend': trend,
      'views': views,
      'isExplicit': isExplicit,
      'playlistId': playlistId,
      'album': album,
    };
  }

  @override
  String toString() {
    return 'ChartItem(title: $title, artists: $artists, chartType: $chartType, rank: $rank, trend: $trend, country: $country)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ChartItem &&
        other.videoId == videoId &&
        other.title == title &&
        other.artists == artists;
  }

  @override
  int get hashCode {
    return videoId.hashCode ^ title.hashCode ^ artists.hashCode;
  }

  /// Returns true if this is a chart song (has rank)
  bool get isChartSong => chartType == 'songs' && rank != null;

  /// Returns true if this is a chart video
  bool get isChartVideo => chartType == 'videos';

  /// Returns true if this is a trending video
  bool get isTrending => chartType == 'trending';

  /// Returns the rank as an integer, or null if not available
  int? get rankAsInt {
    if (rank == null) return null;
    return int.tryParse(rank!);
  }

  /// Returns formatted views count
  String get formattedViews {
    if (views == null || views!.isEmpty) return '';
    return views!;
  }

  /// Returns a display string for the chart position
  String get chartPosition {
    if (isChartSong && rank != null) {
      return '#$rank';
    }
    return '';
  }

  /// Returns trend emoji
  String get trendEmoji {
    switch (trend.toLowerCase()) {
      case 'up':
        return '📈';
      case 'down':
        return '📉';
      case 'neutral':
      default:
        return '➡️';
    }
  }
}

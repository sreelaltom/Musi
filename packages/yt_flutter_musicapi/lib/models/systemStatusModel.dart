// SystemStatus model class
class SystemStatus {
  final bool success;
  final String message;
  final bool ytmusicReady;
  final String ytmusicVersion;
  final bool ytdlpReady;
  final String ytdlpVersion;

  SystemStatus({
    required this.success,
    required this.message,
    required this.ytmusicReady,
    required this.ytmusicVersion,
    required this.ytdlpReady,
    required this.ytdlpVersion,
  });

  factory SystemStatus.fromMap(Map<String, dynamic> map) {
    return SystemStatus(
      success: map['success'] ?? false,
      message: map['message'] ?? 'Unknown',
      ytmusicReady: map['ytmusic_ready'] ?? false,
      ytmusicVersion: map['ytmusic_version'] ?? 'Unknown',
      ytdlpReady: map['ytdlp_ready'] ?? false,
      ytdlpVersion: map['ytdlp_version'] ?? 'Unknown',
    );
  }

  bool get isFullyOperational => ytmusicReady && ytdlpReady;

  String get statusSummary {
    if (isFullyOperational) {
      return 'All systems operational';
    } else if (ytmusicReady || ytdlpReady) {
      return 'Partial functionality available';
    } else {
      return 'System offline';
    }
  }

  Map<String, dynamic> toMap() {
    return {
      'success': success,
      'message': message,
      'ytmusic_ready': ytmusicReady,
      'ytmusic_version': ytmusicVersion,
      'ytdlp_ready': ytdlpReady,
      'ytdlp_version': ytdlpVersion,
    };
  }
}

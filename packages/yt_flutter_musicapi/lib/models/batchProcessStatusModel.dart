class BatchProcessingStatus {
  final int processed;
  final int total;
  final int? currentIndex;
  final String? currentSong;
  final String? currentArtist;
  final String? status;

  BatchProcessingStatus({
    required this.processed,
    required this.total,
    this.currentIndex,
    this.currentSong,
    this.currentArtist,
    this.status,
  });

  factory BatchProcessingStatus.fromMap(Map<String, dynamic> map) {
    return BatchProcessingStatus(
      processed: map['processed'] ?? 0,
      total: map['total'] ?? 0,
      currentIndex: map['currentIndex'],
      currentSong: map['currentSong'],
      currentArtist: map['currentArtist'],
      status: map['status'],
    );
  }

  double get progress => total > 0 ? processed / total : 0;
}

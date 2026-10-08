/// Validates and parses Musi custom song links such as
/// `musi://s/dQw4w9WgXcQ`.
class SongDeepLinkService {
  const SongDeepLinkService._();

  static bool isMusiSongLink(Uri uri) =>
      uri.scheme == 'musi' && (uri.host == 's' || uri.host == 'song');

  static String? parseVideoId(Uri uri) {
    if (!isMusiSongLink(uri) || uri.pathSegments.length != 1) return null;
    final id = uri.pathSegments.single.trim();
    return RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id) ? id : null;
  }
}

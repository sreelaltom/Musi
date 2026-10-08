# Local plugin patches

This folder vendors `yt_flutter_musicapi` 3.4.4 (MIT license; see `LICENSE`)
because its published Android plugin pins an outdated YouTube stream extractor.

Musi's changes are intentionally limited to stream URL resolution:

- Bundle yt-dlp 2026.08.19.
- Use yt-dlp's Android player client for stream extraction instead of the
  Android/Web client pair, which produced URLs rejected with HTTP 403.
- Keep the package's search, related-song, metadata, and Flutter APIs intact.

`lib/` and the Kotlin bridge otherwise remain the upstream 3.4.4 source.

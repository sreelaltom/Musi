# Musi

A Flutter-based music streaming application that lets you search, discover, and play music from YouTube Music. Features a modern dark theme with warm amber/gold accents, background playback support, and offline caching.

## Features

- **Search & Discover**: Search songs, artists, albums, and playlists from YouTube Music
- **Background Playback**: Continue listening while using other apps or with screen off
- **Offline Caching**: Cache song metadata for faster repeat searches
- **Modern UI**: Dark theme with warm amber/gold accents, Material 3 design
- **Mini Player**: Persistent mini player with playback controls
- **Library Management**: Save songs, create playlists, manage downloads

## Prerequisites

- Flutter SDK (3.13+)
- Dart SDK (3.13+)
- Android Studio / VS Code with Flutter extensions
- Android device/emulator (API 24+) or iOS device/simulator (iOS 13+)
- For Windows: Visual Studio with C++ workload

## Getting Started

### 1. Clone the Repository

```bash
git clone <repository-url>
cd musi
```

### 2. Install Dependencies

```bash
flutter pub get
```

### 3. Run the App

#### Android/iOS (Mobile)

```bash
# Run on connected device/emulator
flutter run

# Run on specific device
flutter run -d <device-id>

# Run in release mode
flutter run --release
```

#### Windows Desktop

```bash
flutter run -d windows
```

#### Web

```bash
flutter run -d chrome
```

## Building APK

### Debug APK (for testing)

```bash
flutter build apk --debug
# Output: build/app/outputs/flutter-apk/app-debug.apk
```

### Release APK (for distribution)

```bash
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

### Split APKs (smaller per-architecture)

```bash
flutter build apk --split-per-abi
# Outputs: build/app/outputs/flutter-apk/app-arm64-v8a-release.apk, etc.
```

### App Bundle (for Play Store)

```bash
flutter build appbundle --release
# Output: build/app/outputs/bundle/release/app-release.aab
```

## Building for Other Platforms

### iOS

```bash
flutter build ios --release
# Open build/ios/iphoneos/Runner.xcworkspace in Xcode to archive
```

### Windows

```bash
flutter build windows --release
# Output: build/windows/x64/runner/Release/
```

### Web

```bash
flutter build web --release
# Output: build/web/
```

## Project Structure

```
lib/
├── main.dart                      # App entry point
├── models/                        # Data models (Song, Playlist, SearchResult, etc.)
├── screens/                       # UI screens (Home, Search, Library, Settings, Player)
├── services/                      # Business logic (Audio, Download, YouTube API, etc.)
├── widgets/                       # Reusable UI components
├── theme/                         # AppTheme (colors, typography, Material 3 theme)
└── database/                      # SQLite DAOs and database setup
```

## Key Dependencies

- `audio_service` + `just_audio` — Background audio playback
- `youtube_explode_dart` — YouTube stream extraction
- `yt_flutter_musicapi` — YouTube Music search/browse
- `sqflite` — Local SQLite database
- `dio` — HTTP requests
- `provider` — State management

## Configuration

The app uses YouTube Music's public API via `yt_flutter_musicapi` (Python-based via Chaquopy). No API keys required.

## Troubleshooting

### Build Errors

```bash
flutter clean
flutter pub get
flutter run
```

### Android Gradle Issues

- Enable Developer Mode in Windows Settings
- Ensure Android SDK and NDK are installed
- Check `android/local.properties` for correct SDK path

### Missing Dependencies

If you see import errors for `youtube_explode_dart` or `yt_flutter_musicapi`:

```bash
flutter pub add youtube_explode_dart
flutter pub add yt_flutter_musicapi
flutter pub get
```

## License

Private project — not for distribution.

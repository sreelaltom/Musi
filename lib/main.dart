import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme/app_theme.dart';
import 'screens/main_navigation_scaffold.dart';
import 'services/audio_handler.dart';
import 'services/player_service.dart';
import 'services/library_service.dart';
import 'services/youtube_music_api_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppTheme.surface,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // Initialize Background AudioService (MUST succeed for background play)
  try {
    final audioHandler = await AudioService.init(
      builder: () => MusiAudioHandler(),
      config: AudioServiceConfig(
        androidNotificationChannelId: 'com.example.musi.audio',
        androidNotificationChannelName: 'Musi Playback',
        // The notification must NOT be ongoing here. audio_service asserts
        // `!androidNotificationOngoing || androidStopForegroundOnPause`, so
        // pairing ongoing=true with stopForegroundOnPause=false makes
        // AudioService.init() throw — which leaves PlayerService with a null
        // audio handler and no song ever plays.
        androidNotificationOngoing: false,
        // Keep the media foreground service alive while paused so next-track
        // resolution (network call) isn't interrupted by Android process death.
        androidStopForegroundOnPause: false,
        androidShowNotificationBadge: false,
        notificationColor: const Color(0xFFF59E0B),
        artDownscaleWidth: 300,
        artDownscaleHeight: 300,
      ),
    );
    PlayerService().init(audioHandler);
    debugPrint('AudioService initialized successfully');
  } catch (e, st) {
    debugPrint('AudioService init failed: $e\n$st');
    // App still launches — just without background audio service
  }

  // Initialize SQLite Database and persistent library
  try {
    await LibraryService().init();
  } catch (e) {
    debugPrint('LibraryService init failed: $e');
  }

  // Initialize YouTube Music API (Chaquopy Python + yt-dlp engine)
  try {
    await YouTubeMusicApiService().initialize();
  } catch (e) {
    debugPrint('YouTubeMusicApiService init failed: $e');
  }

  runApp(const MusiApp());
}

class MusiApp extends StatelessWidget {
  const MusiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Musi',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const MainNavigationScaffold(),
    );
  }
}

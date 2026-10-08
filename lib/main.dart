import 'package:audio_service/audio_service.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dart:async';
import 'dart:math' as math;

import 'theme/app_theme.dart';
import 'screens/main_navigation_scaffold.dart';
import 'screens/player_screen.dart';
import 'services/audio_handler.dart';
import 'services/player_service.dart';
import 'services/library_service.dart';
import 'services/ui_preferences.dart';
import 'services/youtube_music_api_service.dart';
import 'services/song_deep_link_service.dart';
import 'models/youtube_music_result.dart';
import 'widgets/mini_player.dart';

final _musiRouteObserver = _MusiRouteObserver();
final _musiNavigatorKey = GlobalKey<NavigatorState>();

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

  await UiPreferences.instance.load();

  runApp(const MusiApp());

  // Loading the library also verifies every downloaded file. Keep that disk
  // work off the first-frame path so navigation is available immediately.
  unawaited(_initializeLibrary());

  // Start the heavyweight Python/yt-dlp bridge after the first frame. Home
  // and search await this shared initialization when they need network data.
  unawaited(_initializeYouTubeMusicApi());
}

Future<void> _initializeLibrary() async {
  try {
    await LibraryService().init();
  } catch (e) {
    debugPrint('LibraryService init failed: $e');
  }
}

Future<void> _initializeYouTubeMusicApi() async {
  try {
    await YouTubeMusicApiService().initialize();
  } catch (e) {
    debugPrint('YouTubeMusicApiService init failed: $e');
  }
}

class MusiApp extends StatefulWidget {
  const MusiApp({super.key});

  @override
  State<MusiApp> createState() => _MusiAppState();
}

class _MusiAppState extends State<MusiApp> {
  late final AppLinks _appLinks;
  StreamSubscription<Uri>? _appLinkSubscription;
  final Set<String> _openingSharedSongs = <String>{};
  final Map<String, DateTime> _recentSharedSongs = <String, DateTime>{};

  @override
  void initState() {
    super.initState();
    // Set up the listener during app startup so cold-start song links aren't
    // lost before the first page is rendered.
    _appLinks = AppLinks();
    _appLinkSubscription = _appLinks.uriLinkStream.listen(
      _openSharedSong,
      onError: (Object error) => debugPrint('Musi link error: $error'),
    );
    unawaited(_openInitialSharedSong());
  }

  Future<void> _openInitialSharedSong() async {
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) await _openSharedSong(initialUri);
    } catch (error) {
      debugPrint('Unable to read initial Musi link: $error');
    }
  }

  @override
  void dispose() {
    _appLinkSubscription?.cancel();
    super.dispose();
  }

  Future<void> _openSharedSong(Uri uri) async {
    if (!SongDeepLinkService.isMusiSongLink(uri)) return;
    final videoId = SongDeepLinkService.parseVideoId(uri);
    if (videoId == null) {
      _showDeepLinkMessage('This song link is invalid or incomplete.');
      return;
    }
    final now = DateTime.now();
    final lastOpened = _recentSharedSongs[videoId];
    if (_openingSharedSongs.contains(videoId) ||
        (lastOpened != null && now.difference(lastOpened).inSeconds < 3)) {
      return;
    }
    _recentSharedSongs[videoId] = now;
    _openingSharedSongs.add(videoId);
    try {
      final api = YouTubeMusicApiService();
      await api.initialize();
      final video = await api.getVideoDetails(videoId);
      if (!mounted) return;
      if (video == null || !video.hasUsableTitle) {
        _showDeepLinkMessage(
          'This song is unavailable. Try opening the link on YouTube.',
        );
        return;
      }

      final player = PlayerService();
      unawaited(
        player.playYouTubeAudio(
          video,
          contextQueue: <YouTubeMusicResult>[video],
        ),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final navigator = _musiNavigatorKey.currentState;
        if (!mounted || navigator == null || _musiRouteObserver.isPlayerPage) {
          return;
        }
        navigator.push(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: '/player'),
            builder: (_) => const PlayerScreen(),
          ),
        );
      });
    } catch (error) {
      debugPrint('Unable to open linked song $videoId: $error');
      _showDeepLinkMessage(
        'Could not load this song. Check your internet connection and try again.',
      );
    } finally {
      _openingSharedSongs.remove(videoId);
    }
  }

  void _showDeepLinkMessage(String message) {
    final context = _musiNavigatorKey.currentContext;
    if (!mounted || context == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Musi',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      navigatorKey: _musiNavigatorKey,
      navigatorObservers: [_musiRouteObserver],
      builder: (context, child) {
        final baseMediaQuery = MediaQuery.of(context);
        return ListenableBuilder(
          listenable: UiPreferences.instance,
          builder: (context, _) => MediaQuery(
            data: baseMediaQuery.copyWith(
              textScaler: TextScaler.linear(UiPreferences.instance.textScale),
            ),
            child: ListenableBuilder(
              listenable: Listenable.merge([
                _musiRouteObserver.revision,
                MainNavigationScaffold.activeTab,
                MainNavigationScaffold.homeAtRoot,
              ]),
              builder: (context, _) {
                final media = MediaQuery.of(context);
                // The app-wide tab bar stays above every route, including the
                // full player. Keep route content and the mini-player clear of
                // that persistent area.
                final bottomBarHeight = 80.0 + media.padding.bottom;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(bottom: bottomBarHeight),
                      child: child ?? const SizedBox.shrink(),
                    ),
                    if (!_musiRouteObserver.isPopup &&
                        !_musiRouteObserver.isPlayerPage &&
                        !(MainNavigationScaffold.activeTab.value == 0 &&
                            MainNavigationScaffold.homeAtRoot.value))
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: bottomBarHeight + 4,
                        child: Center(
                          child: SizedBox(
                            width: math.min(media.size.width, 900),
                            child: MiniPlayer(navigatorKey: _musiNavigatorKey),
                          ),
                        ),
                      ),
                    if (!_musiRouteObserver.isPopup)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: SizedBox(
                          height: bottomBarHeight,
                          child: Overlay(
                            initialEntries: [
                              OverlayEntry(
                                builder: (_) =>
                                    MainNavigationScaffold.buildBottomNavigationBar(
                                      currentIndex: MainNavigationScaffold
                                          .activeTab
                                          .value,
                                      onTap: (index) {
                                        if (_musiRouteObserver.isPlayerPage &&
                                            (_musiNavigatorKey.currentState
                                                    ?.canPop() ??
                                                false)) {
                                          _musiNavigatorKey.currentState?.pop();
                                        }
                                        MainNavigationScaffold.selectTab(index);
                                      },
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
      home: const MainNavigationScaffold(),
    );
  }
}

class _MusiRouteObserver extends NavigatorObserver {
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  final List<Route<dynamic>> _routes = [];

  bool get isAtRoot => _routes.length <= 1;
  bool get isPopup => _routes.isNotEmpty && _routes.last is PopupRoute<dynamic>;
  bool get isPlayerPage =>
      _routes.isNotEmpty && _routes.last.settings.name == '/player';

  void _changed() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      revision.value++;
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _routes.add(route);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) _routes.remove(oldRoute);
    if (newRoute != null) _routes.add(newRoute);
    _changed();
  }
}

import 'package:flutter/material.dart';

import 'home_screen.dart';
import 'search_screen.dart';
import 'library_screen.dart';
import 'settings_screen.dart';

class MainNavigationScaffold extends StatefulWidget {
  const MainNavigationScaffold({super.key});

  static final ValueNotifier<int> activeTab = ValueNotifier<int>(0);
  static final ValueNotifier<bool> homeAtRoot = ValueNotifier<bool>(true);

  static void selectTab(int index) {
    if (index >= 0 && index < 4) activeTab.value = index;
  }

  static Widget buildBottomNavigationBar({
    required int currentIndex,
    required ValueChanged<int> onTap,
  }) => Container(
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: Color(0xFF1E212B), width: 0.8)),
    ),
    child: SafeArea(
      top: false,
      child: BottomNavigationBar(
        currentIndex: currentIndex,
        onTap: onTap,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.search_rounded),
            activeIcon: Icon(Icons.search_rounded),
            label: 'Search',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.library_music_outlined),
            activeIcon: Icon(Icons.library_music_rounded),
            label: 'Library',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            activeIcon: Icon(Icons.settings_rounded),
            label: 'Settings',
          ),
        ],
      ),
    ),
  );

  @override
  State<MainNavigationScaffold> createState() => _MainNavigationScaffoldState();
}

class _MainNavigationScaffoldState extends State<MainNavigationScaffold> {
  final _libraryTabIndex = ValueNotifier<int>(0);
  final _homeRouteObserver = _HomeRouteDepthObserver();
  final _tabNavigatorKeys = List.generate(
    4,
    (_) => GlobalKey<NavigatorState>(),
  );

  void _onTabSelected(int index) => MainNavigationScaffold.selectTab(index);

  void _navigateToLibrary(int tabIndex) {
    _libraryTabIndex.value = tabIndex;
    _onTabSelected(2);
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      HomeScreen(
        onSearchTap: () => _onTabSelected(1),
        onNavigateToLibrary: _navigateToLibrary,
      ),
      const SearchScreen(),
      LibraryScreen(tabIndexNotifier: _libraryTabIndex),
      const SettingsScreen(),
    ];

    return ValueListenableBuilder<int>(
      valueListenable: MainNavigationScaffold.activeTab,
      builder: (context, currentIndex, _) => Scaffold(
        body: LayoutBuilder(
          builder: (context, constraints) => Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: constraints.maxWidth.clamp(0.0, 900.0).toDouble(),
              height: constraints.maxHeight,
              child: IndexedStack(
                index: currentIndex,
                children: [
                  for (var index = 0; index < screens.length; index++)
                    NavigatorPopHandler<Object?>(
                      enabled: index == currentIndex,
                      onPopWithResult: (_) {
                        final navigator = _tabNavigatorKeys[index].currentState;
                        if (navigator?.canPop() ?? false) navigator!.pop();
                      },
                      child: Navigator(
                        key: _tabNavigatorKeys[index],
                        observers: index == 0
                            ? [_homeRouteObserver]
                            : const <NavigatorObserver>[],
                        onGenerateRoute: (settings) => MaterialPageRoute<void>(
                          settings: settings,
                          builder: (_) => screens[index],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _libraryTabIndex.dispose();
    super.dispose();
  }
}

class _HomeRouteDepthObserver extends NavigatorObserver {
  final List<Route<dynamic>> _routes = [];

  void _update() {
    MainNavigationScaffold.homeAtRoot.value = _routes.length <= 1;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _routes.add(route);
    _update();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _update();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _update();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) _routes.remove(oldRoute);
    if (newRoute != null) _routes.add(newRoute);
    _update();
  }
}

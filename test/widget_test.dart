import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:musi/main.dart';
import 'package:musi/screens/home_screen.dart';

class _TestHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return _MockHttpClient();
  }
}

class _MockHttpClient implements HttpClient {
  @override
  bool autoUncompress = true;
  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  int? maxConnectionsPerHost;
  @override
  String? userAgent;

  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) {}
  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) {}
  @override
  void close({bool force = false}) {}

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _MockHttpClientRequest();
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _MockHttpClientRequest();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHttpClientRequest implements HttpClientRequest {
  @override
  final HttpHeaders headers = _MockHttpHeaders();

  @override
  Future<HttpClientResponse> close() async => _MockHttpClientResponse();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHttpHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  static final Uint8List _kTransparentImage = Uint8List.fromList(<int>[
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x06,
    0x00,
    0x00,
    0x00,
    0x1F,
    0x15,
    0xC4,
    0x89,
    0x00,
    0x00,
    0x00,
    0x0A,
    0x49,
    0x44,
    0x41,
    0x54,
    0x78,
    0x9C,
    0x63,
    0x00,
    0x01,
    0x00,
    0x00,
    0x05,
    0x00,
    0x01,
    0x0D,
    0x0A,
    0x2D,
    0xB4,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82,
  ]);

  @override
  int get statusCode => 200;
  @override
  int get contentLength => _kTransparentImage.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable([_kTransparentImage]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('home greeting follows local time-of-day boundaries', () {
    expect(greetingForHour(0), 'Good midnight');
    expect(greetingForHour(4), 'Good night');
    expect(greetingForHour(5), 'Good morning');
    expect(greetingForHour(11), 'Good morning');
    expect(greetingForHour(12), 'Good noon');
    expect(greetingForHour(13), 'Good afternoon');
    expect(greetingForHour(16), 'Good afternoon');
    expect(greetingForHour(17), 'Good evening');
    expect(greetingForHour(19), 'Good evening');
    expect(greetingForHour(20), 'Good evening');
    expect(greetingForHour(21), 'Good night');
    expect(greetingForHour(23), 'Good night');
    expect(greetingIconForHour(0), Icons.auto_awesome_rounded);
    expect(greetingIconForHour(12), Icons.wb_sunny_rounded);
    expect(greetingIconForHour(18), Icons.wb_twilight_rounded);
    expect(greetingIconForHour(22), Icons.nightlight_round);
  });

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    HttpOverrides.global = _TestHttpOverrides();
  });

  testWidgets('Musi app loads with home screen and tabs', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MusiApp());
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    // Verify Musi app title is displayed on Home screen
    expect(find.text('Musi'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            RegExp(r'^Good (morning|noon|afternoon|evening|night)$')
                .hasMatch(widget.data ?? ''),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Sreelal'), findsNothing);
    expect(find.text('Chill'), findsNothing);
    expect(find.text('Energy'), findsNothing);
    expect(find.text('Liked Songs'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Verify navigation tabs
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);

    // Switch to Search tab
    await tester.tap(find.byIcon(Icons.search_rounded).first);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    // Verify search input is present
    expect(find.text('Search songs, artists, genres...'), findsOneWidget);

    // Check the compact phone layout for the pages most recently redesigned.
    await tester.tap(find.text('Library').last);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Your Library'), findsOneWidget);
    expect(find.text('My Playlists'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('My Playlists'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Your playlists'), findsOneWidget);

    await tester.tap(find.text('Create playlist'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.enterText(find.byType(TextField).last, 'Responsive test');
    await tester.tap(find.text('Create').last);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Responsive test'), findsOneWidget);

    // Opening a playlist pushes a page inside the Library tab's navigator.
    // The shared bottom bar must stay visible above every tab route.
    await tester.tap(find.text('Responsive test'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Responsive test'), findsNWidgets(2));
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Your playlists'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Settings').last);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Streaming Quality'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

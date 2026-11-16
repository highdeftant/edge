import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/activity/tiles.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TilePaths extends PathProviderPlatform {
  _TilePaths(this.root);
  final String root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory cache;
  late PathProviderPlatform previousPaths;
  late Uint8List png;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('map-tile-cache-');
    cache = await Directory('${root.path}/osm_tiles').create();
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TilePaths(root.path);
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();

    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xff225588), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(2, 2);
    try {
      png = (await image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer.asUint8List();
    } finally {
      image.dispose();
      picture.dispose();
    }
  });

  setUp(() => setMapTilesAllowed(true));

  tearDownAll(() async {
    setMapTilesAllowed(false);
    PathProviderPlatform.instance = previousPaths;
    await root.delete(recursive: true);
  });

  test('concurrent callers share a request but own separate decoded images', () async {
    final started = Completer<void>();
    final respond = Completer<void>();
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      expect(request.url.path, '/8/1/2.png');
      expect(request.headers['User-Agent'], contains('OpenStrap'));
      if (!started.isCompleted) started.complete();
      await respond.future;
      return http.Response.bytes(png, 200);
    });
    addTearDown(client.close);

    final first = loadMapTileForTesting(8, 1, 2, client);
    final second = loadMapTileForTesting(8, 1, 2, client);
    await started.future;
    expect(requests, 1);
    expect(await File('${cache.path}/8_1_2.png').exists(), isFalse);
    respond.complete();
    final images = await Future.wait([first, second]);
    final a = images[0]!;
    final b = images[1]!;
    expect(identical(a, b), isFalse);
    a.dispose();
    try {
      // Disposing one consumer must not invalidate another consumer's image.
      expect(await b.toByteData(format: ui.ImageByteFormat.png), isNotNull);
    } finally {
      b.dispose();
    }
    expect(await File('${cache.path}/8_1_2.png').readAsBytes(), orderedEquals(png));
    expect(await cache.list().where((entry) => entry.path.endsWith('.tmp')).isEmpty,
        isTrue);

    final offline = MockClient((_) async => throw StateError('must use cache'));
    addTearDown(offline.close);
    final cached = await loadMapTileForTesting(8, 1, 2, offline);
    expect(cached, isNotNull);
    cached?.dispose();
    expect(requests, 1);
  });

  test('legacy partial cache is replaced; interrupted staging files are ignored', () async {
    final destination = File('${cache.path}/8_3_4.png');
    final partial = Uint8List.fromList([137, 80, 78]);
    await destination.writeAsBytes(partial);
    final orphan = File('${destination.path}.interrupted.tmp');
    await orphan.writeAsBytes(partial);
    final started = Completer<void>();
    final respond = Completer<void>();
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      if (!started.isCompleted) started.complete();
      await respond.future;
      return http.Response.bytes(png, 200);
    });
    addTearDown(client.close);

    final first = loadMapTileForTesting(8, 3, 4, client);
    final second = loadMapTileForTesting(8, 3, 4, client);
    await started.future;
    // The old entry is not truncated or deleted before replacement is ready.
    expect(await destination.readAsBytes(), orderedEquals(partial));
    respond.complete();
    final images = await Future.wait([first, second]);
    for (final image in images) {
      expect(image, isNotNull);
      image?.dispose();
    }
    expect(requests, 1);
    expect(await destination.readAsBytes(), orderedEquals(png));
    expect(await orphan.readAsBytes(), orderedEquals(partial));
    await orphan.delete();
  });

  test('invalid response is not cached and a later request retries', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response.bytes(requests == 1 ? [1, 2, 3] : png, 200);
    });
    addTearDown(client.close);
    expect(await loadMapTileForTesting(8, 5, 6, client), isNull);
    expect(await File('${cache.path}/8_5_6.png').exists(), isFalse);
    final retry = await loadMapTileForTesting(8, 5, 6, client);
    expect(retry, isNotNull);
    retry?.dispose();
    expect(requests, 2);
    expect(await File('${cache.path}/8_5_6.png').readAsBytes(), orderedEquals(png));
  });

  test('failed cache replacement remains best-effort for rendering', () async {
    // A directory at the destination prevents rename-to-file replacement.
    final blocker = await Directory('${cache.path}/8_7_8.png').create();
    final client = MockClient((_) async => http.Response.bytes(png, 200));
    addTearDown(client.close);
    final image = await loadMapTileForTesting(8, 7, 8, client);
    expect(image, isNotNull);
    image?.dispose();
    expect(await blocker.exists(), isTrue);
    expect(await cache.list().where((entry) => entry.path.endsWith('.tmp')).isEmpty,
        isTrue);
  });

  test('consent denial prevents cache reads and network requests', () async {
    setMapTilesAllowed(false);
    final client = MockClient((_) async => throw StateError('no consent'));
    addTearDown(client.close);
    expect(await loadMapTileForTesting(8, 1, 2, client), isNull);
    expect(await buildRouteMosaic(const [(0.0, 0.0), (0.001, 0.001)],
        width: 64, height: 64,
        bg: const ui.Color(0xff000000), ink: const ui.Color(0xffffffff)), isNull);
  });
}

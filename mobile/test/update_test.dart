import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/features/update/update_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/app_harness.dart';
import 'support/flows.dart';

Map<String, Object?> release(String tag, {String body = '', bool draft = false, bool prerelease = false}) => {
  'tag_name': tag,
  'body': body,
  'draft': draft,
  'prerelease': prerelease,
  'published_at': '2026-10-22T10:00:00Z',
  'assets': [
    {'name': 'getonit.apk.sha256', 'browser_download_url': 'https://example.com/$tag/getonit.apk.sha256'},
    {'name': 'getonit.apk', 'browser_download_url': 'https://example.com/$tag/getonit.apk'},
  ],
};

void main() {
  test('versions compare by number, and dev builds count as zero', () {
    expect(isNewer('0.10.0', '0.9.9'), true);
    expect(isNewer('0.2.0', '0.2.0'), false);
    expect(isNewer('0.2.1', '0.2.0-dev'), true);
    expect(isNewer('0.1.0', 'dev'), true);
    expect(isNewer('0.1.0', '0.2.0'), false);
  });

  test('the check lists every newer published release, newest first, with the APK', () async {
    final releases = [
      release('v0.2.0', body: 'Two'),
      release('v0.4.0', body: 'Four'),
      release('v0.5.0', draft: true),
      release('v0.6.0', prerelease: true),
      release('v0.3.0', body: 'Three'),
      release('v0.1.0'),
    ];
    final client = MockClient((req) async {
      expect(req.url.toString(), releasesApiUrl);
      return http.Response.bytes(utf8Json(releases), 200);
    });
    final settings = <String, String>{};
    final service = UpdateService(client, '0.2.0', () async => settings, (k, v) async => settings[k] = v);
    final info = (await service.check())!;
    expect(info.latestVersion, '0.4.0');
    expect(info.apkUrl, 'https://example.com/v0.4.0/getonit.apk');
    expect(info.notes.map((n) => n.version), ['0.4.0', '0.3.0']);
    expect(info.notes.first.body, 'Four');

    expect(await service.isDismissed('0.4.0'), false);
    await service.dismiss('0.4.0');
    expect(await service.isDismissed('0.4.0'), true);
  });

  test('up to date, an error, or no network: no update', () async {
    Future<UpdateInfo?> check(http.Client c, [String v = '0.4.0']) =>
        UpdateService(c, v, () async => {}, (_, _) async {}).check();
    expect(await check(MockClient((_) async => http.Response.bytes(utf8Json([release('v0.4.0')]), 200))), isNull);
    expect(await check(MockClient((_) async => http.Response('rate limited', 403))), isNull);
    expect(await check(MockClient((_) async => throw const SocketExceptionLike())), isNull);
  });

  group('downloaded APKs', () {
    late Directory dir;
    final bytes = List<int>.generate(1000, (i) => i % 256);
    const apkUrl = 'https://example.com/v0.3.0/getonit.apk';
    const shaUrl = 'https://example.com/v0.3.0/getonit.apk.sha256';
    const info = UpdateInfo(latestVersion: '0.3.0', apkUrl: apkUrl, apkSize: 1000, sha256Url: shaUrl);
    var apkRequests = 0;
    Stream<List<int>> Function() apkBody = () => Stream.value(bytes);

    UpdateDownloads downloads() => UpdateDownloads(
      MockClient.streaming((req, _) async {
        if (req.url.toString() == shaUrl) {
          return http.StreamedResponse(Stream.value(utf8.encode('${sha256.convert(bytes)}  getonit.apk\n')), 200);
        }
        apkRequests++;
        return http.StreamedResponse(apkBody(), 200, contentLength: bytes.length);
      }),
      () async => dir,
    );
    List<String> files() => dir.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();

    setUp(() {
      dir = Directory.systemTemp.createTempSync('getonit-updates');
      apkRequests = 0;
      apkBody = () => Stream.value(bytes);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('a complete APK is reused: Install again does not download again', () async {
      final d = downloads();
      final first = await d.fetch(info);
      expect(first.uri.pathSegments.last, 'getonit-0.3.0.apk');
      double? progress;
      final again = await d.fetch(info, onProgress: (p) => progress = p);
      expect(apkRequests, 1);
      expect(again.path, first.path);
      expect(progress, 1);
      expect(await again.readAsBytes(), bytes);
    });

    test('a damaged copy is downloaded again', () async {
      File('${dir.path}/getonit-0.3.0.apk').writeAsBytesSync(List.filled(1000, 7));
      final f = await downloads().fetch(info);
      expect(apkRequests, 1);
      expect(await f.readAsBytes(), bytes);
    });

    test('a cut download leaves only a .part file, which is never taken as complete', () async {
      apkBody = () => Stream<List<int>>.multi((c) {
        c.add(bytes.sublist(0, 400));
        c.addError(const SocketException('connection cut'));
        c.close();
      });
      await expectLater(downloads().fetch(info), throwsA(isA<SocketException>()));
      expect(files(), ['getonit-0.3.0.apk.part']);

      apkBody = () => Stream.value(bytes);
      final f = await downloads().fetch(info);
      expect(apkRequests, 2);
      expect(await f.readAsBytes(), bytes);
      expect(files(), ['getonit-0.3.0.apk']);
    });

    test('a download that does not match the published SHA-256 is not kept', () async {
      apkBody = () => Stream.value(List.filled(1000, 1));
      await expectLater(downloads().fetch(info), throwsA(isA<HttpException>()));
      expect(files(), isEmpty);
    });

    test('clean-up: finished updates, cut downloads and older APKs go; the newest waits until installed', () async {
      for (final n in ['getonit-0.2.0.apk', 'getonit-0.3.0.apk', 'getonit-0.4.0.apk', 'getonit-0.4.0.apk.part']) {
        File('${dir.path}/$n').writeAsStringSync('x');
      }
      final d = downloads();
      // 0.3.0 runs and 0.4.0 is on offer: only the 0.4.0 APK is still useful.
      await d.cleanUp('0.3.0', keep: '0.4.0');
      expect(files(), ['getonit-0.4.0.apk']);
      // 0.4.0 installed: its APK goes too.
      await d.cleanUp('0.4.0');
      expect(files(), isEmpty);
    });
  });

  testWidgets('the Google Play build updates through Play and never asks GitHub', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    fakeClipboard(tester.binding.defaultBinaryMessenger);
    rootBundle.clear();
    final db = memoryDatabase();
    addTearDown(db.close);
    final fakes = Fakes();
    fakes.updates
      ..version = '0.4.2'
      ..distribution = 'play'
      ..playHasUpdate = true
      ..releases = [release('v0.5.0', body: 'GitHub notes')];

    await tester.pumpWidget(buildTestApp(db: db, fakes: fakes));
    await settle(tester);
    // Start: Play's flexible update, no GitHub dialog, no APK files.
    expect(fakes.updates.playUpdatesStarted, 1);
    expect(fakes.updates.requests, 0);
    expect(fakes.updates.cleanUps, isEmpty);
    expect(find.byKey(const ValueKey('update-dialog')), findsNothing);

    // Settings says where updates come from and asks Play again.
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
    fakes.updates.playHasUpdate = false;
    await tapKey(tester, 'settings-check-update');
    expect(find.text('Get the newest version from Google Play'), findsOneWidget);
    expect(find.text('You have the latest version from Google Play.'), findsOneWidget);
    expect(fakes.updates.playChecks, 2);
    expect(fakes.updates.requests, 0);
    expect(fakes.updates.installed, isEmpty);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('on start: release notes once, install hands the APK over; settings can check again', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    fakeClipboard(tester.binding.defaultBinaryMessenger);
    rootBundle.clear();
    final db = memoryDatabase();
    addTearDown(db.close);
    final fakes = Fakes();
    fakes.updates
      ..version = '0.2.0'
      ..releases = [release('v0.3.0', body: '- **Previews** before import'), release('v0.2.0')];

    await tester.pumpWidget(buildTestApp(db: db, fakes: fakes));
    await settle(tester);
    expect(find.text('Get On It 0.3.0 is out'), findsOneWidget);
    expect(find.textContaining('Previews', findRichText: true), findsWidgets);
    await tapKey(tester, 'update-install');
    expect(fakes.updates.installed, ['https://example.com/v0.3.0/getonit.apk']);
    // Before the check: APKs of finished updates go. After it: older ones.
    expect(fakes.updates.cleanUps, [('0.2.0', null), ('0.2.0', '0.3.0')]);

    // Seen once: a restart does not ask again.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(buildTestApp(db: db, fakes: fakes));
    await settle(tester);
    expect(fakes.updates.requests, 2);
    expect(find.byKey(const ValueKey('update-dialog')), findsNothing);

    // Settings always answers.
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
    await tapKey(tester, 'settings-check-update');
    expect(find.text('Get On It 0.3.0 is out'), findsOneWidget);
    await tapKey(tester, 'update-later');
    fakes.updates.releases = [release('v0.2.0')];
    await tapKey(tester, 'settings-check-update');
    expect(find.textContaining('You have the latest version (0.2.0)'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('debug builds do not check on start', (tester) async {
    fakeClipboard(tester.binding.defaultBinaryMessenger);
    rootBundle.clear();
    final db = memoryDatabase();
    addTearDown(db.close);
    final fakes = Fakes()..updates.releases = [release('v9.0.0')];
    await tester.pumpWidget(buildTestApp(db: db, fakes: fakes));
    await settle(tester);
    expect(fakes.updates.requests, 0);
    expect(fakes.updates.cleanUps, isEmpty);
    expect(find.byKey(const ValueKey('update-dialog')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}

List<int> utf8Json(Object v) => utf8.encode(jsonEncode(v));

class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}

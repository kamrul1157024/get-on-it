import 'dart:convert';

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
    expect(find.byKey(const ValueKey('update-dialog')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}

List<int> utf8Json(Object v) => utf8.encode(jsonEncode(v));

class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}

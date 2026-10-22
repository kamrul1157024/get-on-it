import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/core/time/clock_format.dart';
import 'package:getonit/engines/engine.dart';

import 'support/app_harness.dart';
import 'support/flows.dart';

void main() {
  test('clock times: 24-hour or 12-hour with AM and PM', () {
    expect(clockDisplay(19 * 60, use24h: true), '19:00');
    expect(clockDisplay(19 * 60 + 5, use24h: false), '7:05 PM');
    expect(clockDisplay(0, use24h: false), '12:00 AM');
    expect(clockDisplay(0, use24h: true), '00:00');
    expect(clockDisplay(12 * 60, use24h: false), '12:00 PM');
    expect(clockDisplay(7 * 60 + 30, use24h: false), '7:30 AM');
  });

  test('a place in a video is spelled out, not written like a clock', () {
    expect(positionLabel(0), '0 s');
    expect(positionLabel(45), '45 s');
    expect(positionLabel(120), '2 min');
    expect(positionLabel(34 * 60 + 12), '34 min 12 s');
    expect(positionLabel(3600 + 5 * 60 + 40), '1 h 5 min');
    expect(positionLabel(7200), '2 h');
  });

  Future<Fakes> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    fakeClipboard(tester.binding.defaultBinaryMessenger);
    rootBundle.clear();
    final db = memoryDatabase();
    addTearDown(db.close);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    });
    final fakes = Fakes();
    await tester.pumpWidget(buildTestApp(db: db, fakes: fakes));
    await settle(tester);
    return fakes;
  }

  for (final use24h in [true, false]) {
    testWidgets('settings follow the phone: ${use24h ? '24-hour' : '12-hour'}', (tester) async {
      tester.platformDispatcher.alwaysUse24HourFormatTestValue = use24h;
      addTearDown(tester.platformDispatcher.clearAlwaysUse24HourTestValue);
      await open(tester);
      await tester.tap(find.byTooltip('Settings'));
      await settle(tester);
      // Quiet hours 23:00–07:00 and "My day starts at" midnight.
      expect(find.text(use24h ? '23:00' : '11:00 PM'), findsOneWidget);
      expect(find.text(use24h ? '07:00' : '7:00 AM'), findsOneWidget);
      expect(find.text(use24h ? '00:00' : '12:00 AM'), findsOneWidget);
    });
  }

  testWidgets('a new time zone plans the reminders again', (tester) async {
    final fakes = await open(tester);
    final n = fakes.notifications;
    void resume() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }

    resume();
    await settle(tester);
    final plans = n.plans;
    expect(n.zoneChanges, 0, reason: 'same zone: nothing to do');

    n.zone = 'Asia/Dhaka';
    resume();
    await settle(tester);
    expect(n.zoneChanges, 1);
    expect(n.plans, plans + 1);
  });
}

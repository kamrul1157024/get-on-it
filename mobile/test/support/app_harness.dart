import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:getonit/actions/action_router.dart';
import 'package:getonit/app/app.dart';
import 'package:getonit/app/providers.dart';
import 'package:getonit/data/database.dart';

/// A controllable clock shared by the app and the test.
class TestClock {
  TestClock(this.now);

  DateTime now;

  DateTime call() => now;
}

/// The whole app on a fresh in-memory database. Used by the host widget tests
/// and by the on-device e2e tests.
Widget buildTestApp({required AppDatabase db, TestClock? clock, Future<String?> Function(String goalId)? pdfPicker}) =>
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        if (clock != null) wallClockProvider.overrideWithValue(clock.call),
        if (pdfPicker != null) pdfPickerProvider.overrideWithValue(pdfPicker),
      ],
      child: const GetOnItApp(listenForIntents: false),
    );

AppDatabase memoryDatabase() =>
    AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));

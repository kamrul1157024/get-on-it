import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/core/events/goal_event.dart';
import 'package:getonit/core/schema/documents.dart';
import 'package:getonit/data/database.dart';
import 'package:getonit/data/repository.dart';
import 'package:getonit/features/drive/backup.dart';
import 'package:getonit/features/drive/remote_store.dart';
import 'package:googleapis/drive/v3.dart' as drive;

import 'support/fake_drive_server.dart';
import 'support/harness.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('GoogleDriveStore against the fake Drive API', () {
    late FakeDriveServer server;
    late GoogleDriveStore store;

    setUp(() {
      server = FakeDriveServer();
      store = GoogleDriveStore(drive.DriveApi(server.client));
    });

    test('put creates the folder tree once and uploads the content', () async {
      await store.put('goals/a.json', '{"id":"a"}');
      await store.put('goals/b.json', '{"id":"b"}');
      expect(server.contentsByPath, {'Get On It/goals/a.json': '{"id":"a"}', 'Get On It/goals/b.json': '{"id":"b"}'});
      final folders = server.files.values.where((f) => f.isFolder).map(server.pathOf).toList()..sort();
      expect(folders, ['Get On It', 'Get On It/goals']);
    });

    test('put on an existing file updates it instead of adding a copy', () async {
      await store.put('settings.json', '{"v":1}');
      await store.put('settings.json', '{"v":2}');
      expect(server.contentsByPath, {'Get On It/settings.json': '{"v":2}'});
      expect(await store.get('settings.json'), '{"v":2}');
    });

    test('get, list and folders', () async {
      expect(await store.get('goals/none.json'), isNull, reason: 'no folder yet');
      expect(await store.list('goals'), isEmpty);
      await store.put('goals/x.json', 'X — ünïcode');
      await store.put('events/dev-1/2026-10.jsonl', 'a\n');
      await store.put('events/dev-2/2026-10.jsonl', 'b\n');
      expect(await store.get('goals/x.json'), 'X — ünïcode');
      expect(await store.list('goals'), ['goals/x.json']);
      expect(await store.list('events'), isEmpty, reason: 'files only, not folders');
      expect(await GoogleDriveStore(drive.DriveApi(server.client)).folders('events'), ['dev-1', 'dev-2']);
    });

    test('a fresh store finds the existing folder by name', () async {
      await store.put('goals/a.json', '1');
      final again = GoogleDriveStore(drive.DriveApi(server.client));
      await again.put('goals/b.json', '2');
      expect(server.files.values.where((f) => f.isFolder && f.name == 'Get On It'), hasLength(1));
      expect(await again.list('goals'), ['goals/a.json', 'goals/b.json']);
    });

    test('names with quotes are escaped in queries', () async {
      await store.put("goals/it's.json", 'q');
      expect(await store.get("goals/it's.json"), 'q');
    });

    test('deleteAll removes the app folder and everything in it', () async {
      await store.put('goals/a.json', '1');
      await store.put('events/d/2026-10.jsonl', '2');
      await store.deleteAll();
      expect(server.files, isEmpty);
      expect(await store.get('goals/a.json'), isNull);
    });
  });

  group('BackupService', () {
    late List<AppDatabase> dbs;

    Repository newRepo() {
      final db = AppDatabase(NativeDatabase.memory());
      dbs.add(db);
      return Repository(db);
    }

    setUp(() => dbs = []);
    tearDown(() async {
      for (final db in dbs) {
        await db.close();
      }
    });

    Future<Repository> seeded() async {
      final repo = newRepo();
      for (final name in ['course', 'book', 'habit']) {
        await repo.installTemplate(TemplateDoc(readJson('assets/templates/$name.json')), source: 'builtin');
      }
      final custom = TemplateDoc({
        'kind': 'template',
        'schemaVersion': '1.0',
        'id': 'pushups',
        'version': '1.0.0',
        'engine': 'count',
        'surfaces': {
          'screen': {'type': 'text', 'value': '{{state.label}}'},
        },
      });
      await repo.installTemplate(custom);
      await repo.saveGoal(GoalDoc(readJson('assets/samples/course-cs229.getonit.json')));
      await repo.saveGoal(GoalDoc(readJson('assets/samples/habit-water.getonit.json')));
      await repo.addEvent('stanford-cs229', EventType.itemDone, {
        'item': 'lec-01',
        'done': true,
      }, at: at('2026-09-30T10:00:00'));
      await repo.addEvent('stanford-cs229', EventType.itemPosition, {
        'item': 'lec-02',
        'sec': 600,
      }, at: at('2026-10-21T19:00:00'));
      await repo.addEvent('water', EventType.countDelta, {'delta': 3}, at: at('2026-10-21T09:00:00'));
      await repo.setSetting('dayStartHour', '4');
      await repo.setSetting('deviceId', 'phone-a');
      return repo;
    }

    test('backup writes the documented layout', () async {
      final store = MemoryStore();
      final result = await BackupService(await seeded(), store, 'phone-a').backup();
      expect(result.goals, 2);
      expect(result.templates, 1, reason: 'built-in templates ship with the app');
      expect(result.events, 3);
      expect(store.files.keys.toList()..sort(), [
        'events/phone-a/2026-09.jsonl',
        'events/phone-a/2026-10.jsonl',
        'goals/stanford-cs229.json',
        'goals/water.json',
        'settings.json',
        'templates/pushups@1.0.0.json',
      ]);
      final october = const LineSplitter().convert(store.files['events/phone-a/2026-10.jsonl']!);
      expect(october, hasLength(2));
      expect(jsonDecode(october.first), containsPair('device', 'phone-a'));
      expect(jsonDecode(store.files['settings.json']!), {'dayStartHour': '4'}, reason: 'device settings stay local');
    });

    test('restore on a new phone brings back goals, progress, templates and settings', () async {
      final server = FakeDriveServer();
      final source = await seeded();
      await BackupService(source, GoogleDriveStore(drive.DriveApi(server.client)), 'phone-a').backup();

      final target = newRepo();
      final result = await BackupService(target, GoogleDriveStore(drive.DriveApi(server.client)), 'phone-b').restore();
      expect(result.goals, 2);
      expect(result.templates, 1);
      expect(result.events, 3);

      expect((await target.allGoals()).map((g) => g.id).toSet(), {'stanford-cs229', 'water'});
      expect((await target.templates()).keys, contains('pushups@1'));
      expect((await target.settings())['dayStartHour'], '4');
      final before = (await source.allEvents()).map((e) => e.toJson()..remove('device')).toList();
      final after = (await target.allEvents()).map((e) => e.toJson()..remove('device')).toList();
      expect(after, before, reason: 'same events, same times, same payloads');
      expect((await target.allEvents()).map((e) => e.device).toSet(), {'phone-a'});
    });

    test('restoring twice adds nothing the second time', () async {
      final store = MemoryStore();
      await BackupService(await seeded(), store, 'phone-a').backup();
      final target = newRepo();
      expect((await BackupService(target, store, 'phone-b').restore()).events, 3);
      expect((await BackupService(target, store, 'phone-b').restore()).events, 0);
      expect(await target.allEvents(), hasLength(3));
    });

    test('a phone restoring its own backup keeps its events local', () async {
      final store = MemoryStore();
      await BackupService(await seeded(), store, 'phone-a').backup();
      final reinstalled = newRepo();
      await BackupService(reinstalled, store, 'phone-a').restore();
      expect((await reinstalled.allEvents()).map((e) => e.device).toSet(), {'local'});
    });

    test('events from two phones are merged', () async {
      final store = MemoryStore();
      final a = await seeded();
      await BackupService(a, store, 'phone-a').backup();
      final b = newRepo();
      await BackupService(b, store, 'phone-b').restore();
      await b.addEvent('water', EventType.countDelta, {'delta': 1}, at: at('2026-10-21T12:00:00'));
      await BackupService(b, store, 'phone-b').backup();
      expect(await store.folders('events'), ['phone-a', 'phone-b']);

      final c = newRepo();
      expect((await BackupService(c, store, 'phone-c').restore()).events, 4);
    });
  });
}

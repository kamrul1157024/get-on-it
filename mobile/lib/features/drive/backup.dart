import 'dart:convert';

import '../../core/events/goal_event.dart';
import '../../core/schema/documents.dart';
import '../../data/repository.dart';
import 'remote_store.dart';

class BackupResult {
  const BackupResult({this.goals = 0, this.templates = 0, this.events = 0});

  final int goals;
  final int templates;
  final int events;

  @override
  String toString() => '$goals goals, $templates templates, $events events';
}

/// Settings that belong to this phone and are never copied.
const _localSettings = {'deviceId', 'backup.lastAt', 'backup.account', 'backup.auto'};

/// Backup and restore of the app's data in a [RemoteStore]. Spec §13.
///
/// Layout:
/// ```
/// goals/<goalId>.json
/// templates/<templateId>@<version>.json   (imported templates only)
/// events/<deviceId>/<yyyy-mm>.jsonl       (one file per device and month)
/// settings.json
/// ```
///
/// Each device writes only its own event files, so a later multi-device
/// sync can merge them without conflicts.
class BackupService {
  BackupService(this.repo, this.store, this.deviceId);

  final Repository repo;
  final RemoteStore store;
  final String deviceId;

  Future<BackupResult> backup() async {
    final goals = await repo.allGoals();
    for (final g in goals) {
      await store.put('goals/${g.id}.json', g.encode());
    }

    final templates = await repo.importedTemplates();
    for (final t in templates) {
      await store.put('templates/${t.id}@${t.version}.json', t.encode());
    }

    // Events recorded on this phone. Events restored from another device keep
    // that device's id and stay in its files.
    final mine = (await repo.allEvents()).where((e) => e.device == 'local' || e.device == deviceId);
    final byMonth = <String, List<GoalEvent>>{};
    for (final e in mine) {
      final t = DateTime.fromMillisecondsSinceEpoch(e.utcMs, isUtc: true);
      final month = '${t.year}-${t.month.toString().padLeft(2, '0')}';
      (byMonth[month] ??= []).add(e);
    }
    var count = 0;
    for (final entry in byMonth.entries) {
      final lines = [
        for (final e in entry.value) jsonEncode({...e.toJson(), 'device': deviceId}),
      ];
      count += lines.length;
      await store.put('events/$deviceId/${entry.key}.jsonl', '${lines.join('\n')}\n');
    }

    final settings = {
      for (final e in (await repo.settings()).entries)
        if (!_localSettings.contains(e.key)) e.key: e.value,
    };
    await store.put('settings.json', jsonEncode(settings));
    return BackupResult(goals: goals.length, templates: templates.length, events: count);
  }

  /// Restores everything in the store. Goals and templates replace local
  /// copies with the same id; events are added once.
  Future<BackupResult> restore() async {
    final templates = <TemplateDoc>[];
    for (final path in await store.list('templates')) {
      final text = await store.get(path);
      if (text != null) templates.add(TemplateDoc((jsonDecode(text) as Map).cast()));
    }
    for (final t in templates) {
      await repo.installTemplate(t);
    }

    var goals = 0;
    for (final path in await store.list('goals')) {
      final text = await store.get(path);
      if (text == null) continue;
      await repo.saveGoal(GoalDoc((jsonDecode(text) as Map).cast()));
      goals++;
    }

    final devices = await store.folders('events');
    final events = <GoalEvent>[];
    for (final device in devices) {
      for (final path in await store.list('events/$device')) {
        final text = await store.get(path);
        if (text == null) continue;
        for (final line in const LineSplitter().convert(text)) {
          if (line.trim().isEmpty) continue;
          final e = GoalEvent.fromJson((jsonDecode(line) as Map).cast());
          // Events from this phone come back as local ones.
          events.add(e.device == deviceId ? _withDevice(e, 'local') : e);
        }
      }
    }
    final added = await repo.insertEvents(events);

    final settings = await store.get('settings.json');
    if (settings != null) {
      for (final e in (jsonDecode(settings) as Map).entries) {
        if (!_localSettings.contains(e.key)) await repo.setSetting(e.key as String, '${e.value}');
      }
    }
    return BackupResult(goals: goals, templates: templates.length, events: added);
  }

  GoalEvent _withDevice(GoalEvent e, String device) => GoalEvent(
    id: e.id,
    goalId: e.goalId,
    type: e.type,
    payload: e.payload,
    utcMs: e.utcMs,
    offsetMinutes: e.offsetMinutes,
    device: device,
  );
}

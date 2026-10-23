import 'package:getonit/features/reminders/reminders_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/core/events/goal_event.dart';
import 'package:getonit/core/schema/documents.dart';
import 'package:getonit/data/database.dart';
import 'package:getonit/data/repository.dart';

import 'support/harness.dart';

void main() {
  late AppDatabase db;
  late Repository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
  });
  tearDown(() => db.close());

  test('re-import keeps events, so progress stays', () async {
    final v1 = GoalDoc(readJson('assets/samples/course-cs229.getonit.json'));
    await repo.saveGoal(v1);
    await repo.addEvent(v1.id, EventType.itemDone, {'item': 'lec-01', 'done': true});

    final json = readJson('assets/samples/course-cs229.getonit.json');
    final items = (json['data'] as Map)['items'] as List;
    items.add({'id': 'lec-21', 'kind': 'video', 'title': 'Bonus', 'videoId': 'ccccccc', 'durationSec': 600});
    (items[1] as Map)['title'] = 'Lecture 2: Renamed';
    final v2 = GoalDoc(json);

    final diff = diffGoals((await repo.goal(v1.id))!.doc, v2);
    expect(diff.isNew, false);
    expect(diff.added, ['Bonus']);
    expect(diff.renamed, ['Lecture 2: Renamed']);
    expect(diff.describe(), '1 added, 1 renamed. Your progress stays.');

    await repo.saveGoal(v2);
    final goals = await repo.watchGoals().first;
    expect(goals.single.doc.data['items'], hasLength(items.length));
    final events = await repo.watchEvents(v1.id).first;
    expect(events.single.payload, {'item': 'lec-01', 'done': true});
  });

  test('templates install only when newer', () async {
    final t = TemplateDoc(readJson('assets/templates/habit.json'));
    expect(await repo.installTemplate(t, source: 'builtin'), true);
    expect(await repo.installTemplate(t), false);
    final newer = TemplateDoc({...t.json, 'version': '1.99.0'});
    expect(await repo.installTemplate(newer), true);
    expect(await repo.installTemplate(t), false, reason: '${t.version} is older than the installed 1.99.0');
    expect((await repo.templates())['habit@1']!.version, '1.99.0');
    // A different major version is a different template.
    final v0 = TemplateDoc({...t.json, 'version': '0.9.0'});
    expect(await repo.installTemplate(v0), true);
    expect((await repo.templates()).keys, containsAll(['habit@0', 'habit@1']));
  });

  test('delete removes the goal, its events and its files', () async {
    final g = GoalDoc(readJson('assets/samples/habit-water.getonit.json'));
    await repo.saveGoal(g);
    await repo.addEvent(g.id, EventType.countDelta, {'delta': 1});
    await repo.linkFile(g.id, g.id, 'local_path', '/tmp/x.pdf');
    await repo.deleteGoal(g.id);
    expect(await repo.watchGoals().first, isEmpty);
    expect(await repo.watchEvents(g.id).first, isEmpty);
    expect(await repo.watchLinkedFiles(g.id).first, isEmpty);
  });

  test('deleting a goal clears the settings that belong to it', () {
    // The reminder switch lives in settings; deleteGoal must know its key.
    expect(Repository.goalSettingPrefixes.any((p) => reminderSettingKey('g') == '${p}g'), true);
  });
}

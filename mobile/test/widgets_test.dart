import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/core/schema/documents.dart';
import 'package:getonit/data/database.dart';
import 'package:getonit/data/repository.dart';
import 'package:getonit/features/widgets/home_widgets.dart';
import 'package:getonit/features/widgets/widget_data.dart';

import 'support/harness.dart';

void main() {
  group('resolveTree', () {
    test('fills bindings, drops hidden nodes, expands lists', () {
      final tree = resolveTree(
        {
          'type': 'column',
          'children': [
            {'type': 'text', 'value': 'Read {{state.today.label}}'},
            {'type': 'text', 'value': 'hidden', 'visible': '{{state.todayComplete}}'},
            {
              'type': 'list',
              'items': '{{state.steps}}',
              'as': 'st',
              'item': {
                'type': 'checklist_item',
                'label': '{{st.title}}',
                'checked': '{{st.done}}',
                'action': {
                  'type': 'toggle_done',
                  'params': {'goalId': '{{goal.id}}', 'stepId': '{{st.id}}'},
                },
              },
            },
          ],
        },
        {
          'goal': {'id': 'm'},
          'state': {
            'today': {'label': 'p. 1–2'},
            'todayComplete': false,
            'steps': [
              {'id': 'a', 'title': 'Stretch', 'done': true},
            ],
          },
        },
      )!;
      final children = tree['children'] as List;
      expect(children, hasLength(2));
      expect(children[0], {'type': 'text', 'value': 'Read p. 1–2'});
      expect((children[1] as Map)['type'], 'column');
      expect(((children[1] as Map)['children'] as List).single, {
        'type': 'checklist_item',
        'label': 'Stretch',
        'checked': true,
        'action': {
          'type': 'toggle_done',
          'params': {'goalId': 'm', 'stepId': 'a'},
        },
      });
    });

    test('embeds are replaced by the other goal\'s tree', () {
      final tree = resolveTree(
        {
          'type': 'grid',
          'children': [
            {'type': 'embed', 'goalId': 'w', 'surface': 'tile', 'span': 2},
            {'type': 'embed', 'goalId': 'gone', 'surface': 'tile'},
          ],
        },
        const {},
        embed: (id, s) => id == 'w'
            ? (
                tree: {'type': 'text', 'value': '{{state.label}}'},
                scope: {
                  'state': {'label': '5 / 8'},
                },
              )
            : null,
      )!;
      expect(tree['children'], [
        {'type': 'text', 'value': '5 / 8', 'span': 2},
        {'type': 'text', 'style': 'caption', 'value': 'Goal removed'},
      ]);
    });
  });

  group('widget data and background actions', () {
    late AppDatabase db;
    late Repository repo;
    final now = DateTime(2026, 10, 21, 9);

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = Repository(db, clock: () => now);
      for (final name in ['course', 'book', 'habit']) {
        await repo.installTemplate(TemplateDoc(readJson('assets/templates/$name.json')), source: 'builtin');
      }
      for (final name in ['course-cs229', 'book-atomic-habits', 'habit-water', 'habit-meditate']) {
        await repo.saveGoal(GoalDoc(readJson('assets/samples/$name.getonit.json')));
      }
    });
    tearDown(() => db.close());

    test('every goal gets small and medium trees, and Today lists open goals first', () async {
      final data = buildWidgetData(await computeGoalViews(repo, now), now);
      final goals = (jsonDecode(data['goals']!) as List).cast<Map>();
      expect(goals.map((g) => g['id']), ['stanford-cs229', 'atomic-habits', 'water', 'meditate']);
      for (final g in goals) {
        expect(data.keys, containsAll(['goal:${g['id']}:small', 'goal:${g['id']}:medium']));
      }
      final today = data['today']!;
      expect(today, contains('Today · Wed 21 Oct'));
      expect(today, contains('0 of 4 done'));
      expect(today, contains('Stanford CS229: Machine Learning'));
      expect(today, isNot(contains('{{')), reason: 'Kotlin gets no bindings');
      final water = jsonDecode(data['goal:water:medium']!) as Map;
      expect(jsonEncode(water), contains('"log_progress"'));
      expect(jsonEncode(water), contains('"goalId":"water"'));
    });

    test('a widget button that writes data runs without the app', () async {
      Uri link(Map<String, Object?> action) =>
          Uri.parse('getonit://widget?json=${Uri.encodeComponent(jsonEncode(action))}');
      expect(
        await handleWidgetUri(
          repo,
          link({
            'type': 'log_progress',
            'params': {'goalId': 'water', 'delta': 1},
          }),
          now,
        ),
        true,
      );
      expect(
        await handleWidgetUri(
          repo,
          link({
            'type': 'mark_done',
            'params': {'goalId': 'meditate', 'scope': 'today'},
          }),
          now,
        ),
        true,
      );
      expect(
        await handleWidgetUri(
          repo,
          link({
            'type': 'open_goal',
            'params': {'goalId': 'water'},
          }),
          now,
        ),
        false,
        reason: 'open actions belong to the app',
      );
      expect(await handleWidgetUri(repo, null, now), false);
      final data = buildWidgetData(await computeGoalViews(repo, now), now);
      expect(data['today'], contains('1 of 4 done'));
      expect(data['goal:water:medium'], contains('1 / 8 glasses'));
    });
  });
}

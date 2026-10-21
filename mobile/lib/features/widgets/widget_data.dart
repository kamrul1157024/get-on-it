import 'dart:convert';

import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/binding/resolver.dart';
import '../../core/time/day_clock.dart';
import '../../data/repository.dart';
import '../../engines/engine.dart';

/// Turns a template tree into a plain tree for the native widget renderer:
/// bindings filled, hidden nodes removed, lists expanded, embeds replaced.
/// Spec §10.2: Flutter resolves; Kotlin only maps components.
Map<String, Object?>? resolveTree(
  Object? raw,
  Map<String, Object?> scope, {
  ({Map<String, Object?> tree, Map<String, Object?> scope})? Function(String goalId, String surface)? embed,
  int depth = 0,
}) {
  if (raw is! Map || depth > 20) return null;
  final node = raw.cast<String, Object?>();
  if (node.containsKey('visible') && !node.flag('visible', scope)) return null;
  final type = node['type'];

  if (type == 'list') {
    final items = resolve(node['items'], scope);
    if (items is! List) return null;
    final name = node.str('as', scope) ?? 'item';
    final max = node.number('maxItems', scope)?.toInt();
    return {
      'type': 'column',
      'gap': node['gap'] ?? 0,
      'children': [
        for (final item in max == null ? items : items.take(max))
          ?resolveTree(node['item'], {...scope, name: item}, embed: embed, depth: depth + 1),
      ],
    };
  }
  if (type == 'embed') {
    final goalId = node.str('goalId', scope);
    final found = goalId == null ? null : embed?.call(goalId, node.str('surface', scope) ?? 'tile');
    if (found == null) return {'type': 'text', 'style': 'caption', 'value': 'Goal removed'};
    final tree = resolveTree(found.tree, found.scope, embed: embed, depth: depth + 1);
    return tree == null ? null : {...tree, if (node['span'] != null) 'span': node['span']};
  }

  final out = <String, Object?>{};
  for (final e in node.entries) {
    switch (e.key) {
      case 'children':
        out['children'] = [
          for (final c in (e.value as List? ?? const [])) ?resolveTree(c, scope, embed: embed, depth: depth + 1),
        ];
      case 'child':
        out['child'] = resolveTree(e.value, scope, embed: embed, depth: depth + 1);
      case 'visible' || 'item' || 'fallback':
        break;
      default:
        out[e.key] = resolve(e.value, scope);
    }
  }
  return out;
}

/// Goal + template + state for every goal, computed straight from the
/// database. The background widget callback has no Riverpod container.
Future<List<GoalView>> computeGoalViews(Repository repo, DateTime now) async {
  final settings = await repo.settings();
  final clock = DayClock(dayStartHour: int.tryParse(settings['dayStartHour'] ?? '') ?? 0);
  final templates = await repo.templates();
  final events = await repo.allEvents();
  final views = <GoalView>[];
  for (final stored in await repo.activeGoals()) {
    final g = stored.doc;
    final template = templates[g.templateRef];
    final engine = template == null ? null : engineRegistry.forGoal(template, g);
    final state = engine == null
        ? const <String, Object?>{}
        : engine.computeState(
            EngineContext(
              goal: g,
              events: events.where((e) => e.goalId == g.id).toList(),
              now: Now.of(now),
              clock: clock,
              importedDay: clock.dayOfDateTime(stored.createdAt),
              linkedFiles: await repo.linkedFiles(g.id),
            ),
          );
    views.add(GoalView(goal: g, template: template, state: state, createdAt: stored.createdAt));
  }
  return views;
}

/// Everything the native widgets read, by key (spec §10):
/// - `goals`: `[{id, title, icon}]` for the widget picker
/// - `goal:<id>:small` and `goal:<id>:medium`: one goal
/// - `today`: the composite "Today" widget (auto_today)
Map<String, String> buildWidgetData(List<GoalView> views, DateTime now) {
  final byId = {for (final v in views) v.goal.id: v};
  ({Map<String, Object?> tree, Map<String, Object?> scope})? embed(String id, String surface) {
    final v = byId[id];
    final t = v?.template?.surface(surface);
    return v == null || t == null ? null : (tree: t, scope: v.scope);
  }

  Map<String, Object?>? surfaceOf(GoalView v, List<String> names) {
    for (final n in names) {
      final t = v.template?.surface(n);
      if (t != null) return resolveTree(t, v.scope, embed: embed);
    }
    return {
      'type': 'card',
      'action': {
        'type': 'open_goal',
        'params': {'goalId': v.goal.id},
      },
      'child': {'type': 'text', 'style': 'subtitle', 'value': v.goal.title},
    };
  }

  final data = <String, String>{
    'goals': jsonEncode([
      for (final v in views) {'id': v.goal.id, 'title': v.goal.title, 'icon': v.goal.icon ?? '🎯'},
    ]),
  };
  for (final v in views) {
    data['goal:${v.goal.id}:small'] = jsonEncode(surfaceOf(v, const ['widget.small', 'tile']));
    data['goal:${v.goal.id}:medium'] = jsonEncode(surfaceOf(v, const ['widget.medium', 'tile_wide']));
  }

  // Today: open goals first, then the ones already done.
  final open = views.where((v) => v.state['todayComplete'] != true).toList();
  final done = views.where((v) => v.state['todayComplete'] == true).toList();
  data['today'] = jsonEncode({
    'type': 'column',
    'gap': 8,
    'children': [
      {
        'type': 'row',
        'align': 'between',
        'children': [
          {'type': 'text', 'style': 'subtitle', 'value': 'Today · ${DateFormat('EEE d MMM').format(now)}'},
          {'type': 'badge', 'label': '${done.length} of ${views.length} done', 'tone': 'neutral'},
        ],
      },
      if (views.isEmpty)
        {'type': 'text', 'style': 'caption', 'value': 'No goals yet. Open Get On It to import a plan.'},
      for (final v in [...open, ...done]) ?surfaceOf(v, const ['tile_wide']),
    ],
  });
  data['updatedAt'] = now.toIso8601String();
  return data;
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/app/providers.dart';
import 'package:getonit/core/events/goal_event.dart';
import 'package:getonit/core/schema/capabilities.dart';
import 'package:getonit/core/schema/documents.dart';
import 'package:getonit/core/schema/validator.dart';
import 'package:getonit/core/time/day_clock.dart';
import 'package:getonit/engines/engine.dart';
import 'package:getonit/engines/video_series.dart';
import 'package:getonit/features/import/ask_ai_screen.dart';

import 'support/harness.dart';

void main() {
  final templates = {
    for (final n in ['course', 'book', 'habit']) '$n@1': TemplateDoc(readJson('assets/templates/$n.json')),
  };
  final today = DateTime(2026, 10, 21);
  // Bindings like {{state.count}} belong in the prompt; fill-in slots do not.
  final placeholder = RegExp(
    r'\{\{(today|request|example|customExample|uiReference|goal|progress|currentTemplate|problems|answer)\}\}',
  );
  final uiReference = File('assets/prompt/ui_reference.md').readAsStringSync();

  test('the new-plan prompt has the request, the date, and a valid example', () {
    final prompt = fillPlanPrompt(
      template: File('assets/prompt/plan_prompt.md').readAsStringSync(),
      example: File('assets/samples/book-atomic-habits.getonit.json').readAsStringSync(),
      customExample: File('assets/prompt/custom_example.json').readAsStringSync(),
      uiReference: uiReference,
      request: 'Read Deep Work by December',
      today: today,
    );
    expect(prompt, contains('Read Deep Work by December'));
    expect(prompt, contains('2026-10-21 (Wednesday)'));
    expect(prompt, isNot(contains(placeholder)));
    for (final t in ['course@1', 'book@1', 'habit@1']) {
      expect(prompt, contains(t));
    }
    // The example inside the prompt must still import, or the AI copies a
    // format the app rejects.
    final parsed = parseImport(prompt, (r) => templates[r]);
    expect(parsed.ok, true, reason: '${parsed.issues}');
    expect(prompt, contains('"kind": "bundle"'));
    expect(prompt, contains('# Custom look'));
  });

  test('the custom-template example imports, with a screen and both widget surfaces', () {
    final parsed = parseImport(File('assets/prompt/custom_example.json').readAsStringSync(), (r) => templates[r]);
    expect(parsed.ok, true, reason: '${parsed.issues}');
    expect(parsed.issues, isEmpty);
    final t = parsed.templates.single;
    for (final s in ['screen', 'tile', 'tile_wide']) {
      expect(t.surface(s), isNotNull, reason: s);
    }
    expect(parsed.goals.single.templateRef, '${t.id}@1');
  });

  test('the UI reference names every component, action, and engine the app supports', () {
    for (final name in [...Capabilities.components, ...Capabilities.actions]) {
      expect(uiReference, contains('- $name'), reason: name);
    }
    for (final e in Capabilities.engines.difference({'by_mode'})) {
      expect(uiReference, contains('"$e"'), reason: e);
    }
  });

  test('the change prompt has the plan, the progress, and the keep-the-ids rules', () {
    final goal = GoalDoc(readJson('assets/samples/course-cs229.getonit.json'));
    final state = const VideoSeriesEngine().computeState(
      EngineContext(
        goal: goal,
        events: [
          ev(EventType.itemDone, {'item': 'lec-01', 'done': true}, at('2026-10-20T10:00:00'), goal: goal.id),
        ],
        now: Now.of(DateTime(2026, 10, 21, 9)),
      ),
    );
    final view = GoalView(goal: goal, template: templates['course@1'], state: state, createdAt: DateTime(2026, 10, 1));
    final prompt = fillEditPrompt(
      template: File('assets/prompt/edit_prompt.md').readAsStringSync(),
      uiReference: uiReference,
      view: view,
      request: 'Move the deadline two weeks later',
      today: today,
    );
    expect(prompt, contains('Move the deadline two weeks later'));
    expect(prompt, contains('"id": "stanford-cs229"'));
    expect(prompt, contains('Done item ids: lec-01'));
    expect(prompt, contains('Next item: Lecture 2: Linear Regression and Gradient Descent'));
    expect(prompt, contains('Keep the "id" of every existing item and step'));
    // The template is there, so the AI can change the screen and widgets.
    expect(prompt, contains('"engine": "video_series"'));
    expect(prompt, contains('# Custom look'));
    expect(prompt, isNot(contains(placeholder)));
    // The plan inside the prompt is a valid document on its own.
    expect(parseImport(prompt, (r) => templates[r]).ok, true);
  });

  test('the fix prompt has the problems, the answer, and the keep-the-ids rule', () {
    final prompt = fillFixPrompt(
      template: File('assets/prompt/fix_prompt.md').readAsStringSync(),
      uiReference: uiReference,
      problems: ['data.items: required', 'surfaces.tile.children[0]: "heatmap" does not show on home-screen widgets'],
      answer: 'Here is your plan: {"kind":"goal","id":"x"}',
      today: today,
    );
    expect(prompt, contains('- data.items: required'));
    expect(prompt, contains('- surfaces.tile.children[0]'));
    expect(prompt, contains('{"kind":"goal","id":"x"}'));
    expect(prompt, contains('Keep every "id"'));
    expect(prompt, contains('# Custom look'));
    expect(prompt, isNot(contains(placeholder)));
  });
}

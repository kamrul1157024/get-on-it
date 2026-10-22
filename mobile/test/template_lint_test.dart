import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/app/providers.dart';
import 'package:getonit/core/schema/documents.dart';
import 'package:getonit/core/schema/validator.dart';
import 'package:getonit/core/time/day_clock.dart';
import 'package:getonit/render/template_lint.dart';

import 'support/harness.dart';

void main() {
  final templates = {
    for (final n in ['course', 'book', 'habit']) '$n@1': TemplateDoc(readJson('assets/templates/$n.json')),
  };
  final now = DateTime(2026, 10, 21, 9);

  List<ValidationIssue> lint(TemplateDoc t, GoalDoc g) =>
      lintTemplate(t, g, previewState(t, g, clock: const DayClock(), now: now));

  test('the built-in templates have no warnings for any sample', () {
    for (final f in Directory('assets/samples').listSync().whereType<File>()) {
      final g = GoalDoc(readJson(f.path));
      expect(lint(templates[g.templateRef]!, g), isEmpty, reason: f.path);
    }
  });

  test('the custom example in the prompt has no warnings', () {
    final parsed = parseImport(File('assets/prompt/custom_example.json').readAsStringSync(), (r) => templates[r]);
    expect(lint(parsed.templates.single, parsed.goals.single), isEmpty);
  });

  test('wrong bindings and widget-only limits are warnings with a path', () {
    final t = TemplateDoc({
      'kind': 'template',
      'schemaVersion': '1.0',
      'id': 'bad',
      'version': '1.0.0',
      'engine': 'count',
      'dataSchema': {
        'type': 'object',
        'properties': {
          'unit': {'type': 'string'},
          'target': {'type': 'integer'},
          'tips': {'type': 'array'},
          'optionalLink': {'type': 'string'},
        },
      },
      'surfaces': {
        'screen': {
          'type': 'column',
          'children': [
            {'type': 'text', 'value': '{{state.count}} / {{state.nope}}'},
            {'type': 'text', 'value': '{{data.missing}} {{data.optionalLink}}'},
            {'type': 'text', 'value': '{{state.count + 1}}'},
            {'type': 'text', 'value': '{{goal.titel}}'},
            {
              'type': 'list',
              'items': '{{data.tips}}',
              'as': 'tip',
              'item': {'type': 'text', 'value': '{{tip.text}} {{tip.nope}}'},
            },
            // Hidden for this goal: not checked beyond its condition.
            {'type': 'text', 'visible': '{{state.isComplete}}', 'value': '{{state.alsoNope}}'},
          ],
        },
        'tile': {
          'type': 'column',
          'children': [
            {'type': 'heatmap', 'cells': '{{state.heatmap}}'},
            {'type': 'text', 'value': '{{other.x}}'},
          ],
        },
      },
    });
    final g = GoalDoc({
      'kind': 'goal',
      'schemaVersion': '1.0',
      'id': 'g',
      'template': 'bad@1',
      'title': 'G',
      'data': {
        'unit': 'x',
        'target': 3,
        'tips': [
          {'text': 'one'},
        ],
      },
    });
    final issues = lint(t, g).map((i) => '$i').toList();
    expect(issues.every((i) => i.isNotEmpty), true);
    expect(lint(t, g).every((i) => i.warning), true);
    expect(
      issues,
      contains(startsWith('surfaces.screen.children[0].value: "{{state.nope}}": the "count" engine has no "nope"')),
    );
    expect(
      issues,
      contains('surfaces.screen.children[1].value: "{{data.missing}}": the goal has no data field "missing"'),
    );
    expect(issues.where((i) => i.contains('optionalLink')), isEmpty);
    expect(issues, contains(contains('"{{state.count + 1}}" is not a plain path')));
    expect(issues, contains(contains('goal has no "titel"')));
    expect(issues, contains(contains('"{{tip.nope}}": the list items has no "nope"')));
    expect(issues.where((i) => i.contains('tip.text')), isEmpty);
    expect(issues.where((i) => i.contains('alsoNope')), isEmpty);
    expect(
      issues,
      contains('surfaces.tile.children[0]: "heatmap" does not show on home-screen widgets. Use it only in "screen"'),
    );
    expect(issues, contains(contains('"{{other.x}}": bindings start with goal, data, state or a list name')));
  });

  test('the widget component list matches the native widget renderer', () {
    final kotlin = File('android/app/src/main/kotlin/app/getonit/widget/WidgetTree.kt').readAsStringSync();
    final drawn = {
      for (final m in RegExp(r'^\s+((?:"[a-z_]+",?\s*)+)->', multiLine: true).allMatches(kotlin))
        ...RegExp(r'"([a-z_]+)"').allMatches(m[1]!).map((x) => x[1]!),
    };
    // Text styles and tones share the `"x" ->` form; keep only components.
    final components = drawn.intersection({...widgetComponents, 'heatmap', 'image', 'section', 'number_input'});
    expect(components, widgetComponents.difference({'list', 'embed'}));
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/app/providers.dart';
import 'package:getonit/core/schema/documents.dart';
import 'package:getonit/core/schema/validator.dart';
import 'package:getonit/core/time/day_clock.dart';
import 'package:getonit/features/widgets/widget_data.dart';
import 'package:getonit/render/template_lint.dart';

import 'support/harness.dart';

/// AI-made plans: answers Claude gave to the in-app prompts (new plan,
/// change, change the look), and the example those prompts show.
const _sources = {
  'pushups': 'test/fixtures/ai/pushups-bundle.json',
  'guitar': 'test/fixtures/ai/guitar-bundle.json',
  'cs229-look': 'test/fixtures/ai/cs229-look-bundle.json',
  'water-look': 'test/fixtures/ai/water-look-bundle.json',
  'custom-example': 'assets/prompt/custom_example.json',
};

/// The Kotlin widget test (WidgetTreeTest) draws these trees.
const _fixture = 'android/app/src/test/resources/ai_tiles.json';

void main() {
  final builtin = {
    for (final n in ['course', 'book', 'habit']) '$n@1': TemplateDoc(readJson('assets/templates/$n.json')),
  };
  final now = DateTime(2026, 10, 21, 9);

  ({GoalDoc goal, TemplateDoc template, Map<String, Object?> state}) load(String path) {
    final parsed = parseImport(File(path).readAsStringSync(), (r) => builtin[r]);
    expect(parsed.ok, true, reason: '$path: ${parsed.issues}');
    final t = parsed.templates.single;
    final g = parsed.goals.single;
    return (goal: g, template: t, state: previewState(t, g, clock: const DayClock(), now: now));
  }

  test('AI-made plans import without warnings', () {
    for (final path in _sources.values) {
      final p = load(path);
      expect(lintTemplate(p.template, p.goal, p.state), isEmpty, reason: path);
    }
  });

  test('the resolved widget trees for the Kotlin test are up to date', () {
    final cases = <Map<String, Object?>>[];
    for (final e in _sources.entries) {
      final p = load(e.value);
      final scope = {'goal': p.goal.scopeValue, 'data': p.goal.data, 'state': p.state};
      for (final s in ['tile', 'tile_wide']) {
        final tree = resolveTree(p.template.surface(s), scope);
        cases.add({'name': '${e.key}:$s', 'tree': tree, 'texts': _texts(tree)});
      }
    }
    final want = '${const JsonEncoder.withIndent('  ').convert(cases)}\n';
    final file = File(_fixture);
    if (Platform.environment['UPDATE_FIXTURES'] == '1' || !file.existsSync()) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(want);
    }
    expect(file.readAsStringSync(), want, reason: 'Run: UPDATE_FIXTURES=1 flutter test test/ai_tiles_test.dart');
  });
}

/// The words a widget must show: text, stats, badges and button labels.
List<String> _texts(Object? node) {
  final out = <String>[];
  void walk(Object? n) {
    if (n is! Map) return;
    for (final key in const ['value', 'label']) {
      final v = n[key];
      if (v is String && v.trim().isNotEmpty && n['type'] != 'progress_ring') out.add(v.trim());
    }
    for (final c in (n['children'] as List? ?? const [])) {
      walk(c);
    }
    walk(n['child']);
  }

  walk(node);
  return out;
}

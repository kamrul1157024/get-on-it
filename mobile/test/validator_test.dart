import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/core/schema/documents.dart';
import 'package:getonit/core/schema/validator.dart';

import 'support/harness.dart';

void main() {
  final builtin = {
    for (final name in ['course', 'book', 'habit']) '$name@1': TemplateDoc(readJson('assets/templates/$name.json')),
  };
  TemplateDoc? lookup(String ref) => builtin[ref];

  test('the built-in templates are valid template documents', () {
    for (final name in ['course', 'book', 'habit']) {
      final parsed = parseImport(File('assets/templates/$name.json').readAsStringSync(), (_) => null);
      expect(parsed.errors, isEmpty, reason: '$name: ${parsed.errors}');
      expect(parsed.issues.where((i) => i.warning), isEmpty, reason: '$name uses only known components');
    }
  });

  test('the sample goals validate against the built-in templates', () {
    for (final f in Directory('assets/samples').listSync().whereType<File>()) {
      final parsed = parseImport(f.readAsStringSync(), lookup);
      expect(parsed.ok, true, reason: '${f.path}: ${parsed.issues}');
    }
  });

  test('JSON inside a code fence from Claude is accepted', () {
    final text =
        'Here is your plan:\n```json\n${File('assets/samples/habit-water.getonit.json').readAsStringSync()}\n```\nEnjoy!';
    expect(parseImport(text, lookup).ok, true);
  });

  test('errors carry a path the user can give back to Claude', () {
    final doc = readJson('assets/samples/course-cs229.getonit.json');
    ((doc['data'] as Map)['items'] as List)[3] = {'id': 'lec-04', 'kind': 'video', 'title': 'Lecture 4'};
    final parsed = parseImport(jsonEncode(doc), lookup);
    expect(parsed.ok, false);
    expect(parsed.errors.map((e) => e.path), contains(startsWith('data.items.3')));
  });

  test('a newer schema major version asks for an app update', () {
    final parsed = parseImport('{"kind":"goal","schemaVersion":"2.0","id":"x"}', lookup);
    expect(parsed.errors.single.message, contains('newer app'));
  });

  test('envelope problems', () {
    expect(parseImport('not json', lookup).errors.single.message, startsWith('Not valid JSON'));
    final bad = parseImport('{"kind":"goal","schemaVersion":"1.0","id":"Bad Id"}', lookup);
    expect(bad.errors.map((e) => e.path), ['id']);
    final missing = parseImport(
      '{"kind":"goal","schemaVersion":"1.0","id":"x","template":"rocket@1","title":"T","data":{}}',
      lookup,
    );
    expect(missing.errors.single.message, contains('not installed'));
  });

  test('templates: unknown components warn, http links fail, size limits hold', () {
    final tpl = {
      'kind': 'template',
      'schemaVersion': '1.0',
      'id': 'custom',
      'version': '1.0.0',
      'engine': 'check',
      'surfaces': {
        'screen': {
          'type': 'column',
          'children': [
            {'type': 'rep_tracker'},
            {
              'type': 'rep_tracker',
              'fallback': {'type': 'text', 'value': 'Update'},
            },
            {'type': 'image', 'src': 'http://example.com/x.png'},
          ],
        },
      },
    };
    final parsed = parseImport(jsonEncode(tpl), lookup);
    expect(parsed.issues.where((i) => i.warning).length, 1);
    expect(parsed.errors.single.path, 'surfaces.screen.children[2].src');
  });

  test('a bundle installs a custom template and a goal that uses it', () {
    final bundle = {
      'kind': 'bundle',
      'schemaVersion': '1.0',
      'documents': [
        {
          'kind': 'template',
          'id': 'pushups',
          'version': '1.0.0',
          'engine': 'count',
          'surfaces': {
            'screen': {'type': 'text', 'value': '{{state.label}}'},
          },
        },
        {
          'kind': 'goal',
          'id': 'pushups-daily',
          'template': 'pushups@1',
          'title': 'Push-ups',
          'data': {'target': 50, 'unit': 'push-ups'},
        },
      ],
    };
    final parsed = parseImport(jsonEncode(bundle), lookup);
    expect(parsed.ok, true, reason: '${parsed.issues}');
    expect(parsed.templates.single.ref, 'pushups@1');
    expect(parsed.goals.single.templateRef, 'pushups@1');
  });

  test('an AI answer with fields in the wrong place is refused, with the path', () {
    // A real Claude answer: "schedule" inside "data" and an invented "endDate".
    final parsed = parseImport(File('test/fixtures/ai-edit-misplaced-fields.json').readAsStringSync(), lookup);
    expect(parsed.ok, false);
    expect(parsed.errors.map((e) => e.path), contains('data'));
    expect(parsed.errors.map((e) => e.message).join(), contains('schedule'));
  });

  test('unknown top-level goal fields are a warning', () {
    final doc = readJson('assets/samples/habit-water.getonit.json')..['deadlnie'] = '2026-12-31';
    final parsed = parseImport(jsonEncode(doc), lookup);
    expect(parsed.ok, true);
    expect(parsed.issues.single.path, 'deadlnie');
    expect(parsed.issues.single.warning, true);
  });
}

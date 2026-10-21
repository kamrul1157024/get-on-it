import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/core/schema/documents.dart';
import 'package:getonit/core/schema/validator.dart';

const _skill = '../skill/skills/getonit-planner';

Map<String, Object?> _readJson(File f) => (jsonDecode(f.readAsStringSync()) as Map).cast();

List<File> _jsonFiles(String dir) =>
    Directory(dir).listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));

void main() {
  final builtin = {
    for (final f in _jsonFiles('assets/templates'))
      if (_readJson(f) case final json)
        '${json['id']}@${(json['version'] as String).split('.').first}': TemplateDoc(json),
  };
  TemplateDoc? lookup(String ref) => builtin[ref];

  test('the skill has examples', () {
    expect(_jsonFiles('$_skill/examples').length, greaterThanOrEqualTo(6));
  });

  test('the app accepts every skill example', () {
    for (final f in _jsonFiles('$_skill/examples')) {
      final parsed = parseImport(f.readAsStringSync(), lookup);
      expect(parsed.ok, true, reason: '${f.path}: ${parsed.issues}');
      expect(parsed.issues.where((i) => i.warning), isEmpty, reason: '${f.path}: ${parsed.issues}');
      expect(parsed.goals, isNotEmpty, reason: '${f.path} has a goal');
    }
  });

  test('the custom template bundle installs its template for its goal', () {
    final parsed = parseImport(File('$_skill/examples/custom-template-bundle.getonit.json').readAsStringSync(), lookup);
    expect(parsed.templates.map((t) => t.ref), ['practice-sessions@1']);
    expect(parsed.goals.single.templateRef, 'practice-sessions@1');
  });

  test('the skill template copies match the app templates', () {
    final app = {for (final f in _jsonFiles('assets/templates')) f.uri.pathSegments.last: _readJson(f)};
    final skill = {for (final f in _jsonFiles('$_skill/templates')) f.uri.pathSegments.last: _readJson(f)};
    expect(skill.keys.toSet(), app.keys.toSet());
    for (final name in app.keys) {
      expect(skill[name], app[name], reason: '$name differs. Run: python3 $_skill/scripts/sync_schemas.py');
    }
  });
}

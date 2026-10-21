import 'dart:convert';

import 'package:json_schema/json_schema.dart';

import '../time/day_clock.dart';
import 'capabilities.dart';
import 'documents.dart';

class ValidationIssue {
  const ValidationIssue(this.path, this.message, {this.warning = false});

  final String path;
  final String message;
  final bool warning;

  @override
  String toString() => '${path.isEmpty ? '(root)' : path}: $message';
}

const maxDocumentBytes = 1024 * 1024;
const maxTreeDepth = 20;
const maxTreeNodes = 500;

final _idPattern = RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$');
final _templateRef = RegExp(r'^[a-z0-9][a-z0-9-]{0,63}@\d+$');
final _semver = RegExp(r'^\d+\.\d+\.\d+$');
final _hex = RegExp(r'^#[0-9a-fA-F]{6}$');
final _fence = RegExp(r'```(?:json)?\s*\n([\s\S]*?)\n?```');

/// Pulls JSON out of text that Claude may have wrapped in a code fence.
String extractJson(String text) {
  final t = text.trim();
  if (t.startsWith('{') || t.startsWith('[')) return t;
  final m = _fence.firstMatch(t);
  if (m != null) return m[1]!.trim();
  final start = t.indexOf('{');
  final end = t.lastIndexOf('}');
  return start >= 0 && end > start ? t.substring(start, end + 1) : t;
}

/// The documents found in one import, before they are saved.
class ParsedImport {
  ParsedImport({this.templates = const [], this.goals = const [], this.issues = const []});

  final List<TemplateDoc> templates;
  final List<GoalDoc> goals;
  final List<ValidationIssue> issues;

  List<ValidationIssue> get errors => issues.where((i) => !i.warning).toList();
  bool get ok => errors.isEmpty && (templates.isNotEmpty || goals.isNotEmpty);
}

/// Parses and validates imported text. Spec §14.2.
///
/// [templateLookup] finds installed templates (`id@major`), so a goal can be
/// checked against a template that is not part of this import.
ParsedImport parseImport(String text, TemplateDoc? Function(String ref) templateLookup) {
  if (utf8.encode(text).length > maxDocumentBytes) {
    return ParsedImport(issues: [const ValidationIssue('', 'The document is larger than 1 MB')]);
  }
  Object? decoded;
  try {
    decoded = jsonDecode(extractJson(text));
  } on FormatException catch (e) {
    return ParsedImport(issues: [ValidationIssue('', 'Not valid JSON: ${e.message}')]);
  }
  if (decoded is! Map) {
    return ParsedImport(issues: [const ValidationIssue('', 'Expected a JSON object')]);
  }

  final issues = <ValidationIssue>[];
  final docs = <(String, Map<String, Object?>)>[];
  final root = decoded.cast<String, Object?>();
  _checkEnvelope(root, '', issues);
  if (root['kind'] == 'bundle') {
    final list = root['documents'];
    if (list is! List || list.isEmpty) {
      issues.add(const ValidationIssue('documents', 'A bundle needs a non-empty documents array'));
    } else {
      for (var i = 0; i < list.length; i++) {
        final d = list[i];
        if (d is! Map) {
          issues.add(ValidationIssue('documents[$i]', 'Expected an object'));
          continue;
        }
        final doc = d.cast<String, Object?>();
        // Documents in a bundle inherit the bundle's schemaVersion.
        doc.putIfAbsent('schemaVersion', () => root['schemaVersion']);
        _checkEnvelope(doc, 'documents[$i].', issues);
        docs.add(('documents[$i].', doc));
      }
    }
  } else {
    docs.add(('', root));
  }
  if (issues.any((i) => !i.warning)) return ParsedImport(issues: issues);

  final templates = <TemplateDoc>[];
  final goals = <GoalDoc>[];
  for (final (prefix, doc) in docs) {
    switch (doc['kind']) {
      case 'template':
        if (_checkTemplate(doc, prefix, issues)) templates.add(TemplateDoc(doc));
      case 'goal':
        goals.add(GoalDoc(doc));
      case 'dashboard':
        issues.add(ValidationIssue('${prefix}kind', 'Dashboards are not supported in this version', warning: true));
      default:
        issues.add(ValidationIssue('${prefix}kind', 'Unknown kind "${doc['kind']}"'));
    }
  }

  TemplateDoc? find(String ref) {
    for (final t in templates) {
      if (t.ref == ref) return t;
    }
    return templateLookup(ref);
  }

  for (var i = 0; i < goals.length; i++) {
    final prefix = docs.firstWhere((d) => identical(d.$2, goals[i].json)).$1;
    _checkGoal(goals[i].json, prefix, find, issues);
  }
  return ParsedImport(templates: templates, goals: goals, issues: issues);
}

void _checkEnvelope(Map<String, Object?> doc, String p, List<ValidationIssue> issues) {
  final kind = doc['kind'];
  if (kind is! String) issues.add(ValidationIssue('${p}kind', 'required'));
  final v = doc['schemaVersion'];
  if (v is! String || !RegExp(r'^\d+\.\d+$').hasMatch(v)) {
    issues.add(ValidationIssue('${p}schemaVersion', 'required, in the form MAJOR.MINOR'));
  } else if (int.parse(v.split('.').first) > supportedSchemaMajor) {
    issues.add(ValidationIssue('${p}schemaVersion', 'Version $v needs a newer app. Please update Get On It.'));
  }
  if (kind != 'bundle') {
    final id = doc['id'];
    if (id is! String || !_idPattern.hasMatch(id)) {
      issues.add(ValidationIssue('${p}id', 'required: lowercase letters, digits and hyphens, at most 64'));
    }
  }
}

bool _checkTemplate(Map<String, Object?> doc, String p, List<ValidationIssue> issues) {
  final before = issues.where((i) => !i.warning).length;
  final version = doc['version'];
  if (version is! String || !_semver.hasMatch(version)) {
    issues.add(ValidationIssue('${p}version', 'required, semantic version such as 1.0.0'));
  }
  final engine = doc['engine'];
  if (engine is! String) {
    issues.add(ValidationIssue('${p}engine', 'required'));
  } else if (!Capabilities.engines.contains(engine)) {
    issues.add(ValidationIssue('${p}engine', 'Unknown engine "$engine"'));
  }
  final schema = doc['dataSchema'];
  if (schema != null) {
    try {
      JsonSchema.create(schema);
    } catch (e) {
      issues.add(ValidationIssue('${p}dataSchema', 'Not a valid JSON Schema: $e'));
    }
  }
  final surfaces = doc['surfaces'];
  if (surfaces is! Map || surfaces['screen'] is! Map) {
    issues.add(ValidationIssue('${p}surfaces.screen', 'required'));
  } else {
    for (final e in surfaces.entries) {
      if (e.value is Map) checkTree(e.value as Map, '${p}surfaces.${e.key}', issues);
    }
  }
  return issues.where((i) => !i.warning).length == before;
}

/// Validates a UI tree: size, depth, component names and links.
void checkTree(Map tree, String path, List<ValidationIssue> issues) {
  var count = 0;
  void walk(Object? node, String at, int depth) {
    if (node is! Map) return;
    count++;
    if (depth > maxTreeDepth) {
      issues.add(ValidationIssue(at, 'The tree is deeper than $maxTreeDepth levels'));
      return;
    }
    final type = node['type'];
    if (type is String && !Capabilities.components.contains(type) && node['fallback'] == null) {
      issues.add(ValidationIssue('$at.type', 'Unknown component "$type" without a fallback', warning: true));
    }
    for (final key in const ['src', 'url']) {
      final v = node[key];
      if (v is String && !v.startsWith('{{') && !v.startsWith('https://')) {
        issues.add(ValidationIssue('$at.$key', 'Only https links are allowed'));
      }
    }
    final action = node['action'];
    if (action is Map) {
      final t = action['type'];
      if (t is String && !Capabilities.actions.contains(t)) {
        issues.add(ValidationIssue('$at.action.type', 'Unknown action "$t"', warning: true));
      }
      final url = (action['params'] as Map?)?['url'];
      if (url is String && !url.startsWith('{{') && !url.startsWith('https://')) {
        issues.add(ValidationIssue('$at.action.params.url', 'Only https links are allowed'));
      }
    }
    final children = node['children'];
    if (children is List) {
      for (var i = 0; i < children.length; i++) {
        walk(children[i], '$at.children[$i]', depth + 1);
      }
    }
    for (final key in const ['child', 'item', 'fallback']) {
      walk(node[key], '$at.$key', depth + 1);
    }
  }

  walk(tree, path, 1);
  if (count > maxTreeNodes) {
    issues.add(ValidationIssue(path, 'The tree has more than $maxTreeNodes nodes'));
  }
}

void _checkGoal(Map<String, Object?> doc, String p, TemplateDoc? Function(String) find, List<ValidationIssue> issues) {
  final title = doc['title'];
  if (title is! String || title.trim().isEmpty) {
    issues.add(ValidationIssue('${p}title', 'required'));
  }
  final ref = doc['template'];
  TemplateDoc? template;
  if (ref is! String || !_templateRef.hasMatch(ref)) {
    issues.add(ValidationIssue('${p}template', 'required, in the form <templateId>@<major>, for example course@1'));
  } else {
    template = find(ref);
    if (template == null) issues.add(ValidationIssue('${p}template', 'Template "$ref" is not installed'));
  }
  final accent = doc['accent'];
  if (accent != null && (accent is! String || !_hex.hasMatch(accent))) {
    issues.add(ValidationIssue('${p}accent', 'A hex color such as #e0573f'));
  }
  for (final key in const ['startDate', 'deadline']) {
    if (doc[key] != null && DayClock.parseDate(doc[key]) == null) {
      issues.add(ValidationIssue('$p$key', 'A date in the form YYYY-MM-DD'));
    }
  }
  final days = (doc['schedule'] as Map?)?['days'];
  if (days != null) {
    const valid = {'mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'};
    if (days is! List || days.any((d) => !valid.contains(d))) {
      issues.add(ValidationIssue('${p}schedule.days', 'A list of mon, tue, wed, thu, fri, sat, sun'));
    }
  }
  final data = doc['data'];
  if (data is! Map) {
    issues.add(ValidationIssue('${p}data', 'required'));
    return;
  }
  final schema = template?.dataSchema;
  if (schema != null) {
    final result = JsonSchema.create(schema).validate(data);
    for (final e in result.errors) {
      final at = e.instancePath.replaceAll('/', '.').replaceFirst(RegExp(r'^\.'), '');
      issues.add(ValidationIssue('${p}data${at.isEmpty ? '' : '.$at'}', e.message));
    }
  }
}

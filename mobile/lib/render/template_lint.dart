import '../core/binding/resolver.dart';
import '../core/schema/documents.dart';
import '../core/schema/validator.dart';

/// Components the native home-screen widgets can draw (android/.../widget/
/// WidgetTree.kt). `list` and `embed` are expanded before the tree gets there.
const widgetComponents = {
  'column', 'row', 'grid', 'card', 'text', 'icon', 'badge', 'stat', 'progress_bar', 'progress_ring', //
  'media', 'button', 'checklist_item', 'counter', 'week_dots', 'divider', 'spacer', 'list', 'embed',
};

const _widgetSurfaces = {'tile', 'tile_wide'};

final _binding = RegExp(r'\{\{\s*([^{}]+?)\s*\}\}');
final _plainPath = RegExp(r'^[A-Za-z_][\w-]*(\.[\w-]+)*$');

/// Warnings for a template as one goal will use it: bindings that point at
/// nothing, and parts that the home-screen widgets cannot draw. Both render
/// silently wrong rather than fail, so the import check is the only place
/// they show up.
List<ValidationIssue> lintTemplate(TemplateDoc template, GoalDoc goal, Map<String, Object?> state) {
  final issues = <ValidationIssue>[];
  final dataFields = {
    ...goal.data.keys,
    ...(((template.dataSchema?['properties']) as Map?)?.keys.cast<String>() ?? const <String>[]),
  };
  final scope = <String, Object?>{'goal': goal.scopeValue, 'data': goal.data, 'state': state};

  void checkBinding(String path, String at, Map<String, Object?> vars) {
    if (!_plainPath.hasMatch(path)) {
      issues.add(
        ValidationIssue(at, '"{{$path}}" is not a plain path. Bindings cannot do math or logic', warning: true),
      );
      return;
    }
    final parts = path.split('.');
    final root = parts.first;
    if (vars.containsKey(root)) {
      final sample = vars[root];
      if (sample is Map) _checkKeys(sample, parts.skip(1).toList(), path, at, 'the list items', issues);
      return;
    }
    switch (root) {
      case 'goal':
        _checkKeys(goal.scopeValue, parts.skip(1).toList(), path, at, 'goal', issues);
      case 'state':
        _checkKeys(state, parts.skip(1).toList(), path, at, 'the "${template.engine}" engine', issues);
      case 'data':
        if (parts.length > 1 && !dataFields.contains(parts[1])) {
          issues.add(ValidationIssue(at, '"{{$path}}": the goal has no data field "${parts[1]}"', warning: true));
        }
      default:
        issues.add(
          ValidationIssue(at, '"{{$path}}": bindings start with goal, data, state or a list name', warning: true),
        );
    }
  }

  void walk(Object? node, String at, String surface, Map<String, Object?> vars) {
    if (node is! Map) return;
    final type = node['type'];
    if (_widgetSurfaces.contains(surface) && type is String && !widgetComponents.contains(type)) {
      issues.add(
        ValidationIssue(at, '"$type" does not show on home-screen widgets. Use it only in "screen"', warning: true),
      );
    }
    // A part hidden for this goal (a habit's checklist card on a count habit)
    // may bind keys this goal's state does not have. Check the condition only.
    if (node.containsKey('visible')) {
      _strings(node['visible'], '$at.visible', (s, p) {
        for (final m in _binding.allMatches(s)) {
          checkBinding(m[1]!, p, vars);
        }
      });
      if (!node.cast<String, Object?>().flag('visible', {...scope, ...vars})) return;
    }
    var inner = vars;
    if (type == 'list') {
      final items = resolve(node['items'], {...scope, ...vars});
      final name = node['as'] is String ? node['as'] as String : 'item';
      // An empty list has no item to compare with; any field may be right.
      inner = {...vars, name: items is List && items.isNotEmpty ? items.first : null};
    }
    for (final e in node.entries) {
      final key = e.key as String;
      final value = e.value;
      final path = '$at.$key';
      switch (key) {
        case 'children':
          final list = value is List ? value : const [];
          for (var i = 0; i < list.length; i++) {
            walk(list[i], '$path[$i]', surface, vars);
          }
        case 'child' || 'fallback':
          walk(value, path, surface, vars);
        case 'visible':
          break;
        case 'item':
          walk(value, path, surface, inner);
        default:
          _strings(value, path, (s, p) {
            for (final m in _binding.allMatches(s)) {
              checkBinding(m[1]!, p, vars);
            }
          });
      }
    }
  }

  for (final s in ['screen', 'tile', 'tile_wide']) {
    final tree = template.surface(s);
    if (tree != null) walk(tree, 'surfaces.$s', s, const {});
  }
  return issues;
}

void _strings(Object? value, String at, void Function(String s, String at) onString) {
  if (value is String) {
    onString(value, at);
  } else if (value is Map) {
    for (final e in value.entries) {
      _strings(e.value, '$at.${e.key}', onString);
    }
  } else if (value is List) {
    for (var i = 0; i < value.length; i++) {
      _strings(value[i], '$at[$i]', onString);
    }
  }
}

/// Follows [keys] into [map]. Stops quietly at a value that is not a map
/// (null, a list, a number): there the engine decides at run time.
void _checkKeys(
  Map<Object?, Object?> map,
  List<String> keys,
  String path,
  String at,
  String owner,
  List<ValidationIssue> issues,
) {
  Object? current = map;
  for (final k in keys) {
    if (current is! Map) return;
    if (!current.containsKey(k)) {
      final known = current.keys.map((e) => '$e').toList()..sort();
      issues.add(ValidationIssue(at, '"{{$path}}": $owner has no "$k". Known: ${known.join(', ')}', warning: true));
      return;
    }
    current = current[k];
  }
}

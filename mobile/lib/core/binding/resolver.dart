/// Resolves `{{path}}` bindings against a scope. Spec §6.2.
///
/// Paths only: no expressions, no function calls. A string that is exactly one
/// binding returns the raw value; mixed text returns a string.
library;

final _binding = RegExp(r'\{\{\s*([^{}]+?)\s*\}\}');
final _whole = RegExp(r'^\{\{\s*([^{}]+?)\s*\}\}$');

Object? lookup(String path, Map<String, Object?> scope) {
  Object? current = scope;
  for (final key in path.split('.')) {
    if (current is Map) {
      current = current[key];
    } else if (current is List) {
      final i = int.tryParse(key);
      if (i == null || i < 0 || i >= current.length) return null;
      current = current[i];
    } else {
      return null;
    }
  }
  return current;
}

Object? resolve(Object? value, Map<String, Object?> scope) {
  if (value is String) {
    final whole = _whole.firstMatch(value);
    if (whole != null) return lookup(whole[1]!, scope);
    if (!value.contains('{{')) return value;
    return value.replaceAllMapped(_binding, (m) => _text(lookup(m[1]!, scope)));
  }
  if (value is List) return [for (final v in value) resolve(v, scope)];
  if (value is Map) {
    return {for (final e in value.entries) e.key as String: resolve(e.value, scope)};
  }
  return value;
}

String _text(Object? v) {
  if (v == null) return '';
  if (v is double && v == v.roundToDouble()) return v.toInt().toString();
  return v.toString();
}

/// Convenience readers for resolved node properties.
extension ResolvedRead on Map<String, Object?> {
  String? str(String key, Map<String, Object?> scope) {
    final v = resolve(this[key], scope);
    return v == null ? null : _text(v);
  }

  double? number(String key, Map<String, Object?> scope) {
    final v = resolve(this[key], scope);
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  bool flag(String key, Map<String, Object?> scope, {bool fallback = false}) {
    final v = resolve(this[key], scope);
    if (v == null) return fallback;
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v.isNotEmpty && v != 'false';
    return true;
  }
}

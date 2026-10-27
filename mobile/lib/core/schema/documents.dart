import 'dart:convert';

import '../time/day_clock.dart';

const supportedSchemaMajor = 1;

const _weekdays = {'mon': 1, 'tue': 2, 'wed': 3, 'thu': 4, 'fri': 5, 'sat': 6, 'sun': 7};

/// Weekday numbers (1 = Monday) for names like "mon".
Set<int> weekdaysOf(List<Object?> names) => {
  for (final d in names)
    if (_weekdays[d] != null) _weekdays[d]!,
};

/// A goal document. Spec §5.3.
class GoalDoc {
  GoalDoc(this.json);

  final Map<String, Object?> json;

  String get id => json['id'] as String;
  String get title => json['title'] as String;
  String get templateRef => json['template'] as String;
  String get templateId => templateRef.split('@').first;
  int get templateMajor => int.parse(templateRef.split('@').last);
  String? get accent => json['accent'] as String?;
  String? get icon => json['icon'] as String?;
  int? get startDay => DayClock.parseDate(json['startDate']);
  int? get deadlineDay => DayClock.parseDate(json['deadline']);

  Map<String, Object?> get data => (json['data'] as Map?)?.cast<String, Object?>() ?? const {};

  Map<String, Object?>? get reminders => (json['reminders'] as Map?)?.cast<String, Object?>();

  /// Scheduled weekdays, 1 = Monday. Without a schedule, checklist steps
  /// that name their days (an exercise per weekday) set it: the other days
  /// are rest days. Otherwise every day.
  Set<int> get scheduleDays {
    final days = (json['schedule'] as Map?)?['days'];
    if (days is List && days.isNotEmpty) return weekdaysOf(days);
    final stepDays = {
      for (final s in (data['steps'] as List? ?? const []))
        if (s is Map && s['days'] is List) ...weekdaysOf(s['days'] as List),
    };
    return stepDays.isEmpty ? {1, 2, 3, 4, 5, 6, 7} : stepDays;
  }

  /// The `goal` key of the render scope. Spec §6.1.
  Map<String, Object?> get scopeValue => {
    'id': id,
    'title': title,
    'accent': accent,
    'icon': icon ?? '🎯',
    'deadline': json['deadline'],
    'startDate': json['startDate'],
    'template': templateRef,
  };

  String encode() => jsonEncode(json);
}

/// A template document. Spec §5.4.
class TemplateDoc {
  TemplateDoc(this.json);

  final Map<String, Object?> json;

  String get id => json['id'] as String;
  String get version => json['version'] as String;
  int get major => int.parse(version.split('.').first);
  String get ref => '$id@$major';
  String get title => (json['title'] as String?) ?? id;
  String get engine => json['engine'] as String;
  Map<String, Object?>? get dataSchema => (json['dataSchema'] as Map?)?.cast<String, Object?>();

  Map<String, Object?> get surfaces => (json['surfaces'] as Map?)?.cast<String, Object?>() ?? const {};

  /// A surface tree by dotted name, for example `widget.small`.
  Map<String, Object?>? surface(String name) {
    Object? node = surfaces;
    for (final part in name.split('.')) {
      node = node is Map ? node[part] : null;
    }
    return (node as Map?)?.cast<String, Object?>();
  }

  /// Compares semantic versions; positive when this one is newer.
  int compareVersion(TemplateDoc other) {
    final a = version.split('.').map(int.parse).toList();
    final b = other.version.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      final c = a[i].compareTo(b[i]);
      if (c != 0) return c;
    }
    return 0;
  }

  String encode() => jsonEncode(json);
}

import '../../app/providers.dart';
import '../../engines/page_range.dart';

/// What one unit of an open goal takes: one lecture of 75 min, one page of
/// 2 min. Lost time is told in these units.
class Equivalent {
  const Equivalent(this.unitMinutes, this.singular, this.plural);

  final double unitMinutes;
  final String singular;
  final String plural;

  Map<String, Object?> toJson() => {'unitMinutes': unitMinutes, 'singular': singular, 'plural': plural};
}

/// Units of the goals still open today, the most behind first, at most two.
/// Courses count in lectures, books in pages, minute habits in sessions;
/// other habits have no length and are left out.
List<Equivalent> equivalentsFor(Iterable<GoalView> views) {
  final open = [
    for (final v in views)
      if (v.state['todayComplete'] != true && v.state['todayScheduled'] != false && v.state['isComplete'] != true) v,
  ];
  int behind(GoalView v) => ((v.state['pace'] as Map?)?['behindDays'] as num? ?? 0).toInt();
  open.sort((a, b) => behind(b).compareTo(behind(a)));
  return [for (final v in open) ?_unitOf(v)].take(2).toList();
}

final _minuteUnits = RegExp(r'^min(ute)?s?$');

Equivalent? _unitOf(GoalView v) {
  final s = v.state;
  final short = v.goal.title.split(':').first.trim();
  switch (v.template?.engine) {
    case 'video_series':
      final next = s['next'] as Map?;
      if (next == null || next['isVideo'] != true) return null;
      final item = ((v.goal.data['items'] as List?) ?? const []).whereType<Map>().where((i) => i['id'] == next['id']);
      final seconds = (item.firstOrNull?['durationSec'] as num?)?.toDouble() ?? 0;
      if (seconds <= 0) return null;
      return Equivalent(seconds / 60, '$short lecture', '$short lectures');
    case 'page_range':
      final book = (s['book'] as Map?)?['title'] as String? ?? short;
      return Equivalent(PageRangeEngine.minutesPerPage.toDouble(), 'page of $book', 'pages of $book');
  }
  // A count habit in minutes: one session is the daily target.
  final unit = (v.goal.data['unit'] as String? ?? '').trim().toLowerCase();
  final target = (s['target'] as num?)?.toDouble() ?? 0;
  if (s['isCount'] == true || v.template?.engine == 'count') {
    if (_minuteUnits.hasMatch(unit) && target > 0) return Equivalent(target, '$short session', '$short sessions');
  }
  return null;
}

/// One app's lost time today, from the phone. It never leaves the phone.
class AppUsage {
  const AppUsage(this.package, this.label, this.category, this.minutes);

  final String package;
  final String label;
  final String category;
  final int minutes;
}

// The same words as the nudges (android/.../nudge/NudgeRules.kt, Wording).

String formatDuration(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '$m min';
  return m == 0 ? '$h h' : '$h h $m min';
}

/// "scrolling Instagram", "watching YouTube", "on Chrome".
String doing(String category, String label) => switch (category) {
  'social' => 'scrolling $label',
  'video' => 'watching $label',
  'game' => 'playing $label',
  'news' => 'reading news on $label',
  _ => 'on $label',
};

/// "2 CS229 lectures, or 40 pages of Atomic Habits"; null when no unit fits.
String? couldHave(int minutes, List<Equivalent> equivalents) {
  final parts = [
    for (final e in equivalents.take(2))
      if (e.unitMinutes > 0 && minutes ~/ e.unitMinutes > 0)
        minutes ~/ e.unitMinutes == 1 ? '1 ${e.singular}' : '${minutes ~/ e.unitMinutes} ${e.plural}',
  ];
  return parts.isEmpty ? null : parts.join(', or ');
}

import '../../app/providers.dart';
import '../../engines/page_range.dart';

/// What one unit of an open goal takes: one lecture of 75 min, one page of
/// 2 min. Lost time is told in these units.
/// [whole] is the whole goal ("the whole course", [wholeMinutes] long), told
/// once the time is bigger than it.
class Equivalent {
  const Equivalent(this.unitMinutes, this.singular, this.plural, {this.wholeMinutes = 0, this.whole = ''});

  final double unitMinutes;
  final String singular;
  final String plural;
  final double wholeMinutes;
  final String whole;

  Map<String, Object?> toJson() => {
    'unitMinutes': unitMinutes,
    'singular': singular,
    'plural': plural,
    'wholeMinutes': wholeMinutes,
    'whole': whole,
  };
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
      final items = ((v.goal.data['items'] as List?) ?? const []).whereType<Map>();
      final seconds = (items.where((i) => i['id'] == next['id']).firstOrNull?['durationSec'] as num?)?.toDouble() ?? 0;
      if (seconds <= 0) return null;
      final all = items.fold<double>(0, (sum, i) => sum + ((i['durationSec'] as num?)?.toDouble() ?? 0));
      return Equivalent(
        seconds / 60,
        '$short lecture',
        '$short lectures',
        wholeMinutes: all / 60,
        whole: 'the whole course',
      );
    case 'page_range':
      final book = (s['book'] as Map?)?['title'] as String? ?? short;
      final pages = v.goal.data['pages'] as Map? ?? const {};
      final start = (pages['start'] as num?)?.toInt() ?? 1;
      final end = (pages['end'] as num?)?.toInt() ?? 0;
      final last = (s['lastPage'] as num?)?.toInt() ?? start - 1;
      final left = end - last;
      const perPage = PageRangeEngine.minutesPerPage;
      return Equivalent(
        perPage.toDouble(),
        'page of $book',
        'pages of $book',
        wholeMinutes: (left > 0 ? left : 0) * perPage.toDouble(),
        whole: last < start ? 'the whole book' : 'the rest of the book',
      );
  }
  // A count habit in minutes: one session is the daily target.
  final unit = (v.goal.data['unit'] as String? ?? '').trim().toLowerCase();
  final target = (s['target'] as num?)?.toDouble() ?? 0;
  if (s['isCount'] == true || v.template?.engine == 'count') {
    if (_minuteUnits.hasMatch(unit) && target > 0) return Equivalent(target, '$short session', '$short sessions');
  }
  return null;
}

enum LostPeriod {
  today('Today'),
  month('This month'),
  year('This year');

  const LostPeriod(this.label);

  final String label;
}

/// One app's lost time, from the phone. It never leaves the phone.
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
  final parts = <String>[];
  for (final e in equivalents.take(2)) {
    if (e.unitMinutes <= 0) continue;
    final n = minutes ~/ e.unitMinutes;
    if (n <= 0) continue;
    final units = n == 1 ? '1 ${e.singular}' : '$n ${e.plural}';
    final times = e.wholeMinutes > 0 && e.whole.isNotEmpty ? minutes ~/ e.wholeMinutes : 0;
    parts.add(switch (times) {
      <= 0 => units,
      1 => '$units, or ${e.whole}',
      _ => '$units, or ${e.whole} $times times',
    });
  }
  return parts.isEmpty ? null : parts.join(', or ');
}

/// "social and video apps" for the categories among [apps]; "other apps"
/// for apps without one (watched apps the user chose).
String appKinds(Iterable<AppUsage> apps) {
  const order = ['social', 'video', 'game', 'news'];
  final kinds = [
    for (final k in order)
      if (apps.any((a) => a.category == k)) k,
  ];
  if (kinds.isEmpty) return 'other apps';
  final list = kinds.length == 1 ? kinds.first : '${kinds.sublist(0, kinds.length - 1).join(', ')} and ${kinds.last}';
  return '$list apps';
}

import 'dart:math' as math;

import '../core/events/goal_event.dart';
import '../core/schema/documents.dart';
import 'engine.dart';

/// Reading a page range at a daily pace. Spec §7.4.
///
/// Today's pages are fixed at the start of the day: they come from the pages
/// read before today, so reading does not move today's target.
class PageRangeEngine implements ProgressEngine {
  const PageRangeEngine();

  static const minutesPerPage = 2;

  @override
  String get id => 'page_range';

  @override
  String summary(GoalDoc goal) {
    final pages = (goal.data['pages'] as Map?) ?? const {};
    final start = asNum(pages['start']) ?? 1;
    final end = asNum(pages['end']) ?? start;
    final perDay = asNum(pages['perDay']);
    return [
      'pages $start–$end',
      if (goal.deadlineDay != null)
        'deadline ${shortDate(goal.deadlineDay!)}'
      else if (perDay != null)
        '$perDay per day',
    ].join(' · ');
  }

  @override
  Map<String, Object?> computeState(EngineContext c) {
    final pages = (c.data['pages'] as Map?) ?? const {};
    final start = (asNum(pages['start']) ?? 1).toInt();
    final end = math.max(start, (asNum(pages['end']) ?? start).toInt());
    final fixedPerDay = asNum(pages['perDay'])?.toInt();
    final source = ((c.data['source'] as Map?)?['kind'] as String?) ?? 'local_file';
    final book = (c.data['book'] as Map?) ?? const {};

    // (day, page) in time order.
    final reached = [
      for (final e in c.ofType(EventType.pageReached))
        if (asNum(e['page']) != null) (c.dayOf(e), asNum(e['page'])!.toInt()),
    ];

    int pageBefore(int day) {
      var p = start - 1;
      for (final (d, page) in reached) {
        if (d < day && page > p) p = page;
      }
      return math.min(p, end);
    }

    int pageAtEndOf(int day) {
      var p = start - 1;
      for (final (d, page) in reached) {
        if (d <= day && page > p) p = page;
      }
      return math.min(p, end);
    }

    // With a deadline, the pace follows the pages and days left. The deadline
    // wins over a fixed perDay. Spec §7.4.
    int perDayFor(int day) {
      final deadline = c.deadlineDay;
      if (deadline != null) {
        final remaining = end - pageBefore(day);
        if (remaining <= 0) return 0;
        if (day > deadline) return remaining;
        final days = math.max(1, c.scheduledDaysBetween(day, deadline));
        return math.max(1, (remaining / days).ceil());
      }
      return math.max(1, fixedPerDay ?? 1);
    }

    bool dayComplete(int day) {
      final before = pageBefore(day);
      if (before >= end) return true;
      final target = math.min(end, before + perDayFor(day));
      return pageAtEndOf(day) >= target;
    }

    final lastPage = pageAtEndOf(c.today);
    final dayStart = pageBefore(c.today);
    final perDay = perDayFor(c.today);
    final todayStart = math.min(end, dayStart + 1);
    final todayEnd = math.min(end, dayStart + perDay);
    final total = end - start + 1;
    final read = lastPage - (start - 1);

    // Expected finish at today's pace, counting scheduled days only.
    String finishLabel = '';
    if (lastPage >= end) {
      finishLabel = 'Finished';
    } else if (perDay > 0) {
      var pagesLeft = end - lastPage;
      var day = c.today + (dayComplete(c.today) ? 1 : 0);
      for (var guard = 0; guard < 3660; guard++, day++) {
        if (!c.isScheduled(day)) continue;
        pagesLeft -= perDay;
        if (pagesLeft <= 0) break;
      }
      finishLabel = 'Finish ≈ ${shortDate(day)}';
    }

    final needsFile = (source == 'local_file' || source == 'drive_file') && !c.linkedFiles.containsKey(c.goal.id);

    final common = commonState(
      c,
      progress: total == 0 ? 0 : read / total,
      dayComplete: dayComplete,
      progressLabel: 'Page ${math.max(0, lastPage)} of $end',
    );

    final todayLabel = todayStart == todayEnd ? 'p. $todayStart' : 'p. $todayStart–$todayEnd';
    return {
      ...common,
      'book': {'title': book['title'], 'author': book['author']},
      'source': source,
      'isPhysical': source == 'physical',
      'isUrl': source == 'url',
      'url': (c.data['source'] as Map?)?['url'],
      'needsFile': needsFile,
      'canOpen': source == 'url' || (!needsFile && source != 'physical'),
      'lastPage': lastPage,
      'nextPage': math.min(end, lastPage + 1),
      'perDay': perDay,
      'perDayLabel': '$perDay ${perDay == 1 ? 'page' : 'pages'} per day',
      'today': {
        'startPage': todayStart,
        'endPage': todayEnd,
        'label': lastPage >= end ? 'Finished' : todayLabel,
        'minutesLabel': '≈ ${math.max(1, (todayEnd - todayStart + 1) * minutesPerPage)} min',
        'pagesLeft': math.max(0, todayEnd - lastPage),
      },
      'finishLabel': finishLabel,
    };
  }
}

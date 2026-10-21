import 'dart:math' as math;

import '../core/events/goal_event.dart';
import '../core/schema/documents.dart';
import 'engine.dart';

/// Course progress from a list of videos and tasks. Spec §7.3.
///
/// Two rules per video: "Resume" uses the newest position, while progress
/// uses the highest position, so re-watching a part never lowers progress.
class VideoSeriesEngine implements ProgressEngine {
  const VideoSeriesEngine();

  static const taskWeightSec = 900;

  @override
  String get id => 'video_series';

  @override
  String summary(GoalDoc goal) {
    final items = _items(goal.data);
    final videos = items.where((i) => i['kind'] != 'task').length;
    final tasks = items.length - videos;
    final total = items.fold<num>(0, (s, i) => s + (asNum(i['durationSec']) ?? 0));
    return [
      '$videos ${videos == 1 ? 'video' : 'videos'}',
      if (tasks > 0) '$tasks ${tasks == 1 ? 'task' : 'tasks'}',
      if (total > 0) minutesLabel(total),
      if (goal.deadlineDay != null) 'deadline ${shortDate(goal.deadlineDay!)}',
    ].join(' · ');
  }

  static List<Map<String, Object?>> _items(Map<String, Object?> data) => [
    for (final i in (data['items'] as List? ?? const []))
      if (i is Map) i.cast<String, Object?>(),
  ];

  @override
  Map<String, Object?> computeState(EngineContext c) {
    final items = _items(c.data);
    final threshold = (asNum(c.data['completionThreshold']) ?? 0.9).toDouble();
    final dailyTargetSec = (asNum(c.data['dailyTargetMinutes']) ?? 30) * 60;
    final duration = {for (final i in items) i['id'] as String: (asNum(i['durationSec']) ?? 0).toDouble()};
    final isTask = {for (final i in items) i['id'] as String: i['kind'] == 'task'};

    final maxSec = <String, double>{};
    final lastSec = <String, double>{};
    final lastAt = <String, int>{};
    final explicit = <String, bool>{};
    final watchedByDay = <int, double>{};
    final doneOnDay = <int>{};

    bool isDone(String id) {
      final e = explicit[id];
      if (e != null) return e;
      final d = duration[id] ?? 0;
      return isTask[id] != true && d > 0 && (maxSec[id] ?? 0) >= threshold * d;
    }

    for (final e in c.events) {
      final item = e['item'];
      if (item is! String || !duration.containsKey(item)) continue;
      final wasDone = isDone(item);
      if (e.type == EventType.itemPosition) {
        final sec = (asNum(e['sec']) ?? 0).toDouble();
        final prev = lastSec[item];
        final prevAt = lastAt[item];
        if (prev != null && prevAt != null) {
          // Watch time is forward movement no faster than the clock, so a
          // seek ahead does not count as watching.
          final delta = sec - prev;
          final gap = (e.utcMs - prevAt) / 1000;
          if (delta > 0 && delta <= gap + 5) {
            final day = c.dayOf(e);
            watchedByDay[day] = (watchedByDay[day] ?? 0) + delta;
          }
        }
        lastSec[item] = sec;
        lastAt[item] = e.utcMs;
        maxSec[item] = math.max(maxSec[item] ?? 0, sec);
      } else if (e.type == EventType.itemDone) {
        explicit[item] = e['done'] != false;
      }
      if (!wasDone && isDone(item)) doneOnDay.add(c.dayOf(e));
    }

    double watchedOf(String id) {
      final d = isTask[id] == true ? taskWeightSec.toDouble() : (duration[id] ?? 0);
      if (isDone(id)) return d;
      return isTask[id] == true ? 0 : math.min(maxSec[id] ?? 0, d);
    }

    double total = 0, watched = 0;
    var doneCount = 0, videoCount = 0, videosDone = 0;
    final itemStates = <Map<String, Object?>>[];
    Map<String, Object?>? next;
    for (final i in items) {
      final id = i['id'] as String;
      final task = isTask[id] == true;
      final d = duration[id] ?? 0;
      total += task ? taskWeightSec : d;
      watched += watchedOf(id);
      final done = isDone(id);
      if (done) doneCount++;
      if (!task) {
        videoCount++;
        if (done) videosDone++;
      }
      final position = lastSec[id] ?? 0;
      final fraction = task || d == 0 ? (done ? 1.0 : 0.0) : (done ? 1.0 : math.min(1.0, (maxSec[id] ?? 0) / d));
      final week = i['week'];
      final state = <String, Object?>{
        'id': id,
        'title': i['title'],
        'kind': task ? 'task' : 'video',
        'isVideo': !task,
        'isTask': task,
        'videoId': i['videoId'],
        // Some owners block playback in other apps; those open on YouTube.
        'embeddable': task || i['embeddable'] != false,
        'external': !task && i['embeddable'] == false,
        'url': i['url'],
        'week': week,
        'done': done,
        'watched': fraction,
        'positionSec': done ? 0 : position.round(),
        'positionLabel': clockLabel(done ? 0 : position),
        'resumeLabel': i['embeddable'] == false ? 'Watch on YouTube' : 'Resume ${clockLabel(done ? 0 : position)}',
        'durationLabel': task ? 'Task' : minutesLabel(d),
        'remainingLabel': task ? '' : '${minutesLabel(math.max(0, d - position))} left',
        'sub': [
          if (week != null) 'Week $week',
          task ? 'Task' : minutesLabel(d),
          if (!task && !done && fraction > 0) '${(fraction * 100).round()}%',
        ].join(' · '),
      };
      itemStates.add(state);
      if (!done && next == null) next = state;
    }

    final progress = total == 0 ? 0.0 : watched / total;
    final common = commonState(
      c,
      progress: progress,
      dayComplete: (day) => (watchedByDay[day] ?? 0) >= dailyTargetSec || doneOnDay.contains(day),
      progressLabel: '$videosDone of $videoCount videos',
    );

    final remainingDays = c.deadlineDay == null ? 0 : c.scheduledDaysBetween(c.today, c.deadlineDay!);
    final left = items.length - doneCount;
    final perWeek = remainingDays == 0 ? 0 : (left / remainingDays * c.goal.scheduleDays.length).ceil();

    return {
      ...common,
      'items': itemStates,
      'next': next,
      'hasNext': next != null,
      'doneCount': doneCount,
      'itemCount': items.length,
      'lecturesLabel': '$videosDone / $videoCount',
      'hoursLabel': '${(watched / 3600).toStringAsFixed(1)} / ${(total / 3600).toStringAsFixed(1)} h',
      'todayWatchedLabel': minutesLabel(watchedByDay[c.today] ?? 0),
      'paceText': c.deadlineDay == null || left == 0
          ? ''
          : 'Finish $perWeek ${perWeek == 1 ? 'item' : 'items'} per week to finish by ${shortDate(c.deadlineDay!)}.',
    };
  }
}

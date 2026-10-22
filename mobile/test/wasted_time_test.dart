import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/app/providers.dart';
import 'package:getonit/core/schema/documents.dart';
import 'package:getonit/core/time/day_clock.dart';
import 'package:getonit/features/nudges/wasted_time.dart';

import 'support/harness.dart';

void main() {
  final templates = {
    for (final n in ['course', 'book', 'habit']) '$n@1': TemplateDoc(readJson('assets/templates/$n.json')),
  };
  final now = DateTime(2026, 10, 21, 9);

  GoalView view(GoalDoc g, {Map<String, Object?> state = const {}}) {
    final t = templates[g.templateRef]!;
    final s = previewState(t, g, clock: const DayClock(), now: now);
    return GoalView(goal: g, template: t, state: {...s, ...state}, createdAt: now);
  }

  GoalDoc sample(String name) => GoalDoc(readJson('assets/samples/$name.getonit.json'));

  test('courses count in lectures, books in pages, minute habits in sessions', () {
    final course = equivalentsFor([view(sample('course-cs229'))]).single;
    expect(course.unitMinutes, closeTo(4520 / 60, 0.01));
    expect(course.singular, 'Stanford CS229 lecture');
    expect(course.plural, 'Stanford CS229 lectures');

    final book = equivalentsFor([view(sample('book-atomic-habits'))]).single;
    expect(book.unitMinutes, 2);
    expect(book.plural, 'pages of Atomic Habits');

    final guitar = goal(
      'habit@1',
      {'mode': 'count', 'unit': 'minutes', 'target': 20},
      extra: {'title': 'Guitar practice'},
    );
    final session = equivalentsFor([view(guitar)]).single;
    expect(session.unitMinutes, 20);
    expect(session.plural, 'Guitar practice sessions');
  });

  test('habits without a length, and work done today, are left out', () {
    expect(equivalentsFor([view(sample('habit-water')), view(sample('habit-meditate'))]), isEmpty);
    expect(
      equivalentsFor([
        view(sample('book-atomic-habits'), state: {'todayComplete': true}),
      ]),
      isEmpty,
    );
  });

  test('at most two goals, the most behind first', () {
    final behind = {'behindDays': 5};
    final list = equivalentsFor([
      view(sample('book-atomic-habits')),
      view(sample('course-cs229'), state: {'pace': behind}),
      view(goal('habit@1', {'mode': 'count', 'unit': 'min', 'target': 15})),
    ]);
    expect(list.map((e) => e.plural), ['Stanford CS229 lectures', 'pages of Atomic Habits']);
  });

  test('the words match the nudges', () {
    const lecture = Equivalent(75, 'CS229 lecture', 'CS229 lectures');
    const page = Equivalent(2, 'page of Atomic Habits', 'pages of Atomic Habits');
    expect(formatDuration(5), '5 min');
    expect(formatDuration(60), '1 h');
    expect(formatDuration(80), '1 h 20 min');
    expect(doing('social', 'Instagram'), 'scrolling Instagram');
    expect(doing('video', 'YouTube'), 'watching YouTube');
    expect(doing('game', 'Candy Crush'), 'playing Candy Crush');
    expect(doing('news', 'BBC'), 'reading news on BBC');
    expect(doing('', 'Chrome'), 'on Chrome');
    expect(couldHave(160, [lecture, page]), '2 CS229 lectures, or 80 pages of Atomic Habits');
    expect(couldHave(80, [lecture, page]), '1 CS229 lecture, or 40 pages of Atomic Habits');
    expect(couldHave(30, [lecture, page]), '15 pages of Atomic Habits');
    expect(couldHave(1, [lecture, page]), isNull);
  });

  test('time bigger than a goal counts whole goals: the whole course, the rest of a book', () {
    final course = equivalentsFor([view(sample('course-cs229'))]).single;
    final items = (sample('course-cs229').data['items'] as List).cast<Map>();
    final all = items.fold<num>(0, (s, i) => s + ((i['durationSec'] as num?) ?? 0)) / 60;
    expect(course.wholeMinutes, closeTo(all, 0.01));
    expect(course.whole, 'the whole course');
    final threeTimes = (all * 3).ceil();
    expect(couldHave(threeTimes, [course]), endsWith(', or the whole course 3 times'));
    expect(couldHave(all.ceil(), [course]), endsWith(', or the whole course'));
    expect(couldHave(80, [course]), '1 Stanford CS229 lecture');

    final book = equivalentsFor([view(sample('book-atomic-habits'))]).single;
    final pages = sample('book-atomic-habits').data['pages'] as Map;
    expect(book.wholeMinutes, ((pages['end'] as num) - (pages['start'] as num) + 1) * 2);
    expect(book.whole, 'the whole book');
    final read = view(sample('book-atomic-habits'), state: {'lastPage': 100});
    expect(equivalentsFor([read]).single.whole, 'the rest of the book');
  });

  test('the kinds of apps, for "On social and video apps"', () {
    expect(appKinds(const [AppUsage('a', 'A', 'video', 1), AppUsage('b', 'B', 'social', 1)]), 'social and video apps');
    expect(appKinds(const [AppUsage('a', 'A', 'game', 1)]), 'game apps');
    expect(appKinds(const [AppUsage('a', 'A', '', 1)]), 'other apps');
    expect(
      appKinds(const [AppUsage('a', 'A', 'news', 1), AppUsage('b', 'B', 'social', 1), AppUsage('c', 'C', 'game', 1)]),
      'social, game and news apps',
    );
  });
}

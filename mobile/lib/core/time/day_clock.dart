/// Days are counted as whole days since 1970-01-01 in the user's local time,
/// shifted by the "my day starts at" hour. A day number is the unit every
/// engine works in: streaks, schedules, today's target.
class DayClock {
  const DayClock({this.dayStartHour = 0});

  /// Hour (0–23) at which a new day begins. With 4, reading at 01:00 counts
  /// for the day before.
  final int dayStartHour;

  static const _msPerDay = 86400000;

  /// The day an instant belongs to. [offsetMinutes] is the UTC offset that
  /// was in force at that instant, so travel does not move old events.
  int dayOf(int utcMs, int offsetMinutes) {
    final local = utcMs + offsetMinutes * 60000 - dayStartHour * 3600000;
    return (local / _msPerDay).floor();
  }

  int dayOfDateTime(DateTime t) => dayOf(t.toUtc().millisecondsSinceEpoch, t.timeZoneOffset.inMinutes);

  /// Parses `YYYY-MM-DD` as a day number. Returns null for anything else.
  static int? parseDate(Object? value) {
    if (value is! String) return null;
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
    if (m == null) return null;
    final d = DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    return d.millisecondsSinceEpoch ~/ _msPerDay;
  }

  static DateTime dateOf(int day) => DateTime.utc(1970, 1, 1 + day);

  /// 1 = Monday … 7 = Sunday.
  static int weekdayOf(int day) => dateOf(day).weekday;

  static String isoDate(int day) {
    final d = dateOf(day);
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }
}

/// A moment in time as the engines see it.
class Now {
  const Now(this.utcMs, this.offsetMinutes);

  factory Now.of(DateTime t) => Now(t.toUtc().millisecondsSinceEpoch, t.timeZoneOffset.inMinutes);

  final int utcMs;
  final int offsetMinutes;
}

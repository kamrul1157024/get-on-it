import 'dart:convert';

/// Event types the engines understand. Spec §7.8.
abstract final class EventType {
  static const itemPosition = 'item_position';
  static const itemDone = 'item_done';
  static const pageReached = 'page_reached';
  static const countDelta = 'count_delta';
  static const check = 'check';
  static const stepDone = 'step_done';
  static const timerSession = 'timer_session';
  static const daySkipped = 'day_skipped';
}

/// One thing that happened. Progress is stored only as events; state is
/// always computed from them.
class GoalEvent {
  const GoalEvent({
    required this.id,
    required this.goalId,
    required this.type,
    required this.payload,
    required this.utcMs,
    required this.offsetMinutes,
    this.device = 'local',
  });

  final String id;
  final String goalId;
  final String type;
  final Map<String, Object?> payload;
  final int utcMs;
  final int offsetMinutes;
  final String device;

  Object? operator [](String key) => payload[key];

  String get payloadJson => jsonEncode(payload);

  /// Events are applied in time order, then by id, so the order is always the
  /// same on every device.
  static int compare(GoalEvent a, GoalEvent b) {
    final c = a.utcMs.compareTo(b.utcMs);
    return c != 0 ? c : a.id.compareTo(b.id);
  }

  Map<String, Object?> toJson() => {
    'id': id,
    't': DateTime.fromMillisecondsSinceEpoch(utcMs, isUtc: true).toIso8601String(),
    'tz': offsetMinutes,
    'goal': goalId,
    'event': type,
    'device': device,
    ...payload,
  };
}

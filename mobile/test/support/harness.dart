import 'dart:convert';
import 'dart:io';

import 'package:getonit/core/events/goal_event.dart';
import 'package:getonit/core/schema/documents.dart';
import 'package:getonit/core/time/day_clock.dart';
import 'package:getonit/engines/engine.dart';

var _seq = 0;

/// An event at a UTC time with an optional UTC offset in minutes.
GoalEvent ev(String type, Map<String, Object?> payload, DateTime utc, {int offset = 0, String goal = 'g'}) => GoalEvent(
  id: 'e${(_seq++).toString().padLeft(6, '0')}',
  goalId: goal,
  type: type,
  payload: payload,
  utcMs: utc.millisecondsSinceEpoch,
  offsetMinutes: offset,
);

GoalDoc goal(String template, Map<String, Object?> data, {Map<String, Object?> extra = const {}}) => GoalDoc({
  'kind': 'goal',
  'schemaVersion': '1.0',
  'id': 'g',
  'template': template,
  'title': 'Test goal',
  'data': data,
  ...extra,
});

EngineContext ctx(
  GoalDoc g,
  List<GoalEvent> events,
  DateTime nowUtc, {
  int offset = 0,
  int dayStartHour = 0,
  String? importedOn,
  Map<String, String> files = const {},
}) => EngineContext(
  goal: g,
  events: events,
  now: Now(nowUtc.millisecondsSinceEpoch, offset),
  clock: DayClock(dayStartHour: dayStartHour),
  importedDay: importedOn == null ? null : DayClock.parseDate(importedOn),
  linkedFiles: files,
);

DateTime at(String iso) => DateTime.parse('${iso}Z');

Map<String, Object?> readJson(String path) => (jsonDecode(File(path).readAsStringSync()) as Map).cast();

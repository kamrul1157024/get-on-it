import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';

/// A minute of the day as the user reads clock times: "19:00" with the
/// phone's 24-hour setting on, "7:00 PM" with it off. For display only;
/// settings and plans store "HH:MM" (`clockText`).
///
/// Without [use24h] it reads the phone setting directly, for text built
/// outside a screen (notifications, home-screen widgets).
String clockDisplay(int minuteOfDay, {bool? use24h}) {
  final h24 = use24h ?? PlatformDispatcher.instance.alwaysUse24HourFormat;
  final h = (minuteOfDay ~/ 60) % 24;
  final m = (minuteOfDay % 60).toString().padLeft(2, '0');
  if (h24) return '${h.toString().padLeft(2, '0')}:$m';
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12:$m ${h < 12 ? 'AM' : 'PM'}';
}

/// [clockDisplay] inside a screen, following the setting the screen sees.
String clockOf(BuildContext context, int minuteOfDay) =>
    clockDisplay(minuteOfDay, use24h: MediaQuery.alwaysUse24HourFormatOf(context));

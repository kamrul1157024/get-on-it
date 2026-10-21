import 'dart:async';

import 'package:flutter/services.dart';

/// Plans that arrive from other apps: the share sheet, "Open with", and
/// `getonit://` links. MainActivity reads the content and sends it here.
class IncomingIntents {
  IncomingIntents._();

  static const _channel = MethodChannel('app.getonit/intents');
  static final _controller = StreamController<String>.broadcast();
  static bool _ready = false;

  /// Content received while the app was already running.
  static Stream<String> get stream {
    if (!_ready) {
      _ready = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onText' && call.arguments is String) _controller.add(call.arguments as String);
      });
    }
    return _controller.stream;
  }

  /// Content that started the app, if any.
  static Future<String?> initial() async {
    try {
      return await _channel.invokeMethod<String>('getInitialText');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';

import 'app/app.dart';
import 'features/widgets/home_widgets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Widget buttons that only write data run here, even when the app is closed.
  HomeWidget.registerInteractivityCallback(widgetBackgroundCallback);
  runApp(const ProviderScope(child: GetOnItApp()));
}

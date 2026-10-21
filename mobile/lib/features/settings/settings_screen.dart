import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/schema/capabilities.dart';

const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hour = ref.watch(dayClockProvider).dayStartHour;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('My day starts at'),
            subtitle: const Text('Work after midnight counts for the day before, until this hour.'),
            trailing: DropdownButton<int>(
              value: hour,
              items: [
                for (var h = 0; h <= 6; h++)
                  DropdownMenuItem(value: h, child: Text('${h.toString().padLeft(2, '0')}:00')),
              ],
              onChanged: (h) {
                if (h != null) ref.read(repositoryProvider).setSetting('dayStartHour', '$h');
              },
            ),
          ),
          const Divider(),
          ListTile(
            title: const Text('Capability manifest'),
            subtitle: const Text('Give this to Claude so that it makes plans this app can show.'),
            trailing: const Icon(Icons.copy),
            onTap: () {
              final json = const JsonEncoder.withIndent('  ').convert(Capabilities.manifest(appVersion));
              Clipboard.setData(ClipboardData(text: json));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
            },
          ),
          const ListTile(title: Text('Version'), subtitle: Text(appVersion)),
        ],
      ),
    );
  }
}

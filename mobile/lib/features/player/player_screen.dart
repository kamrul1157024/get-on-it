import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../actions/action_router.dart';
import '../../app/providers.dart';
import '../../core/events/goal_event.dart';
import '../../data/repository.dart';
import '../../render/components.dart';
import 'video_backend.dart';

/// Plays one video and records the position. Spec §7.8: every 15 seconds
/// of playback, on pause, and when the screen closes.
class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key, required this.goalId, required this.videoId, this.itemId, this.startSec = 0});

  final String goalId;
  final String? itemId;
  final String videoId;
  final int startSec;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  late final VideoBackend _backend;
  // Kept from initState: `ref` may not be used in dispose, where the last
  // position is saved.
  late final Repository _repo;
  late final DateTime Function() _clock;
  StreamSubscription<double>? _positions;
  StreamSubscription<void>? _stops;
  double _position = 0;
  double _lastSaved = -1;
  DateTime? _lastSavedAt;

  @override
  void initState() {
    super.initState();
    _repo = ref.read(repositoryProvider);
    _clock = ref.read(wallClockProvider);
    _position = widget.startSec.toDouble();
    _lastSaved = _position;
    _backend = ref.read(videoBackendProvider)(widget.videoId, widget.startSec);
    _positions = _backend.positions.listen((sec) {
      _position = sec;
      final last = _lastSavedAt;
      if (last == null || _clock().difference(last).inSeconds >= 15) _save();
    });
    _stops = _backend.stops.listen((_) => _save());
  }

  void _save() {
    final item = widget.itemId;
    if (item == null || (_position - _lastSaved).abs() < 1) return;
    _lastSaved = _position;
    _lastSavedAt = _clock();
    _repo.addEvent(widget.goalId, EventType.itemPosition, {'item': item, 'sec': _position.round()});
  }

  @override
  void dispose() {
    _save();
    _positions?.cancel();
    _stops?.cancel();
    _backend.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(goalViewProvider(widget.goalId));
    final item = (view?.state['items'] as List? ?? const [])
        .whereType<Map>()
        .where((i) => i['id'] == widget.itemId)
        .firstOrNull;
    return withAccent(
      context,
      view?.goal.accent,
      Scaffold(
        appBar: AppBar(title: Text(item?['title'] as String? ?? view?.goal.title ?? 'Video')),
        body: ListView(
          children: [
            _backend.build(context),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (item != null) ...[
                    Text(item['sub'] as String? ?? '', style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          key: const ValueKey('player-mark-done'),
                          onPressed: widget.itemId == null || item?['done'] == true
                              ? null
                              : () => _repo.addEvent(widget.goalId, EventType.itemDone, {
                                  'item': widget.itemId,
                                  'done': true,
                                }),
                          icon: const Icon(Icons.check),
                          label: Text(item?['done'] == true ? 'Done' : 'Mark done'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        key: const ValueKey('player-youtube'),
                        onPressed: () => ref.read(externalLauncherProvider)(
                          Uri.parse('https://www.youtube.com/watch?v=${widget.videoId}&t=${_position.round()}s'),
                        ),
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('YouTube'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

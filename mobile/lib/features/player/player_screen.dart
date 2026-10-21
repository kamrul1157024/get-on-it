import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../../app/providers.dart';
import '../../core/events/goal_event.dart';
import '../../render/components.dart';

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
  late final YoutubePlayerController _controller;
  StreamSubscription<YoutubeVideoState>? _positions;
  StreamSubscription<YoutubePlayerValue>? _states;
  double _position = 0;
  double _lastSaved = -1;
  DateTime _lastSavedAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _position = widget.startSec.toDouble();
    _controller = YoutubePlayerController.fromVideoId(
      videoId: widget.videoId,
      autoPlay: true,
      startSeconds: widget.startSec.toDouble(),
      params: const YoutubePlayerParams(showFullscreenButton: true, strictRelatedVideos: true),
    );
    _positions = _controller.videoStateStream.listen((s) {
      _position = s.position.inMilliseconds / 1000;
      if (DateTime.now().difference(_lastSavedAt).inSeconds >= 15) _save();
    });
    _states = _controller.stream.listen((v) {
      if (v.playerState == PlayerState.paused || v.playerState == PlayerState.ended) _save();
    });
  }

  void _save() {
    final item = widget.itemId;
    if (item == null || (_position - _lastSaved).abs() < 1) return;
    _lastSaved = _position;
    _lastSavedAt = DateTime.now();
    ref.read(repositoryProvider).addEvent(widget.goalId, EventType.itemPosition, {
      'item': item,
      'sec': _position.round(),
    });
  }

  @override
  void dispose() {
    _save();
    _positions?.cancel();
    _states?.cancel();
    _controller.close();
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
            YoutubePlayer(controller: _controller, aspectRatio: 16 / 9),
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
                          onPressed: widget.itemId == null || item?['done'] == true
                              ? null
                              : () {
                                  ref.read(repositoryProvider).addEvent(widget.goalId, EventType.itemDone, {
                                    'item': widget.itemId,
                                    'done': true,
                                  });
                                },
                          icon: const Icon(Icons.check),
                          label: Text(item?['done'] == true ? 'Done' : 'Mark done'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: () => launchUrl(
                          Uri.parse('https://www.youtube.com/watch?v=${widget.videoId}&t=${_position.round()}s'),
                          mode: LaunchMode.externalApplication,
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

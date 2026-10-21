import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

/// What the player screen needs from a video player: a widget, the playback
/// position, and the moments playback stops. Tests swap in a fake, because the
/// real one needs YouTube over the network.
abstract class VideoBackend {
  Widget build(BuildContext context);

  /// Playback position in seconds.
  Stream<double> get positions;

  /// Fires when playback pauses or ends.
  Stream<void> get stops;

  void dispose();
}

final videoBackendProvider = Provider<VideoBackend Function(String videoId, int startSec)>(
  (ref) =>
      (videoId, startSec) => YoutubeBackend(videoId, startSec),
);

class YoutubeBackend implements VideoBackend {
  YoutubeBackend(String videoId, int startSec)
    : _controller = YoutubePlayerController(
        key: videoId,
        params: const YoutubePlayerParams(showFullscreenButton: true, strictRelatedVideos: true),
      ) {
    // Not `fromVideoId`: it starts this call without waiting for it, and when
    // the player never becomes ready (no network, or the screen closed first)
    // its timeout escapes as an uncaught error. The YouTube button on the
    // player screen still works then.
    _controller.loadVideoById(videoId: videoId, startSeconds: startSec.toDouble()).catchError((Object e) {
      debugPrint('YouTube player did not load $videoId: $e');
    });
  }

  final YoutubePlayerController _controller;

  @override
  Widget build(BuildContext context) => YoutubePlayer(controller: _controller, aspectRatio: 16 / 9);

  @override
  Stream<double> get positions => _controller.videoStateStream.map((s) => s.position.inMilliseconds / 1000);

  @override
  Stream<void> get stops => _controller.stream
      .where((v) => v.playerState == PlayerState.paused || v.playerState == PlayerState.ended)
      .map((_) {});

  @override
  void dispose() => _controller.close();
}

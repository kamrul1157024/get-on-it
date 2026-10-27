import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../app/providers.dart';

/// The how-to video, on the project's web page (docs/howto/ in the repo).
/// Streamed, so the app does not carry it. Captions are in the picture, so
/// it works without sound.
final howToVideoUrlProvider = Provider<Uri>(
  (ref) => Uri.parse('https://kamrul1157024.github.io/get-on-it/howto/ai-plan.mp4'),
);

final videoControllerFactoryProvider = Provider<VideoPlayerController Function(Uri url)>(
  (ref) =>
      (url) => VideoPlayerController.networkUrl(url),
);

/// Off in tests, where the video would cover every flow that opens the AI
/// screen.
final howToAutoShowProvider = Provider<bool>((ref) => true);

const _shownKey = 'howto.autoShown';

/// The first time the user opens "Make a plan with AI", the video plays once
/// on its own. "Watch how" plays it again at any time.
Future<void> showHowToOnce(BuildContext context, WidgetRef ref) async {
  if (!ref.read(howToAutoShowProvider)) return;
  final repo = ref.read(repositoryProvider);
  if ((await repo.settings())[_shownKey] == 'true') return;
  await repo.setSetting(_shownKey, 'true');
  if (!context.mounted) return;
  await Navigator.of(context)
      .push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const HowToVideoScreen(firstRun: true)));
}

/// The three steps, in words: shown under the video and when it cannot play.
const aiPlanSteps = [
  ('Say what you want', 'Type your goal, or tap an idea.'),
  ('Ask your AI', 'Tap Open ChatGPT or Open Claude. The prompt is copied. Paste it with a long press, then send it.'),
  (
    'Bring the plan back',
    'When the answer is ready, tap Copy under it, or Share → Get On It. Come back here. '
        'Get On It finds the plan and shows it. Tap Import.',
  ),
];

class AiPlanStepsText extends StatelessWidget {
  const AiPlanStepsText({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < aiPlanSteps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(radius: 12, child: Text('${i + 1}', style: t.labelMedium)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(aiPlanSteps[i].$1, style: t.titleSmall),
                      Text(aiPlanSteps[i].$2, style: t.bodyMedium),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Plays the how-to video. Without internet, or if it fails, the steps in
/// words take its place.
class HowToVideoScreen extends ConsumerStatefulWidget {
  const HowToVideoScreen({super.key, this.firstRun = false});

  /// Shown on its own the first time: "Skip" and "Got it" close it.
  final bool firstRun;

  @override
  ConsumerState<HowToVideoScreen> createState() => _HowToVideoScreenState();
}

class _HowToVideoScreenState extends ConsumerState<HowToVideoScreen> {
  VideoPlayerController? _controller;
  bool _failed = false;
  bool _muted = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final c = ref.read(videoControllerFactoryProvider)(ref.read(howToVideoUrlProvider));
      _controller = c;
      await c.initialize().timeout(const Duration(seconds: 20));
      if (!mounted) return;
      await c.play();
      setState(() {});
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final ready = !_failed && c != null && c.value.isInitialized;
    return Scaffold(
      appBar: AppBar(
        title: const Text('How it works'),
        actions: [
          if (ready)
            IconButton(
              key: const ValueKey('howto-mute'),
              tooltip: _muted ? 'Sound on' : 'Mute',
              onPressed: () {
                setState(() => _muted = !_muted);
                c.setVolume(_muted ? 0 : 1);
              },
              icon: Icon(_muted ? Icons.volume_off : Icons.volume_up),
            ),
          if (widget.firstRun)
            TextButton(
              key: const ValueKey('howto-skip'),
              onPressed: () => Navigator.pop(context),
              child: const Text('Skip'),
            ),
        ],
      ),
      bottomNavigationBar: widget.firstRun
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                  key: const ValueKey('howto-got-it'),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Got it'),
                ),
              ),
            )
          : null,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_failed)
            Card.filled(
              key: const ValueKey('howto-fallback'),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('The video cannot play now, for example without internet. Here are the same steps.'),
              ),
            )
          else if (!ready)
            const AspectRatio(
              aspectRatio: 9 / 16,
              child: Center(child: CircularProgressIndicator()),
            )
          else
            GestureDetector(
              key: const ValueKey('howto-video'),
              onTap: () => setState(() => c.value.isPlaying ? c.pause() : c.play()),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)),
              ),
            ),
          if (ready) ...[const SizedBox(height: 8), VideoProgressIndicator(c, allowScrubbing: true)],
          const SizedBox(height: 16),
          const AiPlanStepsText(),
        ],
      ),
    );
  }
}

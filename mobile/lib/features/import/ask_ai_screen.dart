import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../actions/action_router.dart';
import '../../app/providers.dart';
import 'import_screen.dart';

/// Fills the copy-paste prompt (assets/prompt/plan_prompt.md). Pure, so a
/// test can check that its examples still pass the app's validator.
String fillPlanPrompt({
  required String template,
  required String example,
  required String request,
  required DateTime today,
}) => template
    .replaceAll('{{today}}', DateFormat('yyyy-MM-dd (EEEE)').format(today))
    .replaceAll('{{request}}', request.trim().isEmpty ? 'Help me pick one goal and make a plan.' : request.trim())
    .replaceAll('{{example}}', example.trim());

/// Fills the change prompt (assets/prompt/edit_prompt.md) for one goal.
String fillEditPrompt({
  required String template,
  required GoalView view,
  required String request,
  required DateTime today,
}) => template
    .replaceAll('{{today}}', DateFormat('yyyy-MM-dd (EEEE)').format(today))
    .replaceAll(
      '{{request}}',
      request.trim().isEmpty ? 'Look at my progress and suggest a better plan.' : request.trim(),
    )
    .replaceAll('{{goal}}', const JsonEncoder.withIndent('  ').convert(view.goal.json))
    .replaceAll('{{progress}}', progressSummary(view));

/// A few lines the AI needs to change a plan well: where the user is, the
/// pace, and which items are already done (their ids must stay).
String progressSummary(GoalView view) {
  final s = view.state;
  final pace = (s['pace'] as Map?)?['label'] as String?;
  final lines = <String>[
    '- Progress: ${s['progressLabel'] ?? ''} (${s['pctLabel'] ?? ''})',
    if (pace != null && pace.isNotEmpty) '- Pace: $pace',
    '- Streak: ${s['streakLabel'] ?? '0 days'}',
    '- Today done: ${s['todayComplete'] == true ? 'yes' : 'no'}',
  ];
  final done = [
    for (final i in [...(s['items'] as List? ?? const []), ...(s['steps'] as List? ?? const [])].whereType<Map>())
      if (i['done'] == true) i['id'],
  ];
  if (done.isNotEmpty) lines.add('- Done item ids: ${done.join(', ')}');
  final next = (s['next'] as Map?)?['title'];
  if (next != null) lines.add('- Next item: $next');
  final lastPage = s['lastPage'];
  if (lastPage != null) lines.add('- Last page read: $lastPage');
  return lines.join('\n');
}

Future<String> buildPlanPrompt(String request, DateTime today) async => fillPlanPrompt(
  template: await rootBundle.loadString('assets/prompt/plan_prompt.md'),
  example: await rootBundle.loadString('assets/samples/book-atomic-habits.getonit.json'),
  request: request,
  today: today,
);

/// Make or change a plan without installing anything: describe the goal or
/// the change, copy the prompt into Claude or ChatGPT, paste the answer back.
/// With [goalId], the prompt is for changing that goal.
class AskAiScreen extends ConsumerStatefulWidget {
  const AskAiScreen({super.key, this.goalId});

  final String? goalId;

  @override
  ConsumerState<AskAiScreen> createState() => _AskAiScreenState();
}

class _AskAiScreenState extends ConsumerState<AskAiScreen> {
  final _request = TextEditingController();

  static const _editIdeas = [
    'I am behind. Make a new pace so I still finish on time',
    'Move the deadline two weeks later',
    'Only 2 days a week from now on',
    'Make the reminders stronger',
  ];

  static const _ideas = [
    'Finish the Stanford CS229 lectures on YouTube by 31 December, 3 days a week',
    'Read Atomic Habits (320 pages) by the end of next month',
    'Drink 8 glasses of water a day',
    'A morning routine: stretch, journal, plan the day',
  ];

  @override
  void dispose() {
    _request.dispose();
    super.dispose();
  }

  Future<void> _copy({Uri? open}) async {
    final today = ref.read(wallClockProvider)();
    final view = widget.goalId == null ? null : ref.read(goalViewProvider(widget.goalId!));
    final prompt = view == null
        ? await buildPlanPrompt(_request.text, today)
        : fillEditPrompt(
            template: await rootBundle.loadString('assets/prompt/edit_prompt.md'),
            view: view,
            request: _request.text,
            today: today,
          );
    await Clipboard.setData(ClipboardData(text: prompt));
    if (!mounted) return;
    // Replace, not queue: several taps would otherwise stack messages.
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Prompt copied. Paste it into Claude or ChatGPT.')));
    if (open != null) await ref.read(externalLauncherProvider)(open);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final editing = widget.goalId != null;
    final title = editing ? ref.watch(goalViewProvider(widget.goalId!))?.goal.title : null;
    return Scaffold(
      appBar: AppBar(title: Text(editing ? 'Change this plan with AI' : 'Make a plan with AI')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null) ...[Text(title, style: t.titleLarge), const SizedBox(height: 12)],
            Text(editing ? '1. Say what should change.' : '1. Say what you want to do.', style: t.titleMedium),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('ask-request'),
              controller: _request,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: editing
                    ? 'For example: I missed a week. Give me a new pace.'
                    : 'For example: read 2 pages of a book every day',
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final idea in editing ? _editIdeas : _ideas)
                  ActionChip(label: Text(idea, maxLines: 1), onPressed: () => setState(() => _request.text = idea)),
              ],
            ),
            const SizedBox(height: 24),
            Text('2. Copy the prompt into an AI chat.', style: t.titleMedium),
            const SizedBox(height: 4),
            Text(
              editing ? 'The prompt holds your current plan and progress, and asks the AI to keep your progress.' : 'The prompt tells the AI exactly what Get On It can import. It works with Claude, ChatGPT and other chat apps.',
              style: t.bodySmall,
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const ValueKey('ask-copy'),
              onPressed: _copy,
              icon: const Icon(Icons.copy),
              label: const Text('Copy prompt'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('ask-claude'),
                    onPressed: () => _copy(open: Uri.parse('https://claude.ai/new')),
                    child: const Text('Copy and open Claude'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('ask-chatgpt'),
                    onPressed: () => _copy(open: Uri.parse('https://chatgpt.com/')),
                    child: const Text('Copy and open ChatGPT'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text('3. Copy the whole answer and import it.', style: t.titleMedium),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              key: const ValueKey('ask-import'),
              onPressed: () =>
                  Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const ImportScreen())),
              icon: const Icon(Icons.content_paste),
              label: Text(editing ? 'I have the answer: update the plan' : 'I have the answer: import it'),
            ),
          ],
        ),
      ),
    );
  }
}

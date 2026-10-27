import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../actions/action_router.dart';
import '../../app/providers.dart';
import 'howto_video.dart';
import 'direct_import.dart';
import 'import_screen.dart';
import 'plan_finder.dart';

/// Fills the copy-paste prompt (assets/prompt/plan_prompt.md). Pure, so a
/// test can check that its examples still pass the app's validator.
String fillPlanPrompt({
  required String template,
  required String example,
  required String customExample,
  required String uiReference,
  required String request,
  required DateTime today,
}) => template
    .replaceAll('{{uiReference}}', uiReference.trim())
    .replaceAll('{{customExample}}', customExample.trim())
    .replaceAll('{{example}}', example.trim())
    .replaceAll('{{today}}', DateFormat('yyyy-MM-dd (EEEE)').format(today))
    .replaceAll('{{request}}', request.trim().isEmpty ? 'Help me pick one goal and make a plan.' : request.trim());

/// Fills the change prompt (assets/prompt/edit_prompt.md) for one goal.
String fillEditPrompt({
  required String template,
  required String uiReference,
  required GoalView view,
  required String request,
  required DateTime today,
}) => template
    .replaceAll('{{uiReference}}', uiReference.trim())
    .replaceAll('{{currentTemplate}}', const JsonEncoder.withIndent('  ').convert(view.template?.json ?? const {}))
    .replaceAll('{{goal}}', const JsonEncoder.withIndent('  ').convert(view.goal.json))
    .replaceAll('{{progress}}', progressSummary(view))
    .replaceAll('{{today}}', DateFormat('yyyy-MM-dd (EEEE)').format(today))
    .replaceAll(
      '{{request}}',
      request.trim().isEmpty ? 'Look at my progress and suggest a better plan.' : request.trim(),
    );

/// Fills the look prompt (assets/prompt/look_prompt.md): a new screen and
/// widgets for one goal, with the plan left as it is.
String fillLookPrompt({
  required String template,
  required String uiReference,
  required GoalView view,
  required String request,
  required DateTime today,
}) => template
    .replaceAll('{{uiReference}}', uiReference.trim())
    .replaceAll('{{currentTemplate}}', const JsonEncoder.withIndent('  ').convert(view.template?.json ?? const {}))
    .replaceAll('{{goal}}', const JsonEncoder.withIndent('  ').convert(view.goal.json))
    .replaceAll('{{today}}', DateFormat('yyyy-MM-dd (EEEE)').format(today))
    .replaceAll(
      '{{request}}',
      request.trim().isEmpty ? 'Make the screen and both widgets clearer and more motivating.' : request.trim(),
    );

/// Fills the fix prompt (assets/prompt/fix_prompt.md): the problems the app
/// found and the answer that has them.
String fillFixPrompt({
  required String template,
  required String uiReference,
  required List<String> problems,
  required String answer,
  required DateTime today,
}) => template
    .replaceAll('{{uiReference}}', uiReference.trim())
    .replaceAll('{{problems}}', [for (final p in problems) '- $p'].join('\n'))
    .replaceAll('{{today}}', DateFormat('yyyy-MM-dd (EEEE)').format(today))
    .replaceAll('{{answer}}', answer.trim());

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
  customExample: await rootBundle.loadString('assets/prompt/custom_example.json'),
  uiReference: await rootBundle.loadString('assets/prompt/ui_reference.md'),
  request: request,
  today: today,
);

/// Make or change a plan without installing anything: describe the goal or
/// the change, copy the prompt into Claude or ChatGPT, paste the answer back.
/// With [goalId], the prompt is for changing that goal; with [look] too, for
/// changing only how it looks.
class AskAiScreen extends ConsumerStatefulWidget {
  const AskAiScreen({super.key, this.goalId, this.look = false});

  final String? goalId;
  final bool look;

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

  static const _lookIdeas = [
    'A big progress ring and one big button on the small widget',
    'Show my streak and the week on the medium widget',
    'Add a section with useful links and tips',
    'A calmer screen: fewer stats, today first',
  ];

  static const _ideas = [
    'Finish the Stanford CS229 lectures on YouTube by 31 December, 3 days a week',
    'Read Atomic Habits (320 pages) by the end of next month',
    'Drink 8 glasses of water a day',
    'Exercise 4 days a week: push-ups, squats, plank and a run on different days',
    'Exercise, read Atomic Habits, and drink 8 glasses of water',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showHowToOnce(context, ref);
    });
  }

  @override
  void dispose() {
    _request.dispose();
    super.dispose();
  }

  Future<void> _copy({Uri? open}) async {
    final today = ref.read(wallClockProvider)();
    final view = widget.goalId == null ? null : ref.read(goalViewProvider(widget.goalId!));
    final uiReference = await rootBundle.loadString('assets/prompt/ui_reference.md');
    final prompt = view == null
        ? await buildPlanPrompt(_request.text, today)
        : widget.look
        ? fillLookPrompt(
            template: await rootBundle.loadString('assets/prompt/look_prompt.md'),
            uiReference: uiReference,
            view: view,
            request: _request.text,
            today: today,
          )
        : fillEditPrompt(
            template: await rootBundle.loadString('assets/prompt/edit_prompt.md'),
            uiReference: uiReference,
            view: view,
            request: _request.text,
            today: today,
          );
    await Clipboard.setData(ClipboardData(text: prompt));
    // When the user comes back with the answer, the app looks for it.
    await armPlanFinder(ref, prompt);
    if (!mounted) return;
    // Replace, not queue: several taps would otherwise stack messages.
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Prompt copied. Paste it with a long press, then send it.')));
    if (open != null) await ref.read(aiChatLauncherProvider)(open);
  }

  /// "I copied the answer": the plan from the clipboard goes straight to the
  /// preview; without one, the import screen opens for a paste by hand.
  Future<void> _bringBack() async {
    final plan = await copiedPlan(ref);
    if (!mounted) return;
    if (plan != null) return importOrReview(context, ref, plan.text);
    await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const ImportScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final editing = widget.goalId != null;
    final title = editing ? ref.watch(goalViewProvider(widget.goalId!))?.goal.title : null;
    Widget step(int n, String heading, List<Widget> body) => Card.outlined(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(radius: 14, child: Text('$n')),
                const SizedBox(width: 12),
                Expanded(child: Text(heading, style: t.titleMedium)),
              ],
            ),
            const SizedBox(height: 12),
            ...body,
          ],
        ),
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.look ? 'Change the look with AI' : (editing ? 'Change this plan with AI' : 'Make a plan with AI'),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null) ...[Text(title, style: t.titleLarge), const SizedBox(height: 8)],
            Text(
              'Your AI chat makes the plan. Get On It shows it and keeps you on track. It takes 3 steps.',
              style: t.bodyMedium,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('ask-howto'),
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HowToVideoScreen())),
                icon: const Icon(Icons.play_circle_outline),
                label: const Text('Watch how (1 min)'),
              ),
            ),
            const SizedBox(height: 4),
            step(
              1,
              widget.look ? 'Say how it should look' : (editing ? 'Say what should change' : 'Say what you want'),
              [
                TextField(
                  key: const ValueKey('ask-request'),
                  controller: _request,
                  minLines: 2,
                  maxLines: 5,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText: widget.look
                        ? 'For example: a quick +1 button on the small widget'
                        : editing
                        ? 'For example: I missed a week. Give me a new pace.'
                        : 'For example: read 2 pages of a book every day',
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final idea in widget.look ? _lookIdeas : (editing ? _editIdeas : _ideas))
                      ActionChip(label: Text(idea, maxLines: 1), onPressed: () => setState(() => _request.text = idea)),
                  ],
                ),
              ],
            ),
            step(2, 'Ask your AI', [
              Text(
                widget.look
                    ? 'The app copies a prompt with your plan and its design. The AI changes only the design.'
                    : editing
                    ? 'The app copies a prompt with your plan and progress. The AI keeps your progress.'
                    : 'The app copies a prompt that tells the AI what Get On It needs.',
                style: t.bodySmall,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const ValueKey('ask-chatgpt'),
                onPressed: () => _copy(open: Uri.parse('https://chatgpt.com/')),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open ChatGPT'),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const ValueKey('ask-claude'),
                onPressed: () => _copy(open: Uri.parse('https://claude.ai/new')),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open Claude'),
              ),
              const SizedBox(height: 8),
              Text('In the chat, paste the prompt with a long press, then send it.', style: t.bodyMedium),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('ask-copy'),
                  onPressed: _copy,
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy prompt only, for another AI chat'),
                ),
              ),
            ]),
            step(3, 'Bring the plan back', [
              Text(
                'When the answer is ready, tap Copy under the answer, or Share → Get On It. Then come back here.',
                style: t.bodyMedium,
              ),
              const SizedBox(height: 4),
              Text('Copy the whole answer. Get On It finds the plan in it and shows it to you.', style: t.bodySmall),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                key: const ValueKey('ask-import'),
                onPressed: _bringBack,
                icon: const Icon(Icons.content_paste),
                label: Text(
                  widget.look ? 'I copied the answer: show the new look' : 'I copied the answer: show the plan',
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

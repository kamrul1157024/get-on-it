import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/events/goal_event.dart';
import '../../core/schema/documents.dart';
import '../../core/schema/validator.dart';
import '../../actions/action_router.dart';
import '../../data/repository.dart';
import '../../render/components.dart';
import '../../render/surface_preview.dart';
import '../../render/template_lint.dart';
import '../reminders/reminder_labels.dart';
import 'ask_ai_screen.dart';
import '../reminders/reminders_controller.dart';

/// Paste or receive a plan, check it, preview it, and save it. Spec §14.
class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key, this.initialText});

  final String? initialText;

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _GoalPreview {
  _GoalPreview(this.goal, this.template, this.summary, this.diff, this.scope, this.warnings);

  final GoalDoc goal;
  final TemplateDoc? template;
  final String summary;
  final GoalDiff diff;
  final Map<String, Object?> scope;
  final List<ValidationIssue> warnings;
}

const _surfaceNames = {'screen': 'goal screen', 'tile': 'small widget', 'tile_wide': 'medium widget'};

class _ImportScreenState extends ConsumerState<ImportScreen> {
  late final _text = TextEditingController(text: widget.initialText ?? '');
  ParsedImport? _parsed;
  List<_GoalPreview> _previews = const [];
  bool _saving = false;

  /// Reminders the user turned on in the preview. Off unless the user says
  /// so: an imported plan only proposes reminders. Spec §11.5.
  final _remindersOn = <String, bool>{};

  /// Surfaces that failed to lay out in the preview, as "goalId/surface".
  final _broken = <String>{};

  @override
  void initState() {
    super.initState();
    if (widget.initialText != null) WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text == null) return;
    _text.text = data!.text!;
    await _check();
  }

  Future<void> _check() async {
    final repo = ref.read(repositoryProvider);
    final installed = await repo.templates();
    final parsed = parseImport(_text.text, (ref) => installed[ref]);
    final previews = <_GoalPreview>[];
    final settings = await repo.settings();
    final clock = ref.read(dayClockProvider);
    final now = ref.read(wallClockProvider)();
    final events = parsed.goals.isEmpty ? const <GoalEvent>[] : await repo.allEvents();
    for (final g in parsed.goals) {
      // An update shows the reminders as they are now.
      _remindersOn.putIfAbsent(g.id, () => settings[reminderSettingKey(g.id)] == 'true');
      final template = parsed.templates.where((t) => t.ref == g.templateRef).firstOrNull ?? installed[g.templateRef];
      final engine = template == null ? null : engineRegistry.forGoal(template, g);
      final existing = await repo.goal(g.id);
      // An update previews with the progress the goal already has.
      final state = template == null
          ? const <String, Object?>{}
          : previewState(
              template,
              g,
              clock: clock,
              now: now,
              events: existing == null ? const [] : events.where((e) => e.goalId == g.id).toList(),
              createdAt: existing?.createdAt,
              files: existing == null ? const {} : await repo.linkedFiles(g.id),
            );
      previews.add(
        _GoalPreview(g, template, engine?.summary(g) ?? '', diffGoals(existing?.doc, g), {
          'goal': g.scopeValue,
          'data': g.data,
          'state': state,
        }, template == null ? const [] : lintTemplate(template, g, state)),
      );
    }
    setState(() {
      _parsed = parsed;
      _previews = previews;
      _broken.clear();
    });
  }

  void _layout(String goalId, String surface, bool ok) {
    final key = '$goalId/$surface';
    if (ok == !_broken.contains(key)) return;
    setState(() => ok ? _broken.remove(key) : _broken.add(key));
  }

  /// Everything the AI should fix, one line each.
  List<String> get _problems => [
    ...?_parsed?.issues.map((i) => i.toString()),
    for (final p in _previews) ...p.warnings.map((w) => '${p.goal.templateRef}: $w'),
    for (final b in _broken)
      '${b.split('/').last}: the ${_surfaceNames[b.split('/').last]} failed to lay out. A part that fills the '
          'width or height probably sits where the space is endless, for example a full-width part in a row or a '
          'heatmap in a grid.',
  ];

  Future<void> _save() async {
    final parsed = _parsed;
    if (parsed == null || !parsed.ok || _broken.isNotEmpty) return;
    setState(() => _saving = true);
    final repo = ref.read(repositoryProvider);
    for (final t in parsed.templates) {
      await repo.installTemplate(t);
    }
    for (final g in parsed.goals) {
      await repo.saveGoal(g);
      if (g.reminders != null) {
        await repo.setSetting(reminderSettingKey(g.id), _remindersOn[g.id] == true ? 'true' : 'false');
      }
    }
    ref.read(remindersProvider.notifier).scheduleSync();
    if (!mounted) return;
    final n = parsed.goals.length;
    final message = n > 0
        ? 'Imported $n ${n == 1 ? 'goal' : 'goals'}'
        : 'Installed ${parsed.templates.length} ${parsed.templates.length == 1 ? 'template' : 'templates'}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    // Back to Today, also when a shared plan opened a second import screen
    // on top of one that was already open.
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final parsed = _parsed;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Import a plan')),
      // Not a lazy list: the screen is short, and the confirm button must
      // exist even when it is below the fold.
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Paste the plan that Claude or ChatGPT made for you.', style: t.bodyMedium),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('import-ask'),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AskAiScreen())),
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('No plan yet? Make one with AI'),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('import-text'),
              controller: _text,
              minLines: 6,
              maxLines: 12,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: '{ "kind": "goal", ... }'),
              onChanged: (_) => setState(() => _parsed = null),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _paste,
                  icon: const Icon(Icons.content_paste),
                  label: const Text('Paste'),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  key: const ValueKey('import-check'),
                  onPressed: _check,
                  child: const Text('Check plan'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (parsed != null && parsed.errors.isNotEmpty) ...[
              _Errors(parsed.issues),
              _FixWithAi(problems: _problems, answer: _text.text),
            ],
            if (parsed != null && parsed.ok) ...[
              for (final w in parsed.issues.where((i) => i.warning))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('⚠ $w', style: t.bodySmall),
                ),
              for (final tpl in parsed.templates)
                Card.outlined(
                  child: ListTile(
                    leading: const Icon(Icons.dashboard_customize_outlined),
                    title: Text('New design: ${tpl.title}'),
                    subtitle: Text('How the goal screen and widgets look · version ${tpl.version}'),
                  ),
                ),
              for (final p in _previews)
                _PreviewCard(
                  p,
                  remindersOn: _remindersOn[p.goal.id] ?? false,
                  onReminders: (v) => setState(() => _remindersOn[p.goal.id] = v),
                  broken: {
                    for (final b in _broken)
                      if (b.startsWith('${p.goal.id}/')) b.split('/').last,
                  },
                  onLayout: (surface, ok) => _layout(p.goal.id, surface, ok),
                ),
              if (_problems.isNotEmpty)
                _FixWithAi(problems: _problems, answer: _text.text, blocking: _broken.isNotEmpty),
              const SizedBox(height: 12),
              FilledButton(
                key: const ValueKey('import-confirm'),
                onPressed: _saving || _broken.isNotEmpty ? null : _save,
                child: Text(_previews.any((p) => !p.diff.isNew) ? 'Update' : 'Import'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Errors extends StatelessWidget {
  const _Errors(this.issues);

  final List<ValidationIssue> issues;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = issues.map((i) => i.toString()).join('\n');
    return Card.filled(
      key: const ValueKey('import-errors'),
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This plan has problems',
              style: TextStyle(color: scheme.onErrorContainer, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'The details below are for the AI. Use "Fix with AI" to send them back to it.',
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 12),
            ),
            const SizedBox(height: 8),
            SelectableText(
              text,
              style: TextStyle(color: scheme.onErrorContainer, fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard(
    this.p, {
    required this.remindersOn,
    required this.onReminders,
    required this.broken,
    required this.onLayout,
  });

  final _GoalPreview p;
  final bool remindersOn;
  final ValueChanged<bool> onReminders;
  final Set<String> broken;
  final void Function(String surface, bool ok) onLayout;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final reminders = p.goal.reminders;
    return Card(
      key: ValueKey('preview:${p.goal.id}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${p.goal.icon ?? '🎯'}  ${p.goal.title}', style: t.titleMedium),
            const SizedBox(height: 4),
            Text(p.template?.title ?? p.goal.templateRef, style: t.labelMedium),
            if (p.summary.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(p.summary, key: const ValueKey('preview-summary')),
            ],
            const SizedBox(height: 8),
            Text(p.diff.describe(), key: const ValueKey('preview-diff'), style: t.bodySmall),
            for (final a in p.diff.added) Text('+ $a', style: t.bodySmall),
            for (final r in p.diff.removed) Text('− $r', style: t.bodySmall),
            for (final r in p.diff.renamed) Text('✎ $r', style: t.bodySmall),
            if (p.template != null) ...[
              const SizedBox(height: 12),
              _SurfaceTabs(p, broken: broken, onLayout: onLayout),
            ],
            if (p.warnings.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Notes for the AI. The plan still works; some text may show empty.', style: t.labelMedium),
              ),
            for (final w in p.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('⚠ $w', style: t.bodySmall),
              ),
            if (reminders != null) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                key: ValueKey('import-reminders:${p.goal.id}'),
                contentPadding: EdgeInsets.zero,
                value: remindersOn,
                onChanged: onReminders,
                title: const Text('Turn on the reminders in this plan'),
                subtitle: Text(
                  ladderDescription(p.goal, use24h: MediaQuery.alwaysUse24HourFormatOf(context)),
                  style: t.bodySmall,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The goal screen and both home-screen widgets, drawn from the plan before
/// it is saved. All three are laid out (the hidden ones offstage), so a
/// layout failure shows on whichever tab is open.
class _SurfaceTabs extends StatefulWidget {
  const _SurfaceTabs(this.p, {required this.broken, required this.onLayout});

  final _GoalPreview p;
  final Set<String> broken;
  final void Function(String surface, bool ok) onLayout;

  @override
  State<_SurfaceTabs> createState() => _SurfaceTabsState();
}

class _SurfaceTabsState extends State<_SurfaceTabs> {
  String _shown = 'screen';

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    final scheme = Theme.of(context).colorScheme;
    final surfaces = [
      for (final s in _surfaceNames.keys)
        if (p.template!.surface(s) != null) s,
    ];
    Future<void> tapped(Map<String, Object?> _) async {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('This is a preview. Buttons work after the import.')));
    }

    Widget frame(String s) {
      final preview = SurfacePreview(
        key: ValueKey('surface-preview:${p.goal.id}:$s'),
        tree: p.template!.surface(s)!,
        scope: p.scope,
        onAction: tapped,
        onLayout: (ok) => widget.onLayout(s, ok),
      );
      // Drawn at the width it gets on the phone, then scaled down to fit:
      // a narrower layout would wrap text that the real screen does not.
      final full = MediaQuery.sizeOf(context).width - 32;
      final Widget box = switch (s) {
        'screen' => SizedBox(
          height: 420,
          child: SingleChildScrollView(padding: const EdgeInsets.all(12), child: _AtWidth(full, preview)),
        ),
        'tile' => Center(child: SizedBox(width: 170, child: preview)),
        _ => _AtWidth(full, preview),
      };
      return Offstage(
        offstage: s != _shown,
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: widget.broken.contains(s) ? scheme.error : scheme.outlineVariant),
          ),
          padding: s == 'screen' ? EdgeInsets.zero : const EdgeInsets.all(12),
          child: withAccent(context, p.goal.accent, box),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<String>(
          key: ValueKey('surface-tabs:${p.goal.id}'),
          showSelectedIcon: false,
          segments: [
            for (final s in surfaces)
              ButtonSegment(
                value: s,
                label: Text(switch (s) {
                  'screen' => 'Screen',
                  'tile' => 'Small',
                  _ => 'Medium',
                }),
                icon: widget.broken.contains(s) ? Icon(Icons.error_outline, color: scheme.error) : null,
              ),
          ],
          selected: {_shown},
          onSelectionChanged: (v) => setState(() => _shown = v.first),
        ),
        const SizedBox(height: 8),
        for (final s in surfaces) frame(s),
        if (widget.broken.contains(_shown))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'The ${_surfaceNames[_shown]} failed to lay out. Ask the AI to fix it below.',
              key: ValueKey('surface-broken:${p.goal.id}:$_shown'),
              style: TextStyle(color: scheme.error),
            ),
          ),
        if (_shown != 'screen')
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Close to how the home-screen widget looks. The widget itself may differ a little.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

/// Lays [child] out at [width] and scales it down to the space there is.
class _AtWidth extends StatelessWidget {
  const _AtWidth(this.width, this.child);

  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => box.maxWidth >= width
        ? child
        : FittedBox(
            fit: BoxFit.fitWidth,
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
  );
}

/// Copies a prompt that asks the AI to fix what the app found, and can open
/// the AI chat. Spec §14.6.
class _FixWithAi extends ConsumerWidget {
  const _FixWithAi({required this.problems, required this.answer, this.blocking = true});

  final List<String> problems;
  final String answer;
  final bool blocking;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    Future<void> copy({Uri? open}) async {
      final prompt = fillFixPrompt(
        template: await rootBundle.loadString('assets/prompt/fix_prompt.md'),
        uiReference: await rootBundle.loadString('assets/prompt/ui_reference.md'),
        problems: problems,
        answer: answer,
        today: ref.read(wallClockProvider)(),
      );
      await Clipboard.setData(ClipboardData(text: prompt));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Fix prompt copied. Paste it into the same AI chat.')));
      if (open != null) await ref.read(externalLauncherProvider)(open);
    }

    return Card.outlined(
      key: const ValueKey('fix-with-ai'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(blocking ? 'Fix with AI' : 'Fix the warnings with AI (optional)', style: t.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Copy a prompt with the problems above, paste it into the AI chat, and import its new answer.',
              style: t.bodySmall,
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              key: const ValueKey('fix-copy'),
              onPressed: copy,
              icon: const Icon(Icons.auto_fix_high),
              label: const Text('Copy fix prompt'),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    key: const ValueKey('fix-claude'),
                    onPressed: () => copy(open: Uri.parse('https://claude.ai/new')),
                    child: const Text('Copy, open Claude'),
                  ),
                ),
                Expanded(
                  child: TextButton(
                    key: const ValueKey('fix-chatgpt'),
                    onPressed: () => copy(open: Uri.parse('https://chatgpt.com/')),
                    child: const Text('Copy, open ChatGPT'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

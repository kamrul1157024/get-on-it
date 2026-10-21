import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/schema/documents.dart';
import '../../core/schema/validator.dart';
import '../../data/repository.dart';
import '../reminders/planner.dart';
import '../reminders/reminders_controller.dart';

/// Paste or receive a plan, check it, preview it, and save it. Spec §14.
class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key, this.initialText});

  final String? initialText;

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _GoalPreview {
  _GoalPreview(this.goal, this.template, this.summary, this.diff);

  final GoalDoc goal;
  final TemplateDoc? template;
  final String summary;
  final GoalDiff diff;
}

class _ImportScreenState extends ConsumerState<ImportScreen> {
  late final _text = TextEditingController(text: widget.initialText ?? '');
  ParsedImport? _parsed;
  List<_GoalPreview> _previews = const [];
  bool _saving = false;

  /// Reminders the user turned on in the preview. Off unless the user says
  /// so: an imported plan only proposes reminders. Spec §11.5.
  final _remindersOn = <String, bool>{};

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
    for (final g in parsed.goals) {
      final template = parsed.templates.where((t) => t.ref == g.templateRef).firstOrNull ?? installed[g.templateRef];
      final engine = template == null ? null : engineRegistry.forGoal(template, g);
      final existing = await repo.goal(g.id);
      previews.add(_GoalPreview(g, template, engine?.summary(g) ?? '', diffGoals(existing?.doc, g)));
    }
    setState(() {
      _parsed = parsed;
      _previews = previews;
    });
  }

  Future<void> _save() async {
    final parsed = _parsed;
    if (parsed == null || !parsed.ok) return;
    setState(() => _saving = true);
    final repo = ref.read(repositoryProvider);
    for (final t in parsed.templates) {
      await repo.installTemplate(t);
    }
    for (final g in parsed.goals) {
      await repo.saveGoal(g);
      if (g.reminders != null && _remindersOn[g.id] == true) {
        await repo.setSetting(reminderSettingKey(g.id), 'true');
      }
    }
    ref.read(remindersProvider.notifier).scheduleSync();
    if (!mounted) return;
    final n = parsed.goals.length;
    final message = n > 0
        ? 'Imported $n ${n == 1 ? 'goal' : 'goals'}'
        : 'Installed ${parsed.templates.length} ${parsed.templates.length == 1 ? 'template' : 'templates'}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    Navigator.of(context).pop(true);
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
            Text('Paste the JSON that Claude made for you.', style: t.bodyMedium),
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
                FilledButton.tonal(key: const ValueKey('import-check'), onPressed: _check, child: const Text('Check')),
              ],
            ),
            const SizedBox(height: 16),
            if (parsed != null && parsed.errors.isNotEmpty) _Errors(parsed.issues),
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
                    title: Text('Template: ${tpl.title}'),
                    subtitle: Text('${tpl.ref} · version ${tpl.version}'),
                  ),
                ),
              for (final p in _previews)
                _PreviewCard(
                  p,
                  remindersOn: _remindersOn[p.goal.id] ?? false,
                  onReminders: (v) => setState(() => _remindersOn[p.goal.id] = v),
                ),
              const SizedBox(height: 12),
              FilledButton(
                key: const ValueKey('import-confirm'),
                onPressed: _saving ? null : _save,
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
            const SizedBox(height: 8),
            SelectableText(
              text,
              style: TextStyle(color: scheme.onErrorContainer, fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: text)),
              icon: const Icon(Icons.copy),
              label: const Text('Copy for Claude'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard(this.p, {required this.remindersOn, required this.onReminders});

  final _GoalPreview p;
  final bool remindersOn;
  final ValueChanged<bool> onReminders;

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
            if (reminders != null) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                key: ValueKey('import-reminders:${p.goal.id}'),
                contentPadding: EdgeInsets.zero,
                value: remindersOn,
                onChanged: onReminders,
                title: const Text('Turn on the proposed reminders'),
                subtitle: Text(
                  [for (final s in ladderOf(p.goal)) '${clockText(s.minuteOfDay)} ${_levelName(s.level)}'].join(' → '),
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

String _levelName(ReminderLevel l) => switch (l) {
  ReminderLevel.notification => 'notification',
  ReminderLevel.sticky => 'sticky',
  ReminderLevel.alarm => 'alarm',
  ReminderLevel.strictAlarm => 'strict alarm',
};

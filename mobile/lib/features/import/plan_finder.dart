import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/schema/validator.dart';
import '../../data/repository.dart';
import 'direct_import.dart';

/// Off in tests, where the shared clipboard would offer plans in other flows.
final planFinderEnabledProvider = Provider<bool>((ref) => true);

const _armedKey = 'aiFlow.armedUntil';
const _seenKey = 'aiFlow.seenPlan';
const _promptKey = 'aiFlow.prompt';

/// How long after "Open ChatGPT" the app looks for a copied answer. Reading
/// the clipboard on every start would show Android's "pasted from your
/// clipboard" note each time; this way it only reads while the user is
/// making a plan.
const armedFor = Duration(hours: 2);

class FoundPlan {
  const FoundPlan(this.text, this.title);

  final String text;
  final String title;
}

/// The user copied [prompt] for an AI: look for the answer when they come
/// back. The prompt itself holds an example plan, so it is remembered and
/// never offered as the answer.
Future<void> armPlanFinder(WidgetRef ref, String prompt) async {
  final until = ref.read(wallClockProvider)().add(armedFor);
  final repo = ref.read(repositoryProvider);
  await repo.setSetting(_armedKey, until.toIso8601String());
  await repo.setSetting(_promptKey, _hash(prompt.trim()));
}

/// A plan in [text]: a goal or a bundle, inside a code block or around other
/// words. It need not be valid; the preview shows the problems and Fix with AI.
FoundPlan? planIn(String? text) {
  final t = text?.trim();
  if (t == null || t.isEmpty || utf8.encode(t).length > maxDocumentBytes) return null;
  Object? json;
  try {
    json = jsonDecode(extractJson(t));
  } on FormatException {
    return null;
  }
  if (json is! Map) return null;
  if (json['kind'] != 'goal' && json['kind'] != 'bundle') return null;
  final goals = json['kind'] == 'goal'
      ? [json]
      : [
          for (final d in (json['documents'] as List?) ?? const [])
            if (d is Map && d['kind'] == 'goal') d,
        ];
  final first = goals.firstOrNull?['title'];
  final title = goals.length > 1
      ? '${goals.length} goals'
      : (first is String && first.isNotEmpty ? first : 'your plan');
  return FoundPlan(t, title);
}

String _hash(String text) => sha1.convert(utf8.encode(text)).toString();

/// The plan in the clipboard, if there is one; not the prompt the app copied.
/// Read only while the app is in front: Android allows nothing else.
Future<FoundPlan?> copiedPlan(WidgetRef ref) async {
  final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
  if (text == null) return null;
  final prompt = (await ref.read(repositoryProvider).settings())[_promptKey];
  return prompt == _hash(text) ? null : planIn(text);
}

/// Marks [text] as handled, so the same answer is not offered again.
Future<void> markPlanSeen(WidgetRef ref, String text) => markPlanSeenIn(ref.read(repositoryProvider), text);

/// [markPlanSeen] without a screen: for work that outlives the screen.
Future<void> markPlanSeenIn(Repository repo, String text) async {
  await repo.setSetting(_seenKey, _hash(text));
  await repo.setSetting(_armedKey, '');
}

/// On return from the AI chat: "Plan found: <title>. See plan". Once per
/// answer, and only while the plan flow is armed.
Future<void> offerCopiedPlan(BuildContext context, WidgetRef ref) async {
  if (!ref.read(planFinderEnabledProvider)) return;
  final repo = ref.read(repositoryProvider);
  final s = await repo.settings();
  final until = DateTime.tryParse(s[_armedKey] ?? '');
  if (until == null || ref.read(wallClockProvider)().isAfter(until)) return;
  final plan = await copiedPlan(ref);
  if (plan == null || s[_seenKey] == _hash(plan.text) || !context.mounted) return;
  await repo.setSetting(_seenKey, _hash(plan.text));
  if (!context.mounted) return;
  final open = await showModalBottomSheet<bool>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Padding(
        key: const ValueKey('plan-found'),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.task_alt, size: 40),
            const SizedBox(height: 8),
            Text('Plan found: ${plan.title}', textAlign: TextAlign.center, style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('You copied it from your AI chat.', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('plan-found-open'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('See plan'),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
          ],
        ),
      ),
    ),
  );
  if (open == true && context.mounted) await importOrReview(context, ref, plan.text);
}

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/providers.dart';
import '../core/events/goal_event.dart';
import '../engines/engine.dart';
import '../features/goal/goal_screen.dart';
import '../features/player/player_screen.dart';
import '../features/reader/reader_screen.dart';

/// Picks a PDF for a goal. Tests replace it; the real one opens the system
/// file picker and copies the file into app storage.
final pdfPickerProvider = Provider<Future<String?> Function(String goalId)>(
  (ref) => (goalId) async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    final path = picked.firstOrNull?.path;
    if (path == null) return null;
    final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/books');
    await dir.create(recursive: true);
    final target = '${dir.path}/$goalId.pdf';
    await File(path).copy(target);
    return target;
  },
);

/// Opens a link in another app. Tests replace it, because the real one leaves
/// the app.
final externalLauncherProvider = Provider<Future<void> Function(Uri url)>(
  (ref) =>
      (url) => launchUrl(url, mode: LaunchMode.externalApplication),
);

/// Maps action types to handlers. Spec §8.
class ActionRouter {
  ActionRouter(this.context, this.ref);

  final BuildContext context;
  final WidgetRef ref;

  Future<void> call(Map<String, Object?> action) async {
    final params = (action['params'] as Map?)?.cast<String, Object?>() ?? const {};
    final repo = ref.read(repositoryProvider);
    final goalId = params['goalId'] as String?;

    switch (action['type']) {
      case 'open_goal':
        if (goalId != null) _push(GoalScreen(goalId: goalId));
      case 'open_video':
        final videoId = params['videoId'] as String?;
        if (videoId == null || goalId == null) return;
        _push(
          PlayerScreen(
            goalId: goalId,
            itemId: params['itemId'] as String?,
            videoId: videoId,
            startSec: asNum(params['startSec'])?.toInt() ?? 0,
          ),
        );
      case 'open_pdf_page':
        final id = (params['documentId'] ?? goalId) as String?;
        if (id == null) return;
        _push(ReaderScreen(goalId: id, page: asNum(params['page'])?.toInt() ?? 1));
      case 'open_external':
        final url = Uri.tryParse(params['url'] as String? ?? '');
        if (url != null && (url.scheme == 'https' || url.scheme == 'vnd.youtube')) {
          await ref.read(externalLauncherProvider)(url);
        }
      case 'link_file':
        final id = (params['documentId'] ?? goalId) as String?;
        if (id == null) return;
        final path = await ref.read(pdfPickerProvider)(id);
        if (path != null) await repo.linkFile(id, id, 'local_path', path);
      case 'mark_done':
        if (goalId == null) return;
        final item = params['itemId'] as String?;
        if (item != null) {
          await repo.addEvent(goalId, EventType.itemDone, {'item': item, 'done': true});
        } else {
          await _completeToday(goalId);
        }
      case 'toggle_done':
        if (goalId == null) return;
        await _toggle(goalId, params);
      case 'log_progress':
        if (goalId == null) return;
        final delta = asNum(params['delta']);
        final value = asNum(params['value']);
        if (delta != null) {
          await repo.addEvent(goalId, EventType.countDelta, {'delta': delta});
        } else if (value != null) {
          await repo.addEvent(goalId, EventType.pageReached, {'page': value.toInt()});
        }
      case 'notify':
        _snack(params['message'] as String? ?? '');
      default:
        debugPrint('Unknown action: ${action['type']}');
    }
  }

  void _push(Widget screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  void _snack(String message) {
    if (message.isEmpty) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// "Done today" means something different for each engine.
  Future<void> _completeToday(String goalId) async {
    final view = ref.read(goalViewProvider(goalId));
    if (view == null) return;
    final repo = ref.read(repositoryProvider);
    final s = view.state;
    switch (s['mode'] ?? view.template?.engine) {
      case 'check':
        if (s['avoid'] != true) await repo.addEvent(goalId, EventType.check, {'checked': true});
      case 'count':
        final left = ((s['target'] as num? ?? 0) - (s['count'] as num? ?? 0)).toInt();
        if (left > 0) await repo.addEvent(goalId, EventType.countDelta, {'delta': left});
      case 'checklist':
        for (final step in (s['steps'] as List? ?? const []).whereType<Map>()) {
          if (step['done'] != true) {
            await repo.addEvent(goalId, EventType.stepDone, {'step': step['id'], 'done': true});
          }
        }
      case 'page_range':
        final end = (s['today'] as Map?)?['endPage'];
        if (end is int) await repo.addEvent(goalId, EventType.pageReached, {'page': end});
      case 'video_series':
        final next = (s['next'] as Map?)?['id'];
        if (next is String) await repo.addEvent(goalId, EventType.itemDone, {'item': next, 'done': true});
    }
  }

  Future<void> _toggle(String goalId, Map<String, Object?> params) async {
    final view = ref.read(goalViewProvider(goalId));
    if (view == null) return;
    final repo = ref.read(repositoryProvider);
    final s = view.state;
    final step = params['stepId'] as String?;
    final item = params['itemId'] as String?;
    if (step != null) {
      final current =
          (s['steps'] as List? ?? const []).whereType<Map>().firstWhere(
            (x) => x['id'] == step,
            orElse: () => const {},
          )['done'] ==
          true;
      await repo.addEvent(goalId, EventType.stepDone, {'step': step, 'done': !current});
    } else if (item != null) {
      final current =
          (s['items'] as List? ?? const []).whereType<Map>().firstWhere(
            (x) => x['id'] == item,
            orElse: () => const {},
          )['done'] ==
          true;
      await repo.addEvent(goalId, EventType.itemDone, {'item': item, 'done': !current});
    } else {
      await repo.addEvent(goalId, EventType.check, {'checked': s['checked'] != true});
    }
  }
}

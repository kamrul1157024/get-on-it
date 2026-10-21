import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../actions/action_router.dart';
import '../../app/providers.dart';
import '../../core/events/goal_event.dart';
import '../../render/components.dart';

/// Opens a goal's PDF at a page and records pages the user stays on for 5
/// seconds. Spec §7.4.
class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({super.key, required this.goalId, required this.page});

  final String goalId;
  final int page;

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  static const dwell = Duration(seconds: 5);
  Timer? _timer;
  int _recorded = 0;

  @override
  void initState() {
    super.initState();
    _recorded = ref.read(goalViewProvider(widget.goalId))?.state['lastPage'] as int? ?? 0;
  }

  void _onPage(int? page) {
    _timer?.cancel();
    if (page == null || page <= _recorded) return;
    _timer = Timer(dwell, () {
      _recorded = page;
      ref.read(repositoryProvider).addEvent(widget.goalId, EventType.pageReached, {'page': page});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(goalViewProvider(widget.goalId));
    final files = ref.watch(linkedFilesProvider(widget.goalId)).value ?? const {};
    final s = view?.state ?? const {};
    final today = (s['today'] as Map?) ?? const {};
    final path = files[widget.goalId];
    final url = s['isUrl'] == true ? s['url'] as String? : null;

    final params = PdfViewerParams(onPageChanged: _onPage, onViewerReady: (_, c) => _onPage(c.pageNumber));
    Widget body;
    if (path != null) {
      body = PdfViewer.file(path, params: params, initialPageNumber: widget.page);
    } else if (url != null && url.startsWith('https://')) {
      body = PdfViewer.uri(Uri.parse(url), params: params, initialPageNumber: widget.page);
    } else {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Select the PDF for this book.'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => ActionRouter(context, ref).call({
                  'type': 'link_file',
                  'params': {'goalId': widget.goalId},
                }),
                child: const Text('Select PDF'),
              ),
            ],
          ),
        ),
      );
    }

    return withAccent(
      context,
      view?.goal.accent,
      Scaffold(
        appBar: AppBar(title: Text((s['book'] as Map?)?['title'] as String? ?? view?.goal.title ?? 'Book')),
        body: Column(
          children: [
            Material(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: ListTile(
                key: const ValueKey('reader-banner'),
                dense: true,
                leading: Icon(s['todayComplete'] == true ? Icons.check_circle : Icons.menu_book),
                title: Text('Today: ${today['label'] ?? ''}'),
                subtitle: Text(s['progressLabel'] as String? ?? ''),
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

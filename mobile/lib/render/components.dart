import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/binding/resolver.dart';
import 'renderer.dart';

/// The component catalog. Spec §6.5. Keep in sync with `Capabilities.components`.
final Map<String, ComponentBuilder> componentBuilders = {
  'column': _column,
  'row': _row,
  'card': _card,
  'grid': _grid,
  'list': _list,
  'section': _section,
  'divider': (n, rc) => const Divider(height: 1),
  'spacer': (n, rc) => SizedBox.square(dimension: n.number('size', rc.scope) ?? 8),
  'text': _text,
  'icon': _icon,
  'image': _image,
  'badge': _badge,
  'stat': _stat,
  'progress_bar': _progressBar,
  'progress_ring': _progressRing,
  'week_dots': _weekDots,
  'heatmap': _heatmap,
  'media': _media,
  'button': _button,
  'checklist_item': _checklistItem,
  'counter': _counter,
  'number_input': (n, rc) => _NumberInput(node: n, rc: rc),
  'embed': _embed,
};

List<Widget> _gapped(List<Widget> children, double gap, Axis axis) {
  if (gap <= 0 || children.length < 2) return children;
  final out = <Widget>[];
  for (var i = 0; i < children.length; i++) {
    if (i > 0) out.add(axis == Axis.vertical ? SizedBox(height: gap) : SizedBox(width: gap));
    out.add(children[i]);
  }
  return out;
}

Widget _column(Map<String, Object?> n, RenderContext rc) {
  final align = n.str('align', rc.scope);
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: switch (align) {
      'center' => CrossAxisAlignment.center,
      'end' => CrossAxisAlignment.end,
      'start' => CrossAxisAlignment.start,
      _ => CrossAxisAlignment.stretch,
    },
    children: _gapped(buildChildren(n, rc), n.number('gap', rc.scope) ?? 0, Axis.vertical),
  );
}

const _shrinkable = {'text', 'column', 'row', 'stat', 'badge', 'list', 'section'};

Widget _row(Map<String, Object?> n, RenderContext rc) {
  final align = n.str('align', rc.scope);
  final raw = n['children'] as List? ?? const [];
  // Documents cannot know the screen width, so content that can wrap may
  // shrink rather than overflow the row. Controls keep their natural size, and
  // hidden children take no share of the space.
  final children = <Widget>[
    for (final c in raw.whereType<Map>())
      if (!c.containsKey('visible') || c.cast<String, Object?>().flag('visible', rc.scope))
        if (c['expand'] == true)
          Expanded(child: buildNode(c, rc))
        else if (_shrinkable.contains(c['type']))
          Flexible(child: buildNode(c, rc))
        else
          buildNode(c, rc),
  ];
  return Row(
    crossAxisAlignment: align == 'top' ? CrossAxisAlignment.start : CrossAxisAlignment.center,
    mainAxisAlignment: align == 'between' ? MainAxisAlignment.spaceBetween : MainAxisAlignment.start,
    children: _gapped(children, n.number('gap', rc.scope) ?? 0, Axis.horizontal),
  );
}

Color? parseColor(String? hex) {
  if (hex == null || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
  return Color(int.parse('ff${hex.substring(1)}', radix: 16));
}

/// Applies a goal accent to a subtree by re-seeding the color scheme.
Widget withAccent(BuildContext context, String? accent, Widget child) {
  final color = parseColor(accent);
  if (color == null) return child;
  final theme = Theme.of(context);
  return Theme(
    data: theme.copyWith(
      colorScheme: ColorScheme.fromSeed(seedColor: color, brightness: theme.brightness),
    ),
    child: child,
  );
}

Widget _card(Map<String, Object?> n, RenderContext rc) {
  final style = n.str('style', rc.scope) ?? 'elevated';
  final action = n['action'];
  return Builder(
    builder: (context) {
      return withAccent(
        context,
        n.str('accent', rc.scope),
        Builder(
          builder: (context) {
            final scheme = Theme.of(context).colorScheme;
            final tile = style == 'tile';
            Widget body = Padding(padding: EdgeInsets.all(tile ? 12 : 16), child: buildNode(n['child'], rc));
            if (action != null) {
              body = InkWell(onTap: () => rc.dispatch(action), child: body);
            }
            final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(tile ? 16 : 20));
            return switch (style) {
              'outlined' => Card.outlined(
                margin: EdgeInsets.zero,
                shape: shape,
                clipBehavior: Clip.antiAlias,
                child: body,
              ),
              'tonal' => Card.filled(
                margin: EdgeInsets.zero,
                shape: shape,
                color: scheme.primaryContainer.withValues(alpha: 0.45),
                clipBehavior: Clip.antiAlias,
                child: body,
              ),
              'tile' => Card.filled(
                margin: EdgeInsets.zero,
                shape: shape,
                color: scheme.surfaceContainerHigh,
                clipBehavior: Clip.antiAlias,
                child: body,
              ),
              _ => Card(margin: EdgeInsets.zero, shape: shape, clipBehavior: Clip.antiAlias, child: body),
            };
          },
        ),
      );
    },
  );
}

Widget _grid(Map<String, Object?> n, RenderContext rc) {
  final columns = (n.number('columns', rc.scope) ?? 2).toInt().clamp(1, 6);
  final gap = n.number('gap', rc.scope) ?? 8;
  final raw = (n['children'] as List? ?? const []).whereType<Map>().toList();
  final rows = <Widget>[];
  var current = <Widget>[];
  var used = 0;
  void flush() {
    if (current.isEmpty) return;
    while (used < columns) {
      current.add(const Expanded(child: SizedBox.shrink()));
      used++;
    }
    rows.add(
      IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: _gapped(current, gap, Axis.horizontal)),
      ),
    );
    current = [];
    used = 0;
  }

  for (final c in raw) {
    final span = ((c['span'] as num?) ?? 1).toInt().clamp(1, columns);
    if (used + span > columns) flush();
    current.add(Expanded(flex: span, child: buildNode(c, rc)));
    used += span;
  }
  flush();
  return Column(mainAxisSize: MainAxisSize.min, children: _gapped(rows, gap, Axis.vertical));
}

Widget _list(Map<String, Object?> n, RenderContext rc) {
  final items = resolve(n['items'], rc.scope);
  if (items is! List) return const SizedBox.shrink();
  final name = n.str('as', rc.scope) ?? 'item';
  final max = n.number('maxItems', rc.scope)?.toInt();
  final shown = max == null ? items : items.take(max);
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: _gapped(
      [for (final item in shown) buildNode(n['item'], rc.withVar(name, item))],
      n.number('gap', rc.scope) ?? 0,
      Axis.vertical,
    ),
  );
}

Widget _section(Map<String, Object?> n, RenderContext rc) => Builder(
  builder: (context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(n.str('title', rc.scope) ?? '', style: Theme.of(context).textTheme.titleMedium),
      ),
      buildNode(n['child'], rc),
    ],
  ),
);

Widget _text(Map<String, Object?> n, RenderContext rc) => Builder(
  builder: (context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final style = switch (n.str('style', rc.scope)) {
      'display' => t.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
      'title' => t.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      'subtitle' => t.titleMedium,
      'caption' => t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      'label' => t.labelSmall?.copyWith(color: scheme.primary, letterSpacing: 1.2, fontWeight: FontWeight.w700),
      _ => t.bodyMedium,
    };
    var value = n.str('value', rc.scope) ?? '';
    if (n.str('style', rc.scope) == 'label') value = value.toUpperCase();
    final maxLines = n.number('maxLines', rc.scope)?.toInt();
    return Text(value, style: style, maxLines: maxLines, overflow: maxLines == null ? null : TextOverflow.ellipsis);
  },
);

Widget _icon(Map<String, Object?> n, RenderContext rc) => Builder(
  builder: (context) {
    final name = n.str('name', rc.scope) ?? '';
    final glyph = Text(name, style: const TextStyle(fontSize: 20));
    if (!n.flag('box', rc.scope)) return glyph;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: glyph,
    );
  },
);

Widget _image(Map<String, Object?> n, RenderContext rc) {
  final src = n.str('src', rc.scope);
  if (src == null || !src.startsWith('https://')) return const SizedBox.shrink();
  return ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: Image.network(
      src,
      width: n.number('width', rc.scope),
      height: n.number('height', rc.scope),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    ),
  );
}

(Color, Color) _toneColors(ColorScheme s, String? tone) => switch (tone) {
  'success' => (const Color(0xFF2E7D4F).withValues(alpha: 0.18), const Color(0xFF3FA66A)),
  'warning' => (const Color(0xFFF0A33A).withValues(alpha: 0.2), const Color(0xFFC77A10)),
  'danger' => (s.errorContainer, s.onErrorContainer),
  _ => (s.surfaceContainerHighest, s.onSurfaceVariant),
};

Widget _badge(Map<String, Object?> n, RenderContext rc) => Builder(
  builder: (context) {
    final (bg, fg) = _toneColors(Theme.of(context).colorScheme, n.str('tone', rc.scope));
    return Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
        child: Text(
          n.str('label', rc.scope) ?? '',
          style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
    );
  },
);

Widget _stat(Map<String, Object?> n, RenderContext rc) => Builder(
  builder: (context) {
    final t = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(n.str('value', rc.scope) ?? '', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        Text(
          n.str('label', rc.scope) ?? '',
          style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    );
  },
);

double _unit(double? v) => (v ?? 0).clamp(0.0, 1.0);

Widget _progressBar(Map<String, Object?> n, RenderContext rc) => LinearProgressIndicator(
  value: _unit(n.number('value', rc.scope)),
  minHeight: 8,
  borderRadius: BorderRadius.circular(99),
);

Widget _progressRing(Map<String, Object?> n, RenderContext rc) => Builder(
  builder: (context) {
    final size = n.number('size', rc.scope) ?? 80;
    final stroke = n.number('stroke', rc.scope) ?? 8;
    final label = n.str('label', rc.scope);
    final sub = n.str('sublabel', rc.scope);
    final t = Theme.of(context).textTheme;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: _unit(n.number('value', rc.scope)),
              strokeWidth: stroke,
              strokeCap: StrokeCap.round,
              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (label != null && label.isNotEmpty)
                Text(label, style: (size >= 80 ? t.titleMedium : t.labelMedium)?.copyWith(fontWeight: FontWeight.w700)),
              if (sub != null && sub.isNotEmpty) Text(sub, style: t.labelSmall),
            ],
          ),
        ],
      ),
    );
  },
);

Widget _weekDots(Map<String, Object?> n, RenderContext rc) => Builder(
  builder: (context) {
    final scheme = Theme.of(context).colorScheme;
    final days = resolve(n['days'], rc.scope);
    if (days is! List) return const SizedBox.shrink();
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (final d in days.whereType<Map>())
          Column(
            children: [
              Text('${d['d']}', style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(height: 4),
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: switch (d['s']) {
                    'done' => scheme.primary,
                    'rest' => Colors.transparent,
                    _ => scheme.surfaceContainerHighest,
                  },
                  border: switch (d['s']) {
                    'today' => Border.all(color: scheme.primary, width: 2),
                    'rest' => Border.all(color: scheme.outlineVariant),
                    _ => null,
                  },
                ),
                child: d['s'] == 'done' ? Icon(Icons.check, size: 14, color: scheme.onPrimary) : null,
              ),
            ],
          ),
      ],
    );
  },
);

Widget _heatmap(Map<String, Object?> n, RenderContext rc) => Builder(
  builder: (context) {
    final scheme = Theme.of(context).colorScheme;
    final cells = resolve(n['cells'], rc.scope);
    if (cells is! List) return const SizedBox.shrink();
    final weeks = (cells.length / 7).ceil();
    return LayoutBuilder(
      builder: (context, box) {
        final cell = math.min(16.0, (box.maxWidth - (weeks - 1) * 3) / weeks);
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var w = 0; w < weeks; w++)
              Column(
                children: [
                  for (var d = 0; d < 7; d++)
                    if (w * 7 + d < cells.length)
                      Container(
                        width: cell,
                        height: cell,
                        margin: const EdgeInsets.only(bottom: 3),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(3),
                          color: switch (((cells[w * 7 + d] as Map?)?['level'] as num?) ?? 0) {
                            < 0 => Colors.transparent,
                            >= 4 => scheme.primary,
                            >= 2 => scheme.primary.withValues(alpha: 0.4),
                            _ => scheme.surfaceContainerHighest,
                          },
                        ),
                      ),
                ],
              ),
          ],
        );
      },
    );
  },
);

Widget _media(Map<String, Object?> n, RenderContext rc) => Builder(
  builder: (context) {
    final w = n.number('width', rc.scope) ?? 120;
    final h = n.number('height', rc.scope) ?? 68;
    if (n.str('kind', rc.scope) == 'pdf_page') {
      return Container(
        width: w,
        height: h,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: const Color(0xFFF5F1E8), borderRadius: BorderRadius.circular(10)),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(height: 6, width: w * 0.5, color: const Color(0xFF6B6455)),
                const SizedBox(height: 8),
                for (var i = 0; i < ((h - 34) / 9).floor(); i++)
                  Container(
                    height: 4,
                    width: (w - 16) * (0.7 + (i * 37 % 30) / 100),
                    margin: const EdgeInsets.only(bottom: 5),
                    color: const Color(0xFFC9C2B2),
                  ),
              ],
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: Text(
                n.str('page', rc.scope) ?? '',
                style: const TextStyle(fontSize: 10, color: Color(0xFF6B6455)),
              ),
            ),
          ],
        ),
      );
    }
    final videoId = n.str('videoId', rc.scope);
    final progress = _unit(n.number('progress', rc.scope));
    final ts = n.str('timestamp', rc.scope);
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: w,
        height: h,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const DecoratedBox(
              decoration: BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF8C1515), Color(0xFF3D0A0A)])),
            ),
            if (videoId != null && RegExp(r'^[\w-]{6,20}$').hasMatch(videoId))
              Image.network(
                'https://i.ytimg.com/vi/$videoId/mqdefault.jpg',
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            const Center(child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 32)),
            if (ts != null && ts.isNotEmpty)
              Positioned(
                right: 6,
                bottom: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  color: Colors.black87,
                  child: Text(ts, style: const TextStyle(color: Colors.white, fontSize: 11)),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 3,
                color: Colors.red,
                backgroundColor: Colors.white24,
              ),
            ),
          ],
        ),
      ),
    );
  },
);

Widget _button(Map<String, Object?> n, RenderContext rc) {
  final label = n.str('label', rc.scope) ?? '';
  final icon = n.str('icon', rc.scope);
  final text = Text(icon == null || icon.isEmpty ? label : '$icon  $label');
  void tap() => rc.dispatch(n['action']);
  final Widget b = switch (n.str('variant', rc.scope)) {
    'tonal' => FilledButton.tonal(onPressed: tap, child: text),
    'text' => TextButton(onPressed: tap, child: text),
    'outlined' => OutlinedButton(onPressed: tap, child: text),
    _ => FilledButton(onPressed: tap, child: text),
  };
  return n.flag('full', rc.scope) ? SizedBox(width: double.infinity, child: b) : b;
}

Widget _checklistItem(Map<String, Object?> n, RenderContext rc) => Builder(
  builder: (context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final checked = n.flag('checked', rc.scope);
    final icon = n.str('icon', rc.scope);
    final sub = n.str('sublabel', rc.scope);
    final label = n.str('label', rc.scope) ?? '';
    return InkWell(
      key: ValueKey('check:$label'),
      borderRadius: BorderRadius.circular(12),
      onTap: () => rc.dispatch(n['action']),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: checked ? scheme.primary : null,
                border: Border.all(color: checked ? scheme.primary : scheme.outline, width: 2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: checked ? Icon(Icons.check, size: 16, color: scheme.onPrimary) : null,
            ),
            const SizedBox(width: 12),
            if (icon != null && icon.isNotEmpty) ...[
              Text(icon, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: t.bodyMedium?.copyWith(
                      decoration: checked ? TextDecoration.lineThrough : null,
                      color: checked ? scheme.onSurfaceVariant : null,
                    ),
                  ),
                  if (sub != null && sub.isNotEmpty)
                    Text(sub, style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  },
);

Widget _counter(Map<String, Object?> n, RenderContext rc) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    IconButton.filledTonal(
      key: const ValueKey('counter:decrement'),
      onPressed: () => rc.dispatch(n['decrement']),
      icon: const Icon(Icons.remove),
    ),
    const SizedBox(width: 8),
    IconButton.filledTonal(
      key: const ValueKey('counter:increment'),
      onPressed: () => rc.dispatch(n['increment']),
      icon: const Icon(Icons.add),
    ),
  ],
);

Widget _embed(Map<String, Object?> n, RenderContext rc) {
  final goalId = n.str('goalId', rc.scope);
  final surface = n.str('surface', rc.scope) ?? 'tile';
  final found = goalId == null ? null : rc.embed?.call(goalId, surface);
  if (found == null) {
    return const Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(padding: EdgeInsets.all(12), child: Text('Goal removed')),
    );
  }
  return buildNode(found.tree, rc.withScope(found.scope));
}

class _NumberInput extends StatefulWidget {
  const _NumberInput({required this.node, required this.rc});

  final Map<String, Object?> node;
  final RenderContext rc;

  @override
  State<_NumberInput> createState() => _NumberInputState();
}

class _NumberInputState extends State<_NumberInput> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final v = num.tryParse(_controller.text.trim());
    final action = widget.node['action'];
    if (v == null || action is! Map) return;
    final params = {...?(action['params'] as Map?)?.cast<String, Object?>(), 'value': v};
    widget.rc.dispatch({...action, 'params': params});
    _controller.clear();
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.node;
    final rc = widget.rc;
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: ValueKey('number:${n['id'] ?? n.str('label', rc.scope)}'),
            controller: _controller,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: n.str('label', rc.scope),
              hintText: n.str('hint', rc.scope),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton.tonal(onPressed: _submit, child: Text(n.str('buttonLabel', rc.scope) ?? 'Save')),
      ],
    );
  }
}

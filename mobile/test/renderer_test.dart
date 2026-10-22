import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/render/layout_guard.dart';
import 'package:getonit/render/renderer.dart';

void main() {
  late List<Map<String, Object?>> dispatched;

  Future<void> render(
    WidgetTester tester,
    Map<String, Object?> tree,
    Map<String, Object?> scope, {
    EmbedResolver? embed,
  }) async {
    dispatched = [];
    final rc = RenderContext(scope: scope, onAction: (a) async => dispatched.add(a), embed: embed);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: buildNode(tree, rc))),
      ),
    );
  }

  testWidgets('text and visible bindings', (tester) async {
    await render(
      tester,
      {
        'type': 'column',
        'children': [
          {'type': 'text', 'value': 'Read {{state.today.label}}'},
          {'type': 'text', 'value': 'hidden', 'visible': '{{state.todayComplete}}'},
          {'type': 'text', 'value': 'shown', 'visible': '{{state.todayPending}}'},
        ],
      },
      {
        'state': {
          'today': {'label': 'p. 45–46'},
          'todayComplete': false,
          'todayPending': true,
        },
      },
    );
    expect(find.text('Read p. 45–46'), findsOneWidget);
    expect(find.text('hidden'), findsNothing);
    expect(find.text('shown'), findsOneWidget);
  });

  testWidgets('actions are resolved at tap time', (tester) async {
    await render(
      tester,
      {
        'type': 'button',
        'label': 'Read',
        'action': {
          'type': 'open_pdf_page',
          'params': {'documentId': '{{goal.id}}', 'page': '{{state.today.startPage}}'},
        },
      },
      {
        'goal': {'id': 'atomic-habits'},
        'state': {
          'today': {'startPage': 45},
        },
      },
    );
    await tester.tap(find.text('Read'));
    expect(dispatched.single, {
      'type': 'open_pdf_page',
      'params': {'documentId': 'atomic-habits', 'page': 45},
    });
  });

  testWidgets('list repeats its item with a loop variable', (tester) async {
    await render(
      tester,
      {
        'type': 'list',
        'items': '{{state.steps}}',
        'as': 'st',
        'item': {
          'type': 'checklist_item',
          'label': '{{st.title}}',
          'checked': '{{st.done}}',
          'action': {
            'type': 'toggle_done',
            'params': {'stepId': '{{st.id}}'},
          },
        },
      },
      {
        'state': {
          'steps': [
            {'id': 'a', 'title': 'Stretch', 'done': true},
            {'id': 'b', 'title': 'Journal', 'done': false},
          ],
        },
      },
    );
    expect(find.text('Stretch'), findsOneWidget);
    await tester.tap(find.text('Journal'));
    expect(dispatched.single['params'], {'stepId': 'b'});
  });

  testWidgets('unknown components use their fallback and never throw', (tester) async {
    await render(tester, {
      'type': 'column',
      'children': [
        {
          'type': 'rep_tracker',
          'fallback': {'type': 'text', 'value': 'Update the app'},
        },
        {'type': 'hologram'},
      ],
    }, const {});
    expect(find.text('Update the app'), findsOneWidget);
    expect(find.text('Unsupported component: hologram'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('embed renders another goal with its own scope', (tester) async {
    await render(
      tester,
      {
        'type': 'grid',
        'columns': 2,
        'children': [
          {'type': 'embed', 'goalId': 'water', 'surface': 'tile'},
          {'type': 'embed', 'goalId': 'gone', 'surface': 'tile'},
        ],
      },
      {
        'state': {'label': 'outer'},
      },
      embed: (id, surface) => id == 'water'
          ? (
              tree: {'type': 'text', 'value': '{{state.label}}'},
              scope: {
                'state': {'label': '5 / 8 glasses'},
              },
            )
          : null,
    );
    expect(find.text('5 / 8 glasses'), findsOneWidget);
    expect(find.text('outer'), findsNothing);
    expect(find.text('Goal removed'), findsOneWidget);
  });

  testWidgets('a row gives full-width children a share instead of failing the layout', (tester) async {
    // AI-made templates put these in rows; one unbounded child blanked the
    // whole goal screen.
    await render(tester, {
      'type': 'row',
      'gap': 8,
      'children': [
        {
          'type': 'button',
          'full': true,
          'label': '+10',
          'action': {'type': 'notify'},
        },
        {'type': 'progress_bar', 'value': 0.5},
        {'type': 'number_input', 'label': 'Pages'},
        {
          'type': 'week_dots',
          'days': [
            {'d': 'M', 's': 'done'},
          ],
        },
        {
          'type': 'heatmap',
          'cells': [
            {'level': 1},
          ],
        },
        {
          'type': 'grid',
          'columns': 2,
          'children': [
            {'type': 'text', 'value': 'cell'},
          ],
        },
      ],
    }, const {});
    expect(tester.takeException(), isNull);
    expect(find.text('+10'), findsOneWidget);
    expect(find.text('cell'), findsOneWidget);
  });

  testWidgets('a card that fails to lay out takes only itself down', (tester) async {
    final report = FlutterError.onError;
    var errors = 0;
    FlutterError.onError = (_) => errors++;
    try {
      await render(tester, {
        'type': 'column',
        'children': [
          {
            'type': 'card',
            'child': {
              'type': 'grid',
              'children': [
                {
                  'type': 'heatmap',
                  'cells': [
                    {'level': 1},
                  ],
                },
              ],
            },
          },
          {
            'type': 'card',
            'child': {
              'type': 'button',
              'label': 'Still here',
              'action': {'type': 'notify'},
            },
          },
        ],
      }, const {});
      await tester.pump();
      await tester.tap(find.text('Still here'));
    } finally {
      FlutterError.onError = report;
    }
    expect(errors, greaterThan(0));
    expect(dispatched.single['type'], 'notify');
    final guards = tester.renderObjectList<RenderLayoutGuard>(find.byType(LayoutGuard)).toList();
    expect(guards.map((g) => g.failed), [true, false]);
  });
}

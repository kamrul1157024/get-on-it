import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/core/binding/resolver.dart';

void main() {
  final scope = <String, Object?>{
    'goal': {'id': 'cs229', 'title': 'CS229'},
    'state': {
      'progress': 0.42,
      'count': 5.0,
      'today': {'label': 'p. 45–46', 'startPage': 45},
      'items': [
        {'title': 'Lecture 1'},
      ],
      'done': true,
    },
  };

  test('a whole binding returns the raw value', () {
    expect(resolve('{{state.progress}}', scope), 0.42);
    expect(resolve('{{state.today}}', scope), isA<Map>());
    expect(resolve('{{state.done}}', scope), true);
  });

  test('mixed text returns a string', () {
    expect(resolve('Read {{state.today.label}} now', scope), 'Read p. 45–46 now');
    expect(resolve('{{state.count}} glasses', scope), '5 glasses');
  });

  test('array indexes and missing paths', () {
    expect(resolve('{{state.items.0.title}}', scope), 'Lecture 1');
    expect(resolve('{{state.items.3.title}}', scope), isNull);
    expect(resolve('{{state.nope.deeper}}', scope), isNull);
    expect(resolve('x{{state.nope}}y', scope), 'xy');
  });

  test('maps and lists resolve recursively', () {
    final action = {
      'type': 'open_pdf_page',
      'params': {'documentId': '{{goal.id}}', 'page': '{{state.today.startPage}}'},
    };
    expect(resolve(action, scope), {
      'type': 'open_pdf_page',
      'params': {'documentId': 'cs229', 'page': 45},
    });
  });

  test('bindings are paths only; expressions are not evaluated', () {
    expect(resolve('{{state.count + 1}}', scope), isNull);
  });
}

import 'dart:io';

import 'package:correlia_tool/correlia_tool.dart';
import 'package:test/test.dart';

void main() {
  group('untaggedWithServerpodCalls', () {
    test('a call without testGroupTagsOverride is reported by line', () {
      const source = '''
void main() {
  withServerpod('Given x', (s, e) {
    test('t', () {});
  });
}
''';
      expect(untaggedWithServerpodCalls(source), [2]);
    });

    test('a call with a tier tag is accepted', () {
      for (final tier in ['db', 'e2e', 'plugin', 'load']) {
        final source =
            "void main() { withServerpod('g', (s, e) {}, "
            "testGroupTagsOverride: ['$tier']); }";
        expect(untaggedWithServerpodCalls(source), isEmpty, reason: tier);
      }
    });

    test('a tier tag among other tags is accepted', () {
      const source = '''
void main() {
  withServerpod(
    'g',
    (s, e) {},
    testGroupTagsOverride: ["slow", "db"],
  );
}
''';
      expect(untaggedWithServerpodCalls(source), isEmpty);
    });

    test('an override without a tier tag is reported', () {
      for (final tags in ["['integration']", '[]', "['fast']", 'null']) {
        final source =
            "void main() { withServerpod('g', (s, e) {}, "
            'testGroupTagsOverride: $tags); }';
        expect(untaggedWithServerpodCalls(source), [1], reason: tags);
      }
    });

    test('the override must belong to the call, not a later one', () {
      const source = '''
void main() {
  withServerpod('a', (s, e) {});
  withServerpod('b', (s, e) {}, testGroupTagsOverride: ['db']);
}
''';
      expect(untaggedWithServerpodCalls(source), [2]);
    });

    test('a tier tag in a nested call or a test body does not count', () {
      const source = '''
void main() {
  withServerpod('a', (s, e) {
    test('t', () {}, tags: ['db']);
    final testGroupTagsOverride = ['db'];
  });
}
''';
      expect(untaggedWithServerpodCalls(source), [2]);
    });

    test('mentions in comments and strings are not calls', () {
      const source = r'''
// withServerpod('a', (s, e) {});
/* withServerpod('b', (s, e) {}); */
/// Use withServerpod( ... ) with testGroupTagsOverride.
void main() {
  print("withServerpod('c', (s, e) {})");
  print('withServerpod(');
  print("""
withServerpod('d', (s, e) {})
""");
  print(r'withServerpod(');
}
''';
      expect(untaggedWithServerpodCalls(source), isEmpty);
    });

    test('a tier tag inside a comment does not count', () {
      const source = '''
void main() {
  withServerpod('a', (s, e) {}, testGroupTagsOverride: [
    // 'db'
  ]);
}
''';
      expect(untaggedWithServerpodCalls(source), [2]);
    });

    test('a longer identifier is not a call', () {
      const source = 'void main() { notWithServerpod(1); withServerpods(2); }';
      expect(untaggedWithServerpodCalls(source), isEmpty);
    });

    test('parentheses inside strings do not unbalance a call', () {
      const source = '''
void main() {
  withServerpod('a ) (', (s, e) {}, testGroupTagsOverride: ['db']);
}
''';
      expect(untaggedWithServerpodCalls(source), isEmpty);
    });
  });

  test(
    'every withServerpod call in correlia_server/test carries a tier tag',
    () {
      final testDir = Directory(
        '${Directory.current.parent.path}/correlia_server/test',
      );
      final files = testDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => !f.path.contains('/test_tools/'))
          .toList();
      expect(files, isNotEmpty);

      final offenders = [
        for (final file in files)
          for (final line in untaggedWithServerpodCalls(
            file.readAsStringSync(),
          ))
            '${file.path}:$line',
      ];

      expect(offenders, isEmpty);
    },
  );
}

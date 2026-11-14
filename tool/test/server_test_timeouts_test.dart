import 'dart:io';

import 'package:correlia_tool/correlia_tool.dart';
import 'package:test/test.dart';

void main() {
  group('testsWithoutTimeout', () {
    test('a test without a timeout is reported with its line', () {
      const source = """
@Tags(['e2e'])
library;
void main() {
  test('missing', () {});
  test('also missing', () {});
}
""";
      expect(testsWithoutTimeout(source), [4, 5]);
    });

    test('literal and constant direct timeout arguments pass', () {
      const source = """
@Tags(['e2e'])
library;
void main() {
  test('literal', () {}, timeout: Timeout(Duration(minutes: 3)));
  test('constant', () {}, timeout: testTimeout);
}
""";
      expect(testsWithoutTimeout(source), isEmpty);
    });

    test('files without the e2e tag or ChildServer are ignored', () {
      const source = """
@Tags(['db'])
library;
void main() { test('no timeout needed', () {}); }
""";
      expect(testsWithoutTimeout(source), isEmpty);
    });

    test('naming ChildServer selects even a db test', () {
      const source = """
@Tags(['db'])
library;
void main() {
  test('child', () { ChildServer.start(); });
}
""";
      expect(testsWithoutTimeout(source), [4]);
    });

    test('comments and strings do not select files or contain calls', () {
      const ignored = """
// ChildServer and @Tags(['e2e'])
final text = 'ChildServer test( @Tags([e2e])';
void main() { test('ordinary', () {}); }
""";
      const selected = """
@Tags(['e2e'])
library;
// test('comment', () {});
final text = "test('string', () {})";
void main() { test('real', () {}); }
""";
      expect(testsWithoutTimeout(ignored), isEmpty);
      expect(testsWithoutTimeout(selected), [5]);
    });

    test('a library Timeout annotation covers the file', () {
      const source = """
@Timeout(Duration(minutes: 3))
@Tags(['e2e'])
library;
void main() { test('covered', () {}); }
""";
      expect(testsWithoutTimeout(source), isEmpty);
    });

    test('a non-library Timeout annotation does not cover the file', () {
      const source = """
@Tags(['e2e'])
library;
@Timeout(Duration(minutes: 3))
void helper() {}
void main() { test('uncovered', () {}); }
""";
      expect(testsWithoutTimeout(source), [5]);
    });

    test('group timeout and nested timeout are not direct arguments', () {
      const source = """
@Tags(['e2e'])
library;
void main() {
  group('group', () {
    test('nested', () { helper(timeout: value); });
  }, timeout: groupTimeout);
}
""";
      expect(testsWithoutTimeout(source), [5]);
    });

    test('longer identifiers and group calls are not tests', () {
      const source = """
@Tags(['e2e'])
library;
void main() {
  group('group', () {});
  customtest('not a test', () {});
}
""";
      expect(testsWithoutTimeout(source), isEmpty);
    });

    test('nested delimiters and strings do not hide direct arguments', () {
      const source = """
@Tags(['e2e'])
library;
void main() {
  test(') , timeout:', () { helper([1, 2], {'key': ')'}); },
      timeout: testTimeout);
  test('missing', () { helper(timeout: testTimeout); });
}
""";
      expect(testsWithoutTimeout(source), [6]);
    });
  });

  test('every server child test declares its own timeout', () {
    final testDir = Directory(
      '${Directory.current.parent.path}/correlia_server/test',
    );
    final files = testDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('_test.dart'))
        .toList();
    expect(files, isNotEmpty);

    final offenders = [
      for (final file in files)
        for (final line in testsWithoutTimeout(file.readAsStringSync()))
          '${file.path}:$line',
    ];
    expect(offenders, isEmpty);
  });
}

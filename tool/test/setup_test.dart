import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:correlia_tool/correlia_tool.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late File passwords;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('setup-test');
    passwords = File('${dir.path}/config/passwords.yaml');
    out = StringBuffer();
    err = StringBuffer();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<int?> runSetup() {
    var counter = 0;
    final runner = CommandRunner<int>('tool', 'test')
      ..addCommand(
        SetupCommand(
          passwordsFile: passwords,
          generatePassword: () => 'generated-secret-${counter++}',
          out: out,
          err: err,
        ),
      );
    return runner.run(['setup']);
  }

  test(
    'creates development and test sections when the file is missing',
    () async {
      final code = await runSetup();

      expect(code, 0, reason: err.toString());
      final text = passwords.readAsStringSync();
      expect(text, matches(RegExp(r'^development:\s*$', multiLine: true)));
      expect(text, matches(RegExp(r'^test:\s*$', multiLine: true)));
      expect(
        RegExp(r'database: "generated-secret-\d"').allMatches(text),
        hasLength(2),
        reason: 'development and test each get a database password',
      );
      expect(text, contains('generated-secret-0'));
      expect(text, contains('generated-secret-1'));
      expect(text, contains('serviceSecret:'));
      expect(out.toString(), isNot(contains('generated-secret')));
    },
  );

  test('never overwrites an existing complete file', () async {
    passwords.parent.createSync(recursive: true);
    const original =
        'development:\n  database: "mine"\ntest:\n  database: "x"\n';
    passwords.writeAsStringSync(original);

    final code = await runSetup();

    expect(code, 0, reason: err.toString());
    expect(passwords.readAsStringSync(), original);
  });

  test(
    'a file without a test section fails naming file and section, unchanged',
    () async {
      passwords.parent.createSync(recursive: true);
      const original = 'development:\n  database: "mine"\n';
      passwords.writeAsStringSync(original);

      final code = await runSetup();

      expect(code, isNot(0));
      expect(err.toString(), contains(passwords.path));
      expect(err.toString(), contains('test'));
      expect(passwords.readAsStringSync(), original);
    },
  );
}

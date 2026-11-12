import 'dart:convert';

import 'package:correlia_server/src/pipeline/pipeline.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  test('warning contains only source count and bounded name hashes', () {
    const source = '11111111-1111-4111-8111-111111111111';
    const names = ['credential-shaped-name', 'newField'];
    final tags = names
        .map(
          (name) =>
              sha256.convert(utf8.encode(name)).toString().substring(0, 12),
        )
        .join(',');
    final line = formatUnknownFieldWarning(source, names, 4);
    expect(
      line,
      'pipeline source=$source unknown_top_level_fields=6 tags=$tags',
    );
    for (final name in names) {
      expect(line, isNot(contains(name)));
    }
  });
}

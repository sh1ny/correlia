import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';

void main() {
  withServerpod(
    'Given the embedded test database',
    (sessionBuilder, _) {
      test('when running SELECT 1 then the database answers 1', () async {
        final session = sessionBuilder.build();

        final rows = await session.db.unsafeQuery('SELECT 1 AS one');

        expect(rows.single.toColumnMap()['one'], 1);
      });
    },
    testGroupTagsOverride: ['db'],
  );
}

@Tags(['plugin'])
library;

import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import 'fileless_worker_test.dart' show runSecretOutputTest;

void main() {
  withServerpod(
    'historical and shared output commitments',
    (builder, _) {
      test(
        'm1_plugin_work_drains_after_upgrade',
        () => runSecretOutputTest(builder.build(), upgrade: true),
      );
      test(
        'plugin_and_webhook_share_a_stored_reference',
        () => runSecretOutputTest(builder.build(), shared: true),
      );
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['plugin'],
  );
}

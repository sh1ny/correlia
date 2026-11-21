import 'package:serverpod/serverpod.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import '../support/icinga2_delivery.dart';
import '../support/icinga2_matrix.dart';
import '../support/icinga2_pipeline.dart';

/// Feeds what real Icinga 2 releases computed into the real pipeline, where a
/// decode alone cannot show the outcome: lateness and alert creation are the
/// pipeline's, not the decoder's.
void main() {
  final pairs = committedStatement();

  withServerpod(
    'Icinga2 captures through the real pipeline',
    (builder, _) {
      late Session s;

      setUp(() async {
        s = builder.build();
        await clearPipelineTables(s);
        await publishIcinga2Config(s);
      });

      for (final pair in pairs) {
        test(
          'initialized_state_change_time_of_a_runtime_created_host '
          '(${pair.name})',
          () async {
            const file =
                'initialized_state_change_time_of_a_runtime_created_host';
            final console = Capture(pair).of(file, 'console').single;
            final input = console.json['input']! as Map<String, Object?>;
            final now = input['now']! as int;
            final result = (console.json['result']! as num).toInt();
            final observed = DateTime.fromMillisecondsSinceEpoch(
              now * 1000,
              isUtc: true,
            );
            final created = hostDelivery(
              set: {
                'host': 'fp-runtime',
                'last_state_change': '$result.000000',
                'notification_time': '$now.000000',
              },
            );
            await deliverIcinga2(s, created, observed);
            final event = await storedEvent(s, eventIdOf(created));
            expect(event['_disposition'], 'ready');
            final alert = await theAlert(s);
            expect(alert['status'], 'firing');

            // The stale time the helper replaced would have been late, so
            // the check above tells the two apart.
            final expression = console.json['expression']! as String;
            final stale = RegExp(
              r'[{,] last_state_change = ([0-9]+)',
            ).firstMatch(expression)![1]!;
            final old = hostDelivery(
              set: {
                'host': 'fp-runtime-stale',
                'last_state_change': '$stale.000000',
                'notification_time': '$now.000000',
              },
            );
            await deliverIcinga2(s, old, observed);
            expect(
              (await storedEvent(s, eventIdOf(old)))['_disposition'],
              'late',
            );
            expect(await countRows(s, 'alerts'), 1);
          },
        );
      }
    },
    rollbackDatabase: RollbackDatabase.disabled,
    testGroupTagsOverride: ['db'],
  );
}

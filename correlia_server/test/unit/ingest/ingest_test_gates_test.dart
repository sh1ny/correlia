import 'package:correlia_server/src/ingest/ingest_test_gates.dart';
import 'package:test/test.dart';

void main() {
  test('production cannot activate ingest crash gates', () {
    final gates = IngestTestGates.fromEnvironment('production', {
      'CORRELIA_TEST_PIPELINE_PIN_GATE': '/unused/pin',
      'CORRELIA_TEST_RELAY_ACQUIRE_GATE': '/unused/relay',
    });
    expect(gates.pipelinePin, isNull);
    expect(gates.relayAcquire, isNull);
  });
  test('test run mode accepts independently named gates', () {
    final gates = IngestTestGates.fromEnvironment('test', {
      'CORRELIA_TEST_PIPELINE_PIN_GATE': '/unused/pin',
      'CORRELIA_TEST_RELAY_ACQUIRE_GATE': '/unused/relay',
    });
    expect(gates.pipelinePin, '/unused/pin');
    expect(gates.relayAcquire, '/unused/relay');
  });
}

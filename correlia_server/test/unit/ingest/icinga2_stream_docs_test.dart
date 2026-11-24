import 'dart:io';

import 'package:correlia_server/src/ingest/bootstrap.dart'
    show IcingaStreamOptions;
import 'package:correlia_server/src/ingest/icinga2/stream/batcher.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/read_timing.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/subscription.dart';
import 'package:correlia_server/src/ingest/icinga2/stream/sync_progress.dart'
    show streamSyncRetentionDays, streamSyncSpacingSeconds;
import 'package:correlia_server/src/ingest/icinga2/stream/sync_reader.dart'
    show streamSyncReadDeadline;
import 'package:correlia_server/src/pipeline/pipeline.dart'
    show evidenceLatenessHorizon, pipelineRowDeadline, skewAllowance;
import 'package:test/test.dart';

String _section(String headingPattern) {
  final lines = File('../docs/ingest-pipeline.md').readAsLinesSync();
  final heading = RegExp(
    '^(#{2,6})\\s+.*(?:$headingPattern)',
    caseSensitive: false,
  );
  final start = lines.indexWhere((line) => heading.hasMatch(line));
  expect(start, isNonNegative, reason: 'Missing section: $headingPattern');
  final level = heading.firstMatch(lines[start])!.group(1)!.length;
  final nextHeading = RegExp('^#{1,$level}\\s+');
  return lines
      .skip(start + 1)
      .takeWhile((line) => !nextHeading.hasMatch(line))
      .join('\n');
}

void _has(String text, String pattern, String reason) {
  expect(
    text,
    matches(RegExp(pattern, caseSensitive: false, dotAll: true)),
    reason: reason,
  );
}

void _tableValue(String text, String label, String value, String reason) {
  final rows = text
      .split('\n')
      .where((line) => line.trimLeft().startsWith('|'));
  expect(
    rows.any(
      (row) =>
          RegExp(label, caseSensitive: false).hasMatch(row) &&
          RegExp(value, caseSensitive: false).hasMatch(row),
    ),
    isTrue,
    reason: reason,
  );
}

String _bytes(int value) {
  final alternatives = <String>['$value'];
  if (value % 1024 == 0) alternatives.add('${value ~/ 1024}\\s*KiB');
  if (value % (1024 * 1024) == 0) {
    alternatives.add('${value ~/ (1024 * 1024)}\\s*MiB');
  }
  return '(?:${alternatives.join('|')})';
}

String _number(String value) =>
    value.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',?');

void _tableNumbers(
  String text,
  String label,
  List<String> values,
  String reason,
) {
  final rows = text
      .split('\n')
      .where((line) => line.trimLeft().startsWith('|'));
  expect(
    rows.any(
      (row) =>
          RegExp(label, caseSensitive: false).hasMatch(row) &&
          values.every(
            (value) => RegExp('\\b${_number(value)}\\b').hasMatch(row),
          ),
    ),
    isTrue,
    reason: reason,
  );
}

void main() {
  test('residual_risk_documented', () {
    final limits = _section('Event Streams.*limits|limits.*Event Streams');
    _has(limits, r'(Icinga\s*2.*queue|queue.*Icinga\s*2)', 'Upstream queue');
    _has(
      limits,
      r'(queue.{0,180}(unbounded|not bound|cannot bound|does not bound)|(unbounded|not bound|cannot bound|does not bound).{0,180}queue)',
      'Unbounded upstream memory risk',
    );
    _has(limits, r'(stay|remain).{0,100}behind', 'Consumer can remain behind');
    _has(
      limits,
      r'(input|arrival).{0,100}(match|equal).{0,100}drain|drain.{0,100}(match|equal).{0,100}(input|arrival)',
      'Input can match drain',
    );
    _has(
      limits,
      r'\b[1-9][0-9,]*(?:\.[0-9]+)?\s*(?:events\s*(?:/|per\s+)\s*(?:s|sec(?:ond)?s?))\b',
      'Measured drain rate in events per second',
    );
    _has(
      limits,
      r'(?:last|final).{0,30}5\s*(?:minutes|min\b)',
      'Measurement interval is the final five minutes',
    );
  });

  test('setup_items_present', () {
    final setup = _section('Event Streams.*setup|setup.*Event Streams');
    for (final type in streamTypes) {
      expect(setup, contains('events/$type'), reason: 'Event grant for $type');
    }
    for (final grant in ['objects/query/Host', 'objects/query/Service']) {
      expect(setup, contains(grant), reason: 'Object query grant');
    }
    final example = File(
      '../contrib/icinga2/event-streams/correlia-stream-api-user.conf',
    ).readAsStringSync();
    final permissions = RegExp(
      r'permissions\s*=\s*\[([^\]]*)\]',
    ).firstMatch(example)!.group(1)!;
    expect(
      RegExp(r'"([^"]+)"').allMatches(permissions).map((m) => m.group(1)),
      unorderedEquals([
        for (final type in streamTypes) 'events/$type',
        'objects/query/Host',
        'objects/query/Service',
      ]),
    );
    _has(setup, r'\bCA\b', 'Configured CA');
    _has(
      setup,
      r'(one|single|1).{0,60}(Icinga|instance).{0,80}(source|stream)|(source|stream).{0,80}(one|single|1).{0,60}(Icinga|instance)',
      'One instance per source',
    );
    _has(setup, r'(all|every).{0,50}(role|process)', 'Upgrade every role');
    _has(
      setup,
      r'(upgrad|new release).{0,120}(before|prior).{0,100}(publish|publication|password|stream source)',
      'Upgrade before first publication',
    );
    _has(
      setup,
      r'(no|not|never|cannot|must not).{0,80}(older|old release|old process)|(?:older|old release|old process).{0,80}(not|cannot|refus|unsupported)',
      'No older processes after cutover',
    );
    _has(
      setup,
      r'(older|old).{0,100}worker.{0,150}(webhook|decod)|(webhook|decod).{0,150}(older|old).{0,100}worker',
      'Older worker cannot decode stream rows',
    );
    _has(
      setup,
      r'(older|old).{0,100}(publisher|publication|release).{0,150}(reuse|refus|database|schema)',
      'Older publisher and database cutover boundary',
    );
    _has(
      setup,
      r'(local|development|test).{0,100}status|status.{0,100}(local|development|test)',
      'Local development/test status access',
    );
    _has(setup, r'404', 'Object-query 404');
    _has(
      setup,
      r'(404.{0,180}(fail|error)|(fail|error).{0,180}404)',
      '404 fails sync',
    );
    _has(
      setup,
      r'(empty|no objects).{0,150}(404|fail)|(404|fail).{0,150}(empty|no objects)',
      'Even an empty collection can return 404',
    );
  });

  test('limits_match_the_code', () {
    final limits = _section('Event Streams.*limits|limits.*Event Streams');
    _tableValue(limits, r'line', _bytes(streamLineLimit), 'Line limit');
    _tableValue(
      limits,
      r'(encoded|row|batch)',
      _bytes(streamEncodedRowBudget),
      'Encoded row budget',
    );
    _tableValue(limits, r'fanout', _bytes(streamFanoutBudget), 'Fanout budget');
    _tableValue(
      limits,
      r'(item|batch|row)',
      '\\b$streamItemsPerRow\\b',
      'Items per row',
    );
    _tableValue(
      limits,
      r'flush',
      '\\b${streamFlushInterval.inSeconds}\\s*(?:s|sec(?:ond)?s?)\\b',
      'Flush interval',
    );
    _tableValue(
      limits,
      r'(stall|block|backpressure)',
      '\\b${readerBlockedLimit.inSeconds}\\s*(?:s|sec(?:ond)?s?)\\b',
      'Reader stall limit',
    );
    _tableValue(
      limits,
      r'(lag|excess)',
      '\\b${readerLagExcess.inSeconds}\\s*(?:s|sec(?:ond)?s?)\\b',
      'Excess lag threshold',
    );
    const interval = IcingaStreamOptions.syncIntervalSeconds;
    _tableNumbers(
      limits,
      r'sync.interval',
      ['${interval.standard}', '${interval.minimum}', '${interval.maximum}'],
      'Sync interval default and range in seconds',
    );
    const pending = IcingaStreamOptions.pendingRows;
    _tableNumbers(
      limits,
      r'max.pending.rows',
      ['${pending.standard}', '${pending.minimum}', '${pending.maximum}'],
      'Pending row default and range',
    );
    _tableNumbers(
      limits,
      r'(sync|read).*(deadline|timeout)',
      ['${streamSyncReadDeadline.inMinutes}'],
      'Sync deadline in minutes',
    );
    _tableNumbers(limits, r'lateness', [
      '${evidenceLatenessHorizon.inDays}',
    ], 'Lateness horizon in days');
    _tableNumbers(
      limits,
      r'sync start spacing',
      ['$streamSyncSpacingSeconds'],
      'Minimum sync spacing in seconds',
    );
    _tableNumbers(
      limits,
      r'sync progress retention',
      ['$streamSyncRetentionDays'],
      'Sync progress retention in days',
    );
    _tableNumbers(
      limits,
      r'pipeline row deadline',
      ['${pipelineRowDeadline.inSeconds}'],
      'Pipeline row deadline in seconds',
    );
    _tableValue(
      limits,
      r'(lag|excess)',
      '\\b${readerLagWindow.inSeconds}\\s*(?:s|sec(?:ond)?s?)\\b',
      'Excess lag window',
    );
    _tableValue(
      limits,
      r'(skew|clock)',
      '\\b${skewAllowance.inMinutes}\\s*(?:m|min(?:ute)?s?)\\b',
      'Clock skew allowance',
    );
    _has(limits, r'(late|lateness)', 'Lateness horizon');
    _has(
      limits,
      r'(equal|same).{0,50}start',
      'Equal starts outside convergence',
    );
    for (final loss in ['acknowledg', 'downtime', 'flapping', 'intermediate']) {
      _has(limits, loss, 'Gap can lose $loss');
    }
    _has(
      limits,
      r'(sync|reconcil).{0,100}(only|current).{0,50}(current|state)|(only|current).{0,50}state.{0,100}(sync|reconcil)',
      'Sync repairs current state only',
    );
    _has(
      limits,
      r'(remov|delet).{0,100}(object|Icinga).{0,100}alert|(object|Icinga).{0,100}(remov|delet).{0,100}alert',
      'Removed object keeps its alert',
    );
    _has(
      limits,
      r'(kept|retain|failed).{0,100}rows?.{0,100}(grow|accumulat|cap|bound)',
      'Retained-row growth',
    );
  });
}

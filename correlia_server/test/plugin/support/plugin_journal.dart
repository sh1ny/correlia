import 'dart:convert';
import 'dart:io';

import 'plugin_fixture_suite.dart';

/// One accepted event recorded by the Go receiver.
///
/// The journal stores the canonical payload digest rather than a second copy
/// of the canonical bytes.
final class PluginJournalRecord {
  /// Creates a journal record.
  PluginJournalRecord({
    required this.id,
    required this.sha256,
    required this.epoch,
    required this.sequence,
  });

  /// The canonical event id.
  final String id;

  /// The lowercase hexadecimal SHA-256 digest of the canonical JSON bytes.
  final String sha256;

  /// The connection epoch that carried the event.
  final String epoch;

  /// The batch sequence within the epoch.
  final int sequence;
}

/// Reads and validates the receiver's acceptance journal.
///
/// A malformed or torn trailing line is rejected instead of being silently
/// ignored. Duplicate event ids remain visible so reconciliation can apply
/// the at-least-once accounting rules.
List<PluginJournalRecord> readPluginJournal(File file) {
  final bytes = file.readAsBytesSync();
  if (bytes.length > pluginJournalMaxBytes) {
    throw StateError('plugin journal exceeds its 32 MiB bound');
  }
  if (bytes.isEmpty) return const <PluginJournalRecord>[];

  final content = utf8.decode(bytes, allowMalformed: false);
  if (!content.endsWith('\n')) {
    throw const FormatException('plugin journal ends with a torn record');
  }
  final lines = content.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();

  return List<PluginJournalRecord>.unmodifiable(
    lines.map((line) => _decodeRecord(line)),
  );
}

PluginJournalRecord _decodeRecord(String line) {
  final value = jsonDecode(line);
  if (value is! Map<String, Object?>) {
    throw const FormatException('plugin journal record is not an object');
  }
  final id = value['id'];
  final digest = value['sha256'];
  final epoch = value['epoch'];
  final sequence = value['sequence'];
  if (id is! String ||
      digest is! String ||
      epoch is! String ||
      sequence is! int) {
    throw const FormatException('plugin journal record is incomplete');
  }
  if (digest.length != 64) {
    throw const FormatException('plugin journal digest is not SHA-256 hex');
  }
  return PluginJournalRecord(
    id: id,
    sha256: digest,
    epoch: epoch,
    sequence: sequence,
  );
}

import 'dart:convert';
import 'dart:io';

import 'plugin_fixture_suite.dart';
import 'plugin_journal.dart';

/// Writes a journal record in the same newline-delimited JSON shape as the
/// Go receiver.
///
/// This is intended for independent observer checks, not for producing
/// acceptance evidence about the receiver itself.
void appendPluginJournalRecord(
  File file,
  PluginJournalRecord record,
) {
  final line = jsonEncode(<String, Object>{
    'id': record.id,
    'sha256': record.sha256,
    'epoch': record.epoch,
    'sequence': record.sequence,
  });
  file.writeAsStringSync(
    '$line\n',
    mode: FileMode.append,
    flush: true,
  );
  final size = file.lengthSync();
  if (size > pluginJournalMaxBytes) {
    throw StateError('plugin journal exceeds its 32 MiB bound');
  }
}

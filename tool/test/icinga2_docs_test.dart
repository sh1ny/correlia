import 'dart:io';

import 'package:test/test.dart';

File get _docFile =>
    File('${Directory.current.parent.path}/docs/ingest-pipeline.md');

/// Returns the text of the level-two section titled [heading], up to the next
/// level-two heading, with every run of whitespace as one space, so a phrase
/// matches across line breaks. Fails when the section is missing.
String _section(String heading) {
  final lines = _docFile.readAsLinesSync();
  final start = lines.indexOf('## $heading');
  if (start < 0) {
    fail('docs/ingest-pipeline.md has no "## $heading" section');
  }
  final rest = lines.skip(start + 1);
  return [
    lines[start],
    ...rest.takeWhile((line) => !line.startsWith('## ')),
  ].join('\n').replaceAll(RegExp(r'\s+'), ' ');
}

/// The Icinga2 document, mapping and convergence section.
String get _mapping => _section('Icinga2 webhook document and mapping');

/// The Icinga2 sender setup section.
String get _setup => _section('Icinga2 sender setup');

/// Every Icinga2 section together.
String get _icinga2 => '$_mapping\n$_setup';

/// Expects [text] to contain every phrase in [phrases].
void _expectAll(String text, List<Pattern> phrases) {
  for (final phrase in phrases) {
    expect(text, contains(phrase), reason: 'missing: $phrase');
  }
}

void main() {
  test('documentation_names_the_limits', () {
    _expectAll(_icinga2, [
      'Icinga 2 does not retry a failed',
      'SOFT',
      'downtime, acknowledgement, dependencies or flapping',
      '## Convergence contract',
      'The upgrade is offline',
      '`api`, `worker` and `all`',
      'decodes every row as Alertmanager',
    ]);
  });

  test('documentation_names_the_state_change_time_limits', () {
    _expectAll(_icinga2, [
      '`1 <= seconds < 2^32`',
      'after 2106',
      'first problem of a new object',
      'one event per distinct, eligible HARD time',
    ]);
  });

  test('documentation_names_the_downtime_limits', () {
    _expectAll(_icinga2, [
      'cannot tell a cancelled downtime from an expired one',
      'never triggered sends no notification',
    ]);
  });

  test('documentation_names_the_text_exposure', () {
    _expectAll(_setup, [
      'process list',
      'failed command',
      'Notice',
      'launch log',
      'never a credential',
    ]);
  });

  test('documentation_names_the_setup_constraints', () {
    _expectAll(_setup, [
      '`LD_PRELOAD`',
      '256 KiB',
      '`ARG_MAX`',
      'writable only by root or the Icinga 2 user',
      'readable only by the Icinga 2 user',
      '`invalid_name`',
      'two signed requests per source',
      'bearer',
    ]);
  });
}

/// The logic of `tool/simulate.dart`: argument handling and the trace output of
/// the rule simulator command line (task 7.2).
///
/// The simulator call is injected, so the fast tests drive [runSimulate] with a
/// fake and the thin `main` binds it to the generated client.
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:correlia_client/correlia_client.dart';

/// The exit code of a failed simulation or a failed call.
const simulationFailedExit = 1;

/// The exit code of a command-line usage error.
const usageExit = 64;

/// The default server URL.
const defaultServer = 'http://localhost:8080/';

/// The signature of `ruleSimulator.simulate` on the generated client.
typedef SimulateCall =
    Future<RuleSimulationResult> Function({
      String? eventJson,
      String? eventId,
      String? observedAt,
      String? disposition,
      String? draftMatcher,
    });

ArgParser _parser() => ArgParser()
  ..addOption('event', help: 'File with a pasted CloudEvent JSON document.')
  ..addOption('event-id', help: 'ID of a stored event.')
  ..addOption(
    'observed-at',
    help: 'observed_at of the stored event, passed through as typed.',
  )
  ..addOption(
    'disposition',
    allowed: ['ready', 'late', 'future_dated'],
    help: 'Disposition of the stored event, when it has one.',
  )
  ..addOption('draft', help: 'File with a draft matcher section as JSON.')
  ..addOption('server', defaultsTo: defaultServer, help: 'Server URL.')
  ..addFlag('json', negatable: false, help: 'Print the result as JSON.')
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this usage.');

/// Reads the `--server` option from [args], or the default when [args] do not
/// parse (the usage error is reported by [runSimulate]). A valid URL comes
/// back in normal form, its scheme and host in lowercase, since the generated
/// client checks for a lowercase `http://` or `https://` prefix.
String serverOption(List<String> args) {
  final String server;
  try {
    server = _parser().parse(args).option('server') ?? defaultServer;
  } on FormatException {
    return defaultServer;
  }
  return isServerUrl(server) ? Uri.parse(server).toString() : server;
}

/// The most bytes of a `--event` file the CLI sends: the server's CloudEvent
/// envelope bound. A larger file fails locally with `too_large`.
const eventFileLimit = 262144;

/// The most bytes of a `--draft` file the CLI sends: the server's draft bound.
const draftFileLimit = 64 * 1024;

/// Reads at most [maxBytes] plus one byte of [path], so a file over a limit is
/// known to be too large without reading all of it.
List<int> _readBounded(String path, int maxBytes) {
  final file = File(path).openSync();
  try {
    return file.readSync(maxBytes + 1);
  } finally {
    file.closeSync();
  }
}

/// Escapes DEL and the C1 controls in the JSON text [json] as `\u00XX`.
///
/// JSON allows them raw, but a terminal acts on them. Outside strings JSON
/// holds only ASCII, so every such character is inside a string, where the
/// escape decodes to the same value.
String escapeJsonControls(String json) => json.replaceAllMapped(
  RegExp(r'[\x7F-\x9F]'),
  (match) => '\\u${match[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}',
);

/// Whether [server] is an absolute `http` or `https` URL with a host and no
/// query or fragment. The generated client appends the endpoint path to the
/// URL as given, so a query or fragment would swallow that path.
bool isServerUrl(String server) => switch (Uri.tryParse(server)) {
  Uri(
    scheme: 'http' || 'https',
    host: final host,
    hasQuery: false,
    hasFragment: false,
  )
      when host.isNotEmpty =>
    true,
  _ => false,
};

/// Runs the simulator command line and returns its exit code.
///
/// Reads the pasted event and draft files through [readFile] (default: the
/// file system), at most their limit plus one byte each; a file over
/// [eventFileLimit] or [draftFileLimit] fails locally with `too_large` on
/// `eventJson` or `draftMatcher`, as the server would. It then calls
/// [simulate], and writes the trace to [out] or, with
/// `--json`, the result document. Errors go to [err]: `error: <code>` and
/// `field: <field>`, exit [simulationFailedExit]; a usage error prints the
/// usage and exits [usageExit]. The operator's text, `observed_at` included,
/// reaches the simulator unchanged.
Future<int> runSimulate(
  List<String> args,
  SimulateCall simulate,
  StringSink out,
  StringSink err, {
  List<int> Function(String path, int maxBytes)? readFile,
}) async {
  final parser = _parser();
  int usage(String message) {
    // The message can hold an argument or a file path the caller typed.
    _EscapingSink(err).writeln(message);
    err
      ..writeln('Usage: dart run tool/simulate.dart [options]')
      ..writeln(parser.usage);
    return usageExit;
  }

  final ArgResults results;
  try {
    results = parser.parse(args);
  } on FormatException catch (e) {
    return usage(e.message);
  }
  if (results.flag('help')) {
    out
      ..writeln('Usage: dart run tool/simulate.dart [options]')
      ..writeln(parser.usage);
    return 0;
  }
  if (results.rest.isNotEmpty) {
    return usage('Unexpected argument: ${results.rest.first}');
  }
  if (!isServerUrl(results.option('server') ?? defaultServer)) {
    return usage(
      '--server must be an http:// or https:// URL with no query or fragment.',
    );
  }
  final eventFile = results.option('event');
  final eventId = results.option('event-id');
  final observedAt = results.option('observed-at');
  if ((eventFile == null) == (eventId == null)) {
    return usage('Give exactly one of --event and --event-id.');
  }
  if (eventId != null && observedAt == null) {
    return usage('--event-id needs --observed-at.');
  }
  if (eventFile != null && observedAt != null) {
    return usage('--observed-at belongs to --event-id.');
  }
  if (eventFile != null && results.option('disposition') != null) {
    return usage('--disposition belongs to --event-id.');
  }
  final read = readFile ?? _readBounded;
  final draftFile = results.option('draft');
  final String? eventJson;
  final String? draft;
  String? tooLarge;
  String? load(String? path, String field, int limit) {
    if (path == null || tooLarge != null) return null;
    final bytes = read(path, limit);
    if (bytes.length > limit) {
      tooLarge = field;
      return null;
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw FileSystemException('not UTF-8 text', path);
    }
  }

  try {
    eventJson = load(eventFile, 'eventJson', eventFileLimit);
    draft = load(draftFile, 'draftMatcher', draftFileLimit);
  } on FileSystemException catch (e) {
    return usage('Cannot read ${e.path ?? 'a file'}: ${e.message}');
  }
  if (tooLarge case final field?) {
    err
      ..writeln('error: too_large')
      ..writeln('field: $field');
    return simulationFailedExit;
  }

  final RuleSimulationResult result;
  try {
    result = await simulate(
      eventJson: eventJson,
      eventId: eventId,
      observedAt: observedAt,
      disposition: results.option('disposition'),
      draftMatcher: draft,
    );
  } on Exception catch (e) {
    _EscapingSink(err).writeln('error: the simulate call failed: $e');
    return simulationFailedExit;
  }
  if (results.flag('json')) {
    out.writeln(
      escapeJsonControls(
        const JsonEncoder.withIndent('  ').convert(result.toJson()),
      ),
    );
  }
  if (result.error case final error?) {
    // The field can name an attribute of the submitted event, so it is
    // escaped like the trace.
    final diagnostics = _EscapingSink(err);
    diagnostics.writeln('error: ${error.code}');
    if (error.field case final field?) diagnostics.writeln('field: $field');
    if (error.missingOutputId case final output?) {
      diagnostics.writeln('output: $output');
    }
    return simulationFailedExit;
  }
  if (!results.flag('json')) writeTrace(result, out);
  return 0;
}

/// Writes the readable form of a successful [result] to [out].
///
/// Labels, link text, action details and other values come from events and
/// may hold newlines or terminal control characters, so every line is
/// escaped: a value can neither start a new trace line nor drive the terminal.
void writeTrace(RuleSimulationResult result, StringSink sink) {
  final out = _EscapingSink(sink);
  final snapshot = switch ((result.snapshotId, result.snapshotRevision)) {
    (final id?, final revision?) => ' (snapshot $id, revision $revision)',
    (final id?, null) => ' (snapshot $id)',
    _ => '',
  };
  out.writeln('rules: ${result.ruleSource}$snapshot');
  if (result.noRulesActive) out.writeln('no rules are active');
  for (final rule in result.trace) {
    final code = rule.failureCode == null ? '' : ' (${rule.failureCode})';
    out.writeln('rule ${rule.ruleId}: ${rule.outcome}$code');
    final depths = <int>[];
    for (final condition in rule.conditions) {
      final depth = switch (condition.parentIndex) {
        final parent? when parent >= 0 && parent < depths.length =>
          depths[parent] + 1,
        _ => 0,
      };
      depths.add(depth);
      final subject = switch ((condition.field, condition.op)) {
        (null, null) => condition.kind,
        (final field, final op) => [?field, ?op].join(' '),
      };
      final reason = condition.failureCode == null
          ? ''
          : ' (${condition.failureCode})';
      out.writeln(
        '  ${'  ' * (depth + 1)}$subject: ${condition.outcome}$reason',
      );
    }
    for (final action in rule.actions) {
      final applied = action.applied ? 'applied' : 'not applied';
      out.writeln(
        '  action ${action.index} ${action.type} ${action.detail}: '
        '${action.effect} ($applied)',
      );
    }
  }
  out.writeln('kind: ${result.eventKind}');
  if (result.noiseClassHint case final hint?) {
    out.writeln('noise class hint: $hint');
  }
  _section(out, 'final labels', [
    for (final MapEntry(:key, :value) in result.finalLabels.entries)
      '$key=$value (${result.finalLabelOrigins[key] ?? 'unknown origin'})',
  ]);
  _section(out, 'links', [
    for (final link in result.finalLinks)
      '${link.relation} ${link.href}${link.text == null ? '' : ' "${link.text}"'}',
  ]);
  out.writeln('severity: ${result.finalSeverity}');
  _section(out, 'baseline routes', result.baselineRoutes);
  _section(out, 'added routes', [
    for (final route in result.addedRoutes) '$route (hypothetical)',
  ]);
  out.writeln('routes: ${result.routeNote}');
  if (result.sourceAbsent) out.writeln('the event source is absent');
  if (result.baselineOverFanout) {
    out.writeln('baseline routes over the fan-out');
  }
  for (final note in result.notes) {
    out.writeln('note: $note');
  }
  if (result.storedSnapshotId case final id?) {
    out.writeln('stored snapshot: $id');
  }
  if (result.storedLabels case final labels?) {
    final origins = result.storedLabelOrigins ?? const {};
    _section(out, 'stored labels', [
      for (final MapEntry(:key, :value) in labels.entries)
        // A label with no explicit origin came from the source, as in the
        // simulated labels.
        '$key=$value (${origins[key] ?? 'source'})',
    ]);
  }
  // A pasted event has no stored errors to show, as opposed to none.
  if (result.storedEnrichmentErrors case final errors?) {
    _section(out, 'stored enrichment errors', [
      for (final e in errors) '${e.stage} ${e.code}: ${e.message}',
    ]);
  }
  if (result.storedBudgetNote case final note?) {
    out.writeln('stored budget note: $note');
  }
}

void _section(_EscapingSink out, String title, List<String> lines) {
  if (lines.isEmpty) {
    out.writeln('$title: none');
    return;
  }
  out.writeln('$title:');
  for (final line in lines) {
    out.writeln('  $line');
  }
}

/// Writes each line with its control characters escaped.
///
/// `\n`, `\r` and `\t` keep their usual escapes; every other C0 or C1 control
/// character and DEL is written as `\u{hex}`. Only [writeln] ends a line.
final class _EscapingSink {
  _EscapingSink(this._sink);

  final StringSink _sink;

  void writeln(String line) {
    final escaped = StringBuffer();
    for (final rune in line.runes) {
      escaped.write(switch (rune) {
        0x0a => r'\n',
        0x0d => r'\r',
        0x09 => r'\t',
        < 0x20 ||
        0x7f ||
        (>= 0x80 && < 0xa0) => '\\u{${rune.toRadixString(16)}}',
        _ => String.fromCharCode(rune),
      });
    }
    _sink.writeln(escaped);
  }
}

import '../event/canonical_event.dart';
import '../event/cloud_event.dart';
import '../event/validation.dart';
import '../generated/protocol.dart' hide ConditionTrace;
import '../generated/protocol.dart' as wire show ConditionTrace;
import '../matcher/matcher_condition.dart';
import '../matcher/matcher_document.dart';
import '../matcher/matcher_evaluation.dart';
import '../matcher/matcher_regex_worker.dart';
import '../pipeline/pipeline.dart' show pipelineFanoutLimit;

/// The rule outcome of a rule whose condition matched and whose patch applied.
const ruleOutcomeMatched = 'matched';

/// The rule outcome of a rule whose condition did not match.
const ruleOutcomeNotMatched = 'not matched';

/// The rule outcome of a rule that failed; [RuleTrace.failureCode] has the code.
const ruleOutcomeFailed = 'failed';

/// The rule outcome of a rule the simulation never evaluated.
const ruleOutcomeNotAttempted = 'not attempted';

/// The statement that added routes are not checked for delivery eligibility.
const simulationRouteNote =
    'Routes are hypothetical: delivery eligibility is not evaluated.';

/// The statement that a stored event's pipeline run shared its budgets.
const simulationStoredBudgetNote =
    "The pipeline shared its regex and time budgets across the whole raw row, "
    'so rules may have been stopped for this event without a recorded error. '
    'This simulation used fresh budgets.';

/// The optional matcher time budget of a simulation: the pipeline's row
/// deadline less the 2 s it keeps back for committing.
const simulationOptionalBudget = Duration(seconds: 8);

/// Where the simulated rules came from.
enum SimulationRuleSource {
  /// The active snapshot's matcher section.
  active,

  /// A draft matcher section supplied with the request.
  draft,
}

/// What the pipeline stored for the event being simulated.
final class StoredEventInfo {
  const StoredEventInfo({
    required this.snapshotId,
    required this.labels,
    required this.labelsOrigin,
    required this.enrichmentErrors,
  });

  /// Reads the stored values from the stored event payload.
  factory StoredEventInfo.fromEvent(
    CanonicalEvent stored, {
    required String snapshotId,
  }) => StoredEventInfo(
    snapshotId: snapshotId,
    labels: stored.labels,
    labelsOrigin: stored.labelsOrigin,
    enrichmentErrors: stored.pipeline.enrichmentErrors,
  );

  /// The snapshot the event was processed under.
  final String snapshotId;

  /// The stored event's labels.
  final Map<String, String> labels;

  /// The stored event's label origins.
  final Map<String, String> labelsOrigin;

  /// The stored event's `enrichment_errors`.
  final List<EventEnrichmentError> enrichmentErrors;
}

/// Everything about a simulation that is not the event or the rules.
final class SimulationContext {
  SimulationContext({
    required this.ruleSource,
    this.snapshotId,
    this.snapshotRevision,
    this.baselineRoutes = const [],
    this.sourceAbsent = false,
    this.stored,
  });

  /// Whether the rules are the active snapshot's or a draft.
  final SimulationRuleSource ruleSource;

  /// The active snapshot's ID, or `null` when none is active.
  final String? snapshotId;

  /// The active snapshot's revision, or `null` when none is active.
  final int? snapshotRevision;

  /// The route IDs of the event's source in the active snapshot.
  final List<String> baselineRoutes;

  /// Whether the event's source is missing from the active snapshot.
  final bool sourceAbsent;

  /// Stored-event data, or `null` for a pasted event.
  final StoredEventInfo? stored;
}

final class _Cutoff implements Exception {
  const _Cutoff();
}

/// The result that carries only [error].
/// The entries of [labels] in its order, as a result carries them.
List<SimulatedLabel> labelEntries(Map<String, String> labels) => [
  for (final MapEntry(:key, :value) in labels.entries)
    SimulatedLabel(key: key, value: value),
];

/// The label lists of a [RuleSimulationResult] as maps.
extension RuleSimulationLabels on RuleSimulationResult {
  /// [finalLabels] as a map.
  Map<String, String> get finalLabelMap => _map(finalLabels);

  /// [finalLabelOrigins] as a map.
  Map<String, String> get finalLabelOriginMap => _map(finalLabelOrigins);

  /// [storedLabels] as a map, `null` when the result has none.
  Map<String, String>? get storedLabelMap =>
      storedLabels == null ? null : _map(storedLabels!);

  /// [storedLabelOrigins] as a map, `null` when the result has none.
  Map<String, String>? get storedLabelOriginMap =>
      storedLabelOrigins == null ? null : _map(storedLabelOrigins!);
}

Map<String, String> _map(List<SimulatedLabel> labels) => {
  for (final label in labels) label.key: label.value,
};

RuleSimulationResult simulationFailure(
  SimulationError error, {
  SimulationRuleSource ruleSource = SimulationRuleSource.active,
}) => RuleSimulationResult(
  error: error,
  ruleSource: ruleSource.name,
  noRulesActive: false,
  eventKind: '',
  trace: [],
  finalLabels: [],
  finalLabelOrigins: [],
  finalLinks: [],
  finalSeverity: '',
  baselineRoutes: [],
  addedRoutes: [],
  routeNote: simulationRouteNote,
  sourceAbsent: false,
  baselineOverFanout: false,
  notes: [],
);

/// Simulates [event] against [document] with budgets that start now.
///
/// Creates a regex worker unless [worker] is given, bounds optional work by
/// [simulationOptionalBudget] on [elapsed] (a stopwatch by default) and closes
/// a worker it created.
Future<RuleSimulationResult> simulateWithFreshBudgets({
  required CanonicalEvent event,
  required MatcherDocument document,
  required SimulationContext context,
  MatcherRegexWorker? worker,
  Duration Function()? elapsed,
  Duration optionalBudget = simulationOptionalBudget,
}) async {
  final watch = Stopwatch()..start();
  final now = elapsed ?? () => watch.elapsed;
  final regex = worker ?? MatcherRegexWorker();
  try {
    Duration remaining() => optionalBudget - now();
    final row = regex.newRow(remaining);
    return await simulateRules(
      event: event,
      document: document,
      context: context,
      regexTest: row.matches,
      capture: row.capture,
      optionalRemaining: remaining,
    );
  } finally {
    if (worker == null) regex.close();
  }
}

/// Runs [document]'s rules over the one [event] and reports every decision.
///
/// Rules run in order through [applyMatcherRule], the pipeline's own rule
/// code, with [regexTest] and [capture] standing for a fresh row's regex
/// allowance and [optionalRemaining] for the time left: a rule in progress at
/// the cutoff fails with `matcher_cutoff` and later rules are not attempted.
/// A patch is charged against [fanoutLimit] like the pipeline charges it, with
/// the event's baseline routes counted; a patch beyond it fails with
/// `batch_bound`, and a baseline already beyond it leaves every rule not
/// attempted. The function writes nothing.
///
/// The caller supplies the active snapshot's route baseline and, for a stored
/// event, the stored values, through [context]. Stored-event fields of the
/// result stay `null` for a pasted event.
Future<RuleSimulationResult> simulateRules({
  required CanonicalEvent event,
  required MatcherDocument document,
  required SimulationContext context,
  required MatcherRegexTest regexTest,
  required MatcherCapture capture,
  required Duration Function() optionalRemaining,
  int fanoutLimit = pipelineFanoutLimit,
}) async {
  final rules = document.rules;
  final baseRoutes = context.baselineRoutes.toSet();
  var payload = CloudEvent(event: event).toJsonBytes();
  var copies = 1 + baseRoutes.length;
  var cost = payload.length * copies;
  var available = fanoutLimit - cost;
  final baselineOver = cost > fanoutLimit;
  var stopped = baselineOver;
  var timedOut = false;
  var current = event;
  final added = <String>[];
  String? hint;
  final traces = <RuleTrace>[];

  void check() {
    if (optionalRemaining() <= Duration.zero) throw const _Cutoff();
  }

  for (final rule in rules) {
    if (!stopped && optionalRemaining() <= Duration.zero) {
      stopped = true;
      timedOut = true;
    }
    if (stopped) {
      traces.add(
        RuleTrace(
          ruleId: rule.id,
          outcome: ruleOutcomeNotAttempted,
          conditions: [],
          actions: [],
        ),
      );
      continue;
    }
    ConditionExplanation? explanation;
    final effects = <int, (MatcherActionEffect, String?)>{};
    // Route actions whose output the baseline or an earlier route already has.
    final present = <int>{};
    final addedBefore = added.toList();
    final severityBefore = current.severity;
    String? failure;
    try {
      final patch = await applyMatcherRule(
        rule,
        original: event,
        current: current,
        regexTest: regexTest,
        capture: capture,
        check: check,
        onExplained: (value) => explanation = value,
        onAction: (index, effect, value) => effects[index] = (effect, value),
      );
      if (patch != null) {
        final bytes = identical(patch.event, current)
            ? payload
            : CloudEvent(event: patch.event).toJsonBytes();
        final extra = routesAddedByPatch(
          patch.routes,
          baseRoutes,
          added.toSet(),
        );
        final delta = fanoutDelta(
          copies: copies,
          added: extra.length,
          bytes: bytes.length,
          cost: cost,
        );
        check();
        if (delta > available) {
          failure = 'batch_bound';
        } else {
          available -= delta;
          cost += delta;
          copies += extra.length;
          current = patch.event;
          payload = bytes;
          added.addAll(extra);
        }
      }
    } on _Cutoff {
      failure = 'matcher_cutoff';
      stopped = timedOut = true;
    } on MatcherRegexUnavailable catch (error) {
      stopped = timedOut = optionalRemaining() <= Duration.zero;
      failure = stopped ? 'matcher_cutoff' : error.code;
    } on EventValidationError catch (error) {
      stopped = timedOut = optionalRemaining() <= Duration.zero;
      failure = stopped ? 'matcher_cutoff' : error.code;
    }
    // A staged route whose output the baseline, an earlier accepted rule or an
    // earlier route of this rule already has, whether or not the patch fits.
    final routed = {...baseRoutes, ...addedBefore};
    for (final (index, action) in rule.actions.indexed) {
      if (action case MatcherRoute(
        :final outputId,
      ) when effects[index]?.$1 == MatcherActionEffect.staged) {
        if (!routed.add(outputId)) present.add(index);
      }
    }
    // A severity mapped to the value the event already has changes nothing.
    final sameSeverity = <int>{
      for (final (index, action) in rule.actions.indexed)
        if (action is MatcherSeverity &&
            effects[index] == (MatcherActionEffect.staged, severityBefore.name))
          index,
    };
    if (failure != null) {
      // A failed action carries its rule's code, the cutoff included.
      for (final MapEntry(:key, :value) in effects.entries.toList()) {
        if (value.$1 == MatcherActionEffect.failed) {
          effects[key] = (MatcherActionEffect.failed, failure);
        }
      }
    }
    final conditionMatched = explanation?.matched ?? false;
    final outcome = failure != null
        ? ruleOutcomeFailed
        : conditionMatched
        ? ruleOutcomeMatched
        : ruleOutcomeNotMatched;
    if (outcome == ruleOutcomeMatched) {
      for (final (index, action) in rule.actions.indexed) {
        if (effects[index]?.$1 != MatcherActionEffect.staged) continue;
        switch (action) {
          case MatcherClassify(:final value):
            hint = value.name;
          case MatcherLabel(:final key) || MatcherExtract(:final key):
            if (key == reservedNoiseKey) hint = null;
          case MatcherRoute() ||
              MatcherSeverity() ||
              MatcherLink() ||
              MatcherLocation():
            break;
        }
      }
    }
    traces.add(
      RuleTrace(
        ruleId: rule.id,
        outcome: outcome,
        failureCode: failure,
        conditions: _flatten(
          explanation?.trace ?? rule.condition.unevaluated(),
          cutoff: stopped ? failure : null,
        ),
        actions: [
          if (conditionMatched)
            for (final (index, action) in rule.actions.indexed)
              _actionTrace(
                index,
                action,
                effects[index],
                original: event.severity,
                routePresent: present.contains(index),
                severityUnchanged: sameSeverity.contains(index),
                applied:
                    outcome == ruleOutcomeMatched &&
                    effects[index]?.$1 == MatcherActionEffect.staged &&
                    !present.contains(index) &&
                    !sameSeverity.contains(index),
              ),
        ],
      ),
    );
  }

  final notes = <String>[
    if (rules.isEmpty && context.ruleSource == SimulationRuleSource.active)
      'No rules are active.',
    if (context.sourceAbsent)
      "The event's source is not in the active snapshot, so the route "
          'baseline is empty and every route a rule adds shows as added.',
    if (baselineOver)
      'The baseline routes alone exceed the fanout bound of $fanoutLimit '
          'bytes, so no rule was attempted.',
    if (timedOut)
      "The simulation reached its time budget; later rules were not "
          'attempted.',
  ];
  final stored = context.stored;
  return RuleSimulationResult(
    ruleSource: context.ruleSource.name,
    snapshotId: context.snapshotId,
    snapshotRevision: context.snapshotRevision,
    noRulesActive:
        rules.isEmpty && context.ruleSource == SimulationRuleSource.active,
    eventKind: current.kind.name,
    noiseClassHint: hint,
    trace: traces,
    finalLabels: labelEntries(current.labels),
    finalLabelOrigins: labelEntries({
      for (final key in current.labels.keys)
        key: current.labelsOrigin[key] ?? 'source',
    }),
    finalLinks: [
      for (final link in current.links)
        SimulatedLink(
          href: link.href,
          relation: link.relation,
          text: link.text,
        ),
    ],
    finalSeverity: current.severity.name,
    baselineRoutes: context.baselineRoutes.toList(),
    addedRoutes: added,
    routeNote: simulationRouteNote,
    sourceAbsent: context.sourceAbsent,
    baselineOverFanout: baselineOver,
    notes: notes,
    storedSnapshotId: stored?.snapshotId,
    storedLabels: stored == null ? null : labelEntries(stored.labels),
    storedLabelOrigins: stored == null
        ? null
        : labelEntries(stored.labelsOrigin),
    storedEnrichmentErrors: stored == null
        ? null
        : [
            for (final error in stored.enrichmentErrors)
              StoredEnrichmentError(
                stage: error.stage,
                code: error.code,
                message: error.message,
              ),
          ],
    storedBudgetNote: stored == null ? null : simulationStoredBudgetNote,
  );
}

ActionTrace _actionTrace(
  int index,
  MatcherAction action,
  (MatcherActionEffect, String?)? effect, {
  required EventSeverity original,
  required bool routePresent,
  required bool severityUnchanged,
  required bool applied,
}) {
  final (type, detail) = switch (action) {
    MatcherLabel(:final key, :final value) => ('label', '$key = $value'),
    MatcherClassify(:final value) => (
      'classify',
      '$reservedNoiseKey = ${value.name}',
    ),
    MatcherRoute(:final outputId) => ('route', outputId),
    MatcherSeverity(:final values) => (
      'severity',
      switch ((effect, values[original])) {
        // The mapping that fired, from the event's original severity. The
        // target comes from the mapping: a failed action reports its failure
        // code as its value.
        ((_, _)?, final target?) => '${original.name} -> ${target.name}',
        _ => [
          for (final entry in values.entries)
            '${entry.key.name} -> ${entry.value.name}',
        ].join(', '),
      },
    ),
    MatcherLink(:final link) => ('link', '${link.relation} ${link.href}'),
    MatcherExtract(:final key) => (
      'extract',
      switch (effect) {
        (
          MatcherActionEffect.staged || MatcherActionEffect.superseded,
          final String value,
        ) =>
          '$key = $value',
        _ => key,
      },
    ),
    MatcherLocation() => (
      'location',
      switch (effect) {
        (
          MatcherActionEffect.staged || MatcherActionEffect.superseded,
          final String labels,
        )
            when labels != '' =>
          labels,
        _ => 'location table lookup',
      },
    ),
  };
  return ActionTrace(
    index: index,
    type: type,
    detail: detail,
    effect: switch (effect?.$1) {
      MatcherActionEffect.staged when routePresent =>
        'skipped: route already present',
      MatcherActionEffect.staged when severityUnchanged =>
        'skipped: severity already ${effect!.$2}',
      MatcherActionEffect.staged => 'staged',
      MatcherActionEffect.noInput => 'skipped: field missing',
      MatcherActionEffect.noCapture => 'skipped: nothing captured',
      MatcherActionEffect.noEntry => 'skipped: no entry matched',
      MatcherActionEffect.noMapping => 'skipped: no mapping for severity',
      MatcherActionEffect.superseded =>
        'skipped: overwritten later in its rule',
      MatcherActionEffect.failed =>
        effect?.$2 == null ? 'failed' : 'failed: ${effect!.$2}',
      null => 'not run',
    },
    applied: applied,
  );
}

/// Flattens [root] into a pre-order list whose entries name their parent.
///
/// When the simulation's deadline stopped the rule, [cutoff] is its code: the
/// failed leaf carries it, since the leaf's own regex still had time.
List<wire.ConditionTrace> _flatten(ConditionTrace root, {String? cutoff}) {
  final nodes = <wire.ConditionTrace>[];
  void visit(ConditionTrace node, int? parent) {
    final index = nodes.length;
    switch (node) {
      case LeafTrace(:final field, :final operator, :final outcome):
        nodes.add(
          wire.ConditionTrace(
            parentIndex: parent,
            kind: node.kind.name,
            field: field,
            op: operator,
            outcome: switch (outcome) {
              LeafOutcome.valueFails => '${outcome.label} $operator',
              _ => outcome.label,
            },
            failureCode: node.failureCode == null
                ? null
                : cutoff ?? node.failureCode,
          ),
        );
      case CompositeTrace():
        nodes.add(
          wire.ConditionTrace(
            parentIndex: parent,
            kind: node.kind.name,
            outcome: switch (node.result) {
              true => 'matched',
              false => 'no match',
              null => _failed(node) ? 'failed' : 'not evaluated',
            },
          ),
        );
        for (final child in node.children) {
          visit(child, index);
        }
    }
  }

  visit(root, null);
  return nodes;
}

bool _failed(ConditionTrace node) => switch (node) {
  LeafTrace(:final outcome) => outcome == LeafOutcome.failed,
  CompositeTrace(:final children) => children.any(_failed),
};

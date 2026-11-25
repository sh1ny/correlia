/* AUTOMATICALLY GENERATED CODE DO NOT MODIFY */
/*   To generate run: "serverpod generate"    */

// ignore_for_file: implementation_imports
// ignore_for_file: library_private_types_in_public_api
// ignore_for_file: non_constant_identifier_names
// ignore_for_file: public_member_api_docs
// ignore_for_file: type_literal_in_constant_pattern
// ignore_for_file: use_super_parameters
// ignore_for_file: invalid_use_of_internal_member

// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'package:correlia_server/src/generated/protocol.dart' as _i4dbeo9h;
import 'package:serverpod/serverpod.dart' as _is;
import 'rule_trace.dart' as _ingcfw9t;
import 'simulated_link.dart' as _ieclo1rh;
import 'simulation_error.dart' as _izi5l5xj;
import 'stored_enrichment_error.dart' as _iy99nx4o;

abstract class RuleSimulationResult
    implements _is.SerializableModel, _is.ProtocolSerialization {
  RuleSimulationResult._({
    this.error,
    required this.ruleSource,
    this.snapshotId,
    this.snapshotRevision,
    required this.noRulesActive,
    required this.eventKind,
    this.noiseClassHint,
    required this.trace,
    required this.finalLabels,
    required this.finalLabelOrigins,
    required this.finalLinks,
    required this.finalSeverity,
    required this.baselineRoutes,
    required this.addedRoutes,
    required this.routeNote,
    required this.sourceAbsent,
    required this.baselineOverFanout,
    required this.notes,
    this.storedSnapshotId,
    this.storedLabels,
    this.storedLabelOrigins,
    this.storedEnrichmentErrors,
    this.storedBudgetNote,
  });

  factory RuleSimulationResult({
    _izi5l5xj.SimulationError? error,
    required String ruleSource,
    String? snapshotId,
    int? snapshotRevision,
    required bool noRulesActive,
    required String eventKind,
    String? noiseClassHint,
    required List<_ingcfw9t.RuleTrace> trace,
    required Map<String, String> finalLabels,
    required Map<String, String> finalLabelOrigins,
    required List<_ieclo1rh.SimulatedLink> finalLinks,
    required String finalSeverity,
    required List<String> baselineRoutes,
    required List<String> addedRoutes,
    required String routeNote,
    required bool sourceAbsent,
    required bool baselineOverFanout,
    required List<String> notes,
    String? storedSnapshotId,
    Map<String, String>? storedLabels,
    Map<String, String>? storedLabelOrigins,
    List<_iy99nx4o.StoredEnrichmentError>? storedEnrichmentErrors,
    String? storedBudgetNote,
  }) = _RuleSimulationResultImpl;

  factory RuleSimulationResult.fromJson(
    Map<String, dynamic> jsonSerialization,
  ) {
    return RuleSimulationResult(
      error: jsonSerialization['error'] == null
          ? null
          : _i4dbeo9h.Protocol().deserialize<_izi5l5xj.SimulationError>(
              jsonSerialization['error'],
            ),
      ruleSource: jsonSerialization['ruleSource'] as String,
      snapshotId: jsonSerialization['snapshotId'] as String?,
      snapshotRevision: jsonSerialization['snapshotRevision'] as int?,
      noRulesActive: _is.BoolJsonExtension.fromJson(
        jsonSerialization['noRulesActive'],
      ),
      eventKind: jsonSerialization['eventKind'] as String,
      noiseClassHint: jsonSerialization['noiseClassHint'] as String?,
      trace: _i4dbeo9h.Protocol().deserialize<List<_ingcfw9t.RuleTrace>>(
        jsonSerialization['trace'],
      ),
      finalLabels: _i4dbeo9h.Protocol().deserialize<Map<String, String>>(
        jsonSerialization['finalLabels'],
      ),
      finalLabelOrigins: _i4dbeo9h.Protocol().deserialize<Map<String, String>>(
        jsonSerialization['finalLabelOrigins'],
      ),
      finalLinks: _i4dbeo9h.Protocol()
          .deserialize<List<_ieclo1rh.SimulatedLink>>(
            jsonSerialization['finalLinks'],
          ),
      finalSeverity: jsonSerialization['finalSeverity'] as String,
      baselineRoutes: _i4dbeo9h.Protocol().deserialize<List<String>>(
        jsonSerialization['baselineRoutes'],
      ),
      addedRoutes: _i4dbeo9h.Protocol().deserialize<List<String>>(
        jsonSerialization['addedRoutes'],
      ),
      routeNote: jsonSerialization['routeNote'] as String,
      sourceAbsent: _is.BoolJsonExtension.fromJson(
        jsonSerialization['sourceAbsent'],
      ),
      baselineOverFanout: _is.BoolJsonExtension.fromJson(
        jsonSerialization['baselineOverFanout'],
      ),
      notes: _i4dbeo9h.Protocol().deserialize<List<String>>(
        jsonSerialization['notes'],
      ),
      storedSnapshotId: jsonSerialization['storedSnapshotId'] as String?,
      storedLabels: jsonSerialization['storedLabels'] == null
          ? null
          : _i4dbeo9h.Protocol().deserialize<Map<String, String>>(
              jsonSerialization['storedLabels'],
            ),
      storedLabelOrigins: jsonSerialization['storedLabelOrigins'] == null
          ? null
          : _i4dbeo9h.Protocol().deserialize<Map<String, String>>(
              jsonSerialization['storedLabelOrigins'],
            ),
      storedEnrichmentErrors:
          jsonSerialization['storedEnrichmentErrors'] == null
          ? null
          : _i4dbeo9h.Protocol()
                .deserialize<List<_iy99nx4o.StoredEnrichmentError>>(
                  jsonSerialization['storedEnrichmentErrors'],
                ),
      storedBudgetNote: jsonSerialization['storedBudgetNote'] as String?,
    );
  }

  _izi5l5xj.SimulationError? error;

  String ruleSource;

  String? snapshotId;

  int? snapshotRevision;

  bool noRulesActive;

  String eventKind;

  String? noiseClassHint;

  List<_ingcfw9t.RuleTrace> trace;

  Map<String, String> finalLabels;

  Map<String, String> finalLabelOrigins;

  List<_ieclo1rh.SimulatedLink> finalLinks;

  String finalSeverity;

  List<String> baselineRoutes;

  List<String> addedRoutes;

  String routeNote;

  bool sourceAbsent;

  bool baselineOverFanout;

  List<String> notes;

  String? storedSnapshotId;

  Map<String, String>? storedLabels;

  Map<String, String>? storedLabelOrigins;

  List<_iy99nx4o.StoredEnrichmentError>? storedEnrichmentErrors;

  String? storedBudgetNote;

  /// Returns a shallow copy of this [RuleSimulationResult]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  RuleSimulationResult copyWith({
    _izi5l5xj.SimulationError? error =
        const _UndefinedRuleSimulationResult$error(),
    String? ruleSource,
    String? snapshotId,
    int? snapshotRevision,
    bool? noRulesActive,
    String? eventKind,
    String? noiseClassHint,
    List<_ingcfw9t.RuleTrace>? trace,
    Map<String, String>? finalLabels,
    Map<String, String>? finalLabelOrigins,
    List<_ieclo1rh.SimulatedLink>? finalLinks,
    String? finalSeverity,
    List<String>? baselineRoutes,
    List<String>? addedRoutes,
    String? routeNote,
    bool? sourceAbsent,
    bool? baselineOverFanout,
    List<String>? notes,
    String? storedSnapshotId,
    Map<String, String>? storedLabels =
        const _is.$UndefinedMap<String, String>(),
    Map<String, String>? storedLabelOrigins =
        const _is.$UndefinedMap<String, String>(),
    List<_iy99nx4o.StoredEnrichmentError>? storedEnrichmentErrors =
        const _is.$UndefinedList<_iy99nx4o.StoredEnrichmentError>(),
    String? storedBudgetNote,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'RuleSimulationResult',
      if (error != null) 'error': error?.toJson(),
      'ruleSource': ruleSource,
      if (snapshotId != null) 'snapshotId': snapshotId,
      if (snapshotRevision != null) 'snapshotRevision': snapshotRevision,
      'noRulesActive': noRulesActive,
      'eventKind': eventKind,
      if (noiseClassHint != null) 'noiseClassHint': noiseClassHint,
      'trace': trace.toJson(valueToJson: (v) => v.toJson()),
      'finalLabels': finalLabels.toJson(),
      'finalLabelOrigins': finalLabelOrigins.toJson(),
      'finalLinks': finalLinks.toJson(valueToJson: (v) => v.toJson()),
      'finalSeverity': finalSeverity,
      'baselineRoutes': baselineRoutes.toJson(),
      'addedRoutes': addedRoutes.toJson(),
      'routeNote': routeNote,
      'sourceAbsent': sourceAbsent,
      'baselineOverFanout': baselineOverFanout,
      'notes': notes.toJson(),
      if (storedSnapshotId != null) 'storedSnapshotId': storedSnapshotId,
      if (storedLabels != null) 'storedLabels': storedLabels?.toJson(),
      if (storedLabelOrigins != null)
        'storedLabelOrigins': storedLabelOrigins?.toJson(),
      if (storedEnrichmentErrors != null)
        'storedEnrichmentErrors': storedEnrichmentErrors?.toJson(
          valueToJson: (v) => v.toJson(),
        ),
      if (storedBudgetNote != null) 'storedBudgetNote': storedBudgetNote,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      '__className__': 'RuleSimulationResult',
      if (error != null) 'error': error?.toJsonForProtocol(),
      'ruleSource': ruleSource,
      if (snapshotId != null) 'snapshotId': snapshotId,
      if (snapshotRevision != null) 'snapshotRevision': snapshotRevision,
      'noRulesActive': noRulesActive,
      'eventKind': eventKind,
      if (noiseClassHint != null) 'noiseClassHint': noiseClassHint,
      'trace': trace.toJson(valueToJson: (v) => v.toJsonForProtocol()),
      'finalLabels': finalLabels.toJson(),
      'finalLabelOrigins': finalLabelOrigins.toJson(),
      'finalLinks': finalLinks.toJson(
        valueToJson: (v) => v.toJsonForProtocol(),
      ),
      'finalSeverity': finalSeverity,
      'baselineRoutes': baselineRoutes.toJson(),
      'addedRoutes': addedRoutes.toJson(),
      'routeNote': routeNote,
      'sourceAbsent': sourceAbsent,
      'baselineOverFanout': baselineOverFanout,
      'notes': notes.toJson(),
      if (storedSnapshotId != null) 'storedSnapshotId': storedSnapshotId,
      if (storedLabels != null) 'storedLabels': storedLabels?.toJson(),
      if (storedLabelOrigins != null)
        'storedLabelOrigins': storedLabelOrigins?.toJson(),
      if (storedEnrichmentErrors != null)
        'storedEnrichmentErrors': storedEnrichmentErrors?.toJson(
          valueToJson: (v) => v.toJsonForProtocol(),
        ),
      if (storedBudgetNote != null) 'storedBudgetNote': storedBudgetNote,
    };
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _UndefinedRuleSimulationResult$error extends _is.UndefinedSentinel
    implements _izi5l5xj.SimulationError {
  const _UndefinedRuleSimulationResult$error();
}

class _RuleSimulationResultImpl extends RuleSimulationResult {
  _RuleSimulationResultImpl({
    _izi5l5xj.SimulationError? error,
    required String ruleSource,
    String? snapshotId,
    int? snapshotRevision,
    required bool noRulesActive,
    required String eventKind,
    String? noiseClassHint,
    required List<_ingcfw9t.RuleTrace> trace,
    required Map<String, String> finalLabels,
    required Map<String, String> finalLabelOrigins,
    required List<_ieclo1rh.SimulatedLink> finalLinks,
    required String finalSeverity,
    required List<String> baselineRoutes,
    required List<String> addedRoutes,
    required String routeNote,
    required bool sourceAbsent,
    required bool baselineOverFanout,
    required List<String> notes,
    String? storedSnapshotId,
    Map<String, String>? storedLabels,
    Map<String, String>? storedLabelOrigins,
    List<_iy99nx4o.StoredEnrichmentError>? storedEnrichmentErrors,
    String? storedBudgetNote,
  }) : super._(
         error: error,
         ruleSource: ruleSource,
         snapshotId: snapshotId,
         snapshotRevision: snapshotRevision,
         noRulesActive: noRulesActive,
         eventKind: eventKind,
         noiseClassHint: noiseClassHint,
         trace: trace,
         finalLabels: finalLabels,
         finalLabelOrigins: finalLabelOrigins,
         finalLinks: finalLinks,
         finalSeverity: finalSeverity,
         baselineRoutes: baselineRoutes,
         addedRoutes: addedRoutes,
         routeNote: routeNote,
         sourceAbsent: sourceAbsent,
         baselineOverFanout: baselineOverFanout,
         notes: notes,
         storedSnapshotId: storedSnapshotId,
         storedLabels: storedLabels,
         storedLabelOrigins: storedLabelOrigins,
         storedEnrichmentErrors: storedEnrichmentErrors,
         storedBudgetNote: storedBudgetNote,
       );

  /// Returns a shallow copy of this [RuleSimulationResult]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  RuleSimulationResult copyWith({
    _izi5l5xj.SimulationError? error =
        const _UndefinedRuleSimulationResult$error(),
    String? ruleSource,
    Object? snapshotId = _Undefined,
    Object? snapshotRevision = _Undefined,
    bool? noRulesActive,
    String? eventKind,
    Object? noiseClassHint = _Undefined,
    List<_ingcfw9t.RuleTrace>? trace,
    Map<String, String>? finalLabels,
    Map<String, String>? finalLabelOrigins,
    List<_ieclo1rh.SimulatedLink>? finalLinks,
    String? finalSeverity,
    List<String>? baselineRoutes,
    List<String>? addedRoutes,
    String? routeNote,
    bool? sourceAbsent,
    bool? baselineOverFanout,
    List<String>? notes,
    Object? storedSnapshotId = _Undefined,
    Map<String, String>? storedLabels =
        const _is.$UndefinedMap<String, String>(),
    Map<String, String>? storedLabelOrigins =
        const _is.$UndefinedMap<String, String>(),
    List<_iy99nx4o.StoredEnrichmentError>? storedEnrichmentErrors =
        const _is.$UndefinedList<_iy99nx4o.StoredEnrichmentError>(),
    Object? storedBudgetNote = _Undefined,
  }) {
    return RuleSimulationResult(
      error: error is _is.UndefinedSentinel ? this.error?.copyWith() : error,
      ruleSource: ruleSource ?? this.ruleSource,
      snapshotId: snapshotId is String? ? snapshotId : this.snapshotId,
      snapshotRevision: snapshotRevision is int?
          ? snapshotRevision
          : this.snapshotRevision,
      noRulesActive: noRulesActive ?? this.noRulesActive,
      eventKind: eventKind ?? this.eventKind,
      noiseClassHint: noiseClassHint is String?
          ? noiseClassHint
          : this.noiseClassHint,
      trace: trace ?? this.trace.map((e0) => e0.copyWith()).toList(),
      finalLabels:
          finalLabels ??
          this.finalLabels.map(
            (
              key0,
              value0,
            ) => MapEntry(
              key0,
              value0,
            ),
          ),
      finalLabelOrigins:
          finalLabelOrigins ??
          this.finalLabelOrigins.map(
            (
              key0,
              value0,
            ) => MapEntry(
              key0,
              value0,
            ),
          ),
      finalLinks:
          finalLinks ?? this.finalLinks.map((e0) => e0.copyWith()).toList(),
      finalSeverity: finalSeverity ?? this.finalSeverity,
      baselineRoutes:
          baselineRoutes ?? this.baselineRoutes.map((e0) => e0).toList(),
      addedRoutes: addedRoutes ?? this.addedRoutes.map((e0) => e0).toList(),
      routeNote: routeNote ?? this.routeNote,
      sourceAbsent: sourceAbsent ?? this.sourceAbsent,
      baselineOverFanout: baselineOverFanout ?? this.baselineOverFanout,
      notes: notes ?? this.notes.map((e0) => e0).toList(),
      storedSnapshotId: storedSnapshotId is String?
          ? storedSnapshotId
          : this.storedSnapshotId,
      storedLabels: storedLabels is _is.UndefinedSentinel
          ? this.storedLabels?.map(
              (
                key0,
                value0,
              ) => MapEntry(
                key0,
                value0,
              ),
            )
          : storedLabels,
      storedLabelOrigins: storedLabelOrigins is _is.UndefinedSentinel
          ? this.storedLabelOrigins?.map(
              (
                key0,
                value0,
              ) => MapEntry(
                key0,
                value0,
              ),
            )
          : storedLabelOrigins,
      storedEnrichmentErrors: storedEnrichmentErrors is _is.UndefinedSentinel
          ? this.storedEnrichmentErrors?.map((e0) => e0.copyWith()).toList()
          : storedEnrichmentErrors,
      storedBudgetNote: storedBudgetNote is String?
          ? storedBudgetNote
          : this.storedBudgetNote,
    );
  }
}

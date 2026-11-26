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
import 'package:correlia_client/src/protocol/protocol.dart' as _iowdjkrj;
import 'package:serverpod_client/serverpod_client.dart' as _isc;
import 'rule_trace.dart' as _ingcfw9t;
import 'simulated_label.dart' as _i3ntsck3;
import 'simulated_link.dart' as _ieclo1rh;
import 'simulation_error.dart' as _izi5l5xj;
import 'stored_enrichment_error.dart' as _iy99nx4o;

abstract class RuleSimulationResult
    implements _isc.SerializableModel, _isc.ProtocolSerialization {
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
    required List<_i3ntsck3.SimulatedLabel> finalLabels,
    required List<_i3ntsck3.SimulatedLabel> finalLabelOrigins,
    required List<_ieclo1rh.SimulatedLink> finalLinks,
    required String finalSeverity,
    required List<String> baselineRoutes,
    required List<String> addedRoutes,
    required String routeNote,
    required bool sourceAbsent,
    required bool baselineOverFanout,
    required List<String> notes,
    String? storedSnapshotId,
    List<_i3ntsck3.SimulatedLabel>? storedLabels,
    List<_i3ntsck3.SimulatedLabel>? storedLabelOrigins,
    List<_iy99nx4o.StoredEnrichmentError>? storedEnrichmentErrors,
    String? storedBudgetNote,
  }) = _RuleSimulationResultImpl;

  factory RuleSimulationResult.fromJson(
    Map<String, dynamic> jsonSerialization,
  ) {
    return RuleSimulationResult(
      error: jsonSerialization['error'] == null
          ? null
          : _iowdjkrj.Protocol().deserialize<_izi5l5xj.SimulationError>(
              jsonSerialization['error'],
            ),
      ruleSource: jsonSerialization['ruleSource'] as String,
      snapshotId: jsonSerialization['snapshotId'] as String?,
      snapshotRevision: jsonSerialization['snapshotRevision'] as int?,
      noRulesActive: _isc.BoolJsonExtension.fromJson(
        jsonSerialization['noRulesActive'],
      ),
      eventKind: jsonSerialization['eventKind'] as String,
      noiseClassHint: jsonSerialization['noiseClassHint'] as String?,
      trace: _iowdjkrj.Protocol().deserialize<List<_ingcfw9t.RuleTrace>>(
        jsonSerialization['trace'],
      ),
      finalLabels: _iowdjkrj.Protocol()
          .deserialize<List<_i3ntsck3.SimulatedLabel>>(
            jsonSerialization['finalLabels'],
          ),
      finalLabelOrigins: _iowdjkrj.Protocol()
          .deserialize<List<_i3ntsck3.SimulatedLabel>>(
            jsonSerialization['finalLabelOrigins'],
          ),
      finalLinks: _iowdjkrj.Protocol()
          .deserialize<List<_ieclo1rh.SimulatedLink>>(
            jsonSerialization['finalLinks'],
          ),
      finalSeverity: jsonSerialization['finalSeverity'] as String,
      baselineRoutes: _iowdjkrj.Protocol().deserialize<List<String>>(
        jsonSerialization['baselineRoutes'],
      ),
      addedRoutes: _iowdjkrj.Protocol().deserialize<List<String>>(
        jsonSerialization['addedRoutes'],
      ),
      routeNote: jsonSerialization['routeNote'] as String,
      sourceAbsent: _isc.BoolJsonExtension.fromJson(
        jsonSerialization['sourceAbsent'],
      ),
      baselineOverFanout: _isc.BoolJsonExtension.fromJson(
        jsonSerialization['baselineOverFanout'],
      ),
      notes: _iowdjkrj.Protocol().deserialize<List<String>>(
        jsonSerialization['notes'],
      ),
      storedSnapshotId: jsonSerialization['storedSnapshotId'] as String?,
      storedLabels: jsonSerialization['storedLabels'] == null
          ? null
          : _iowdjkrj.Protocol().deserialize<List<_i3ntsck3.SimulatedLabel>>(
              jsonSerialization['storedLabels'],
            ),
      storedLabelOrigins: jsonSerialization['storedLabelOrigins'] == null
          ? null
          : _iowdjkrj.Protocol().deserialize<List<_i3ntsck3.SimulatedLabel>>(
              jsonSerialization['storedLabelOrigins'],
            ),
      storedEnrichmentErrors:
          jsonSerialization['storedEnrichmentErrors'] == null
          ? null
          : _iowdjkrj.Protocol()
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

  List<_i3ntsck3.SimulatedLabel> finalLabels;

  List<_i3ntsck3.SimulatedLabel> finalLabelOrigins;

  List<_ieclo1rh.SimulatedLink> finalLinks;

  String finalSeverity;

  List<String> baselineRoutes;

  List<String> addedRoutes;

  String routeNote;

  bool sourceAbsent;

  bool baselineOverFanout;

  List<String> notes;

  String? storedSnapshotId;

  List<_i3ntsck3.SimulatedLabel>? storedLabels;

  List<_i3ntsck3.SimulatedLabel>? storedLabelOrigins;

  List<_iy99nx4o.StoredEnrichmentError>? storedEnrichmentErrors;

  String? storedBudgetNote;

  /// Returns a shallow copy of this [RuleSimulationResult]
  /// with some or all fields replaced by the given arguments.
  @_isc.useResult
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
    List<_i3ntsck3.SimulatedLabel>? finalLabels,
    List<_i3ntsck3.SimulatedLabel>? finalLabelOrigins,
    List<_ieclo1rh.SimulatedLink>? finalLinks,
    String? finalSeverity,
    List<String>? baselineRoutes,
    List<String>? addedRoutes,
    String? routeNote,
    bool? sourceAbsent,
    bool? baselineOverFanout,
    List<String>? notes,
    String? storedSnapshotId,
    List<_i3ntsck3.SimulatedLabel>? storedLabels =
        const _isc.$UndefinedList<_i3ntsck3.SimulatedLabel>(),
    List<_i3ntsck3.SimulatedLabel>? storedLabelOrigins =
        const _isc.$UndefinedList<_i3ntsck3.SimulatedLabel>(),
    List<_iy99nx4o.StoredEnrichmentError>? storedEnrichmentErrors =
        const _isc.$UndefinedList<_iy99nx4o.StoredEnrichmentError>(),
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
      'finalLabels': finalLabels.toJson(valueToJson: (v) => v.toJson()),
      'finalLabelOrigins': finalLabelOrigins.toJson(
        valueToJson: (v) => v.toJson(),
      ),
      'finalLinks': finalLinks.toJson(valueToJson: (v) => v.toJson()),
      'finalSeverity': finalSeverity,
      'baselineRoutes': baselineRoutes.toJson(),
      'addedRoutes': addedRoutes.toJson(),
      'routeNote': routeNote,
      'sourceAbsent': sourceAbsent,
      'baselineOverFanout': baselineOverFanout,
      'notes': notes.toJson(),
      if (storedSnapshotId != null) 'storedSnapshotId': storedSnapshotId,
      if (storedLabels != null)
        'storedLabels': storedLabels?.toJson(valueToJson: (v) => v.toJson()),
      if (storedLabelOrigins != null)
        'storedLabelOrigins': storedLabelOrigins?.toJson(
          valueToJson: (v) => v.toJson(),
        ),
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
      'finalLabels': finalLabels.toJson(
        valueToJson: (v) => v.toJsonForProtocol(),
      ),
      'finalLabelOrigins': finalLabelOrigins.toJson(
        valueToJson: (v) => v.toJsonForProtocol(),
      ),
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
      if (storedLabels != null)
        'storedLabels': storedLabels?.toJson(
          valueToJson: (v) => v.toJsonForProtocol(),
        ),
      if (storedLabelOrigins != null)
        'storedLabelOrigins': storedLabelOrigins?.toJson(
          valueToJson: (v) => v.toJsonForProtocol(),
        ),
      if (storedEnrichmentErrors != null)
        'storedEnrichmentErrors': storedEnrichmentErrors?.toJson(
          valueToJson: (v) => v.toJsonForProtocol(),
        ),
      if (storedBudgetNote != null) 'storedBudgetNote': storedBudgetNote,
    };
  }

  @override
  String toString() {
    return _isc.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _UndefinedRuleSimulationResult$error extends _isc.UndefinedSentinel
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
    required List<_i3ntsck3.SimulatedLabel> finalLabels,
    required List<_i3ntsck3.SimulatedLabel> finalLabelOrigins,
    required List<_ieclo1rh.SimulatedLink> finalLinks,
    required String finalSeverity,
    required List<String> baselineRoutes,
    required List<String> addedRoutes,
    required String routeNote,
    required bool sourceAbsent,
    required bool baselineOverFanout,
    required List<String> notes,
    String? storedSnapshotId,
    List<_i3ntsck3.SimulatedLabel>? storedLabels,
    List<_i3ntsck3.SimulatedLabel>? storedLabelOrigins,
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
  @_isc.useResult
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
    List<_i3ntsck3.SimulatedLabel>? finalLabels,
    List<_i3ntsck3.SimulatedLabel>? finalLabelOrigins,
    List<_ieclo1rh.SimulatedLink>? finalLinks,
    String? finalSeverity,
    List<String>? baselineRoutes,
    List<String>? addedRoutes,
    String? routeNote,
    bool? sourceAbsent,
    bool? baselineOverFanout,
    List<String>? notes,
    Object? storedSnapshotId = _Undefined,
    List<_i3ntsck3.SimulatedLabel>? storedLabels =
        const _isc.$UndefinedList<_i3ntsck3.SimulatedLabel>(),
    List<_i3ntsck3.SimulatedLabel>? storedLabelOrigins =
        const _isc.$UndefinedList<_i3ntsck3.SimulatedLabel>(),
    List<_iy99nx4o.StoredEnrichmentError>? storedEnrichmentErrors =
        const _isc.$UndefinedList<_iy99nx4o.StoredEnrichmentError>(),
    Object? storedBudgetNote = _Undefined,
  }) {
    return RuleSimulationResult(
      error: error is _isc.UndefinedSentinel ? this.error?.copyWith() : error,
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
          finalLabels ?? this.finalLabels.map((e0) => e0.copyWith()).toList(),
      finalLabelOrigins:
          finalLabelOrigins ??
          this.finalLabelOrigins.map((e0) => e0.copyWith()).toList(),
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
      storedLabels: storedLabels is _isc.UndefinedSentinel
          ? this.storedLabels?.map((e0) => e0.copyWith()).toList()
          : storedLabels,
      storedLabelOrigins: storedLabelOrigins is _isc.UndefinedSentinel
          ? this.storedLabelOrigins?.map((e0) => e0.copyWith()).toList()
          : storedLabelOrigins,
      storedEnrichmentErrors: storedEnrichmentErrors is _isc.UndefinedSentinel
          ? this.storedEnrichmentErrors?.map((e0) => e0.copyWith()).toList()
          : storedEnrichmentErrors,
      storedBudgetNote: storedBudgetNote is String?
          ? storedBudgetNote
          : this.storedBudgetNote,
    );
  }
}

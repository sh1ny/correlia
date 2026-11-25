/* AUTOMATICALLY GENERATED CODE DO NOT MODIFY */
/*   To generate run: "serverpod generate"    */

// ignore_for_file: implementation_imports
// ignore_for_file: library_private_types_in_public_api
// ignore_for_file: non_constant_identifier_names
// ignore_for_file: public_member_api_docs
// ignore_for_file: type_literal_in_constant_pattern
// ignore_for_file: use_super_parameters
// ignore_for_file: invalid_use_of_internal_member
// ignore_for_file: dead_code, unnecessary_type_check

// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'package:serverpod_client/serverpod_client.dart' as _isc;
import 'action_trace.dart' as _ikn0wxo5;
import 'alert_snapshot.dart' as _iz3t21fy;
import 'alert_view.dart' as _i897ft9c;
import 'condition_trace.dart' as _i0ehnxud;
import 'console_access_denied_exception.dart' as _i25sduw2;
import 'feed_entry.dart' as _iywqxrq6;
import 'feed_page.dart' as _ijrqdfur;
import 'feed_wake_up.dart' as _ivrec9rl;
import 'icinga2_consumer_status.dart' as _i0zg1hdn;
import 'icinga2_consumer_sync.dart' as _id40rhfu;
import 'invalid_cursor_exception.dart' as _iil3cq3h;
import 'mapping_preview_diagnostic.dart' as _ibaui0zg;
import 'mapping_preview_event.dart' as _i20s3xik;
import 'mapping_preview_result.dart' as _ines6tzx;
import 'mapping_preview_validation_error.dart' as _i2ozkwub;
import 'matcher_failure_view.dart' as _ik186lp1;
import 'rule_simulation_result.dart' as _i2oitrdy;
import 'rule_trace.dart' as _ingcfw9t;
import 'simulated_link.dart' as _ieclo1rh;
import 'simulation_error.dart' as _izi5l5xj;
import 'stored_enrichment_error.dart' as _iy99nx4o;
export 'action_trace.dart';
export 'alert_snapshot.dart';
export 'alert_view.dart';
export 'condition_trace.dart';
export 'console_access_denied_exception.dart';
export 'feed_entry.dart';
export 'feed_page.dart';
export 'feed_wake_up.dart';
export 'icinga2_consumer_status.dart';
export 'icinga2_consumer_sync.dart';
export 'invalid_cursor_exception.dart';
export 'mapping_preview_diagnostic.dart';
export 'mapping_preview_event.dart';
export 'mapping_preview_result.dart';
export 'mapping_preview_validation_error.dart';
export 'matcher_failure_view.dart';
export 'rule_simulation_result.dart';
export 'rule_trace.dart';
export 'simulated_link.dart';
export 'simulation_error.dart';
export 'stored_enrichment_error.dart';
export 'client.dart';

class Protocol extends _isc.SerializationManager
    implements _isc.ProtocolDeserializationProvider {
  Protocol._();

  factory Protocol() => _instance;

  static final Protocol _instance = Protocol._();

  @override
  _isc.ProtocolDeserialization get deserializationMetadata =>
      _isc.ProtocolDeserialization.cached(
        this,
        types: const [
          _isc.getType<_ikn0wxo5.ActionTrace>,
          _isc.getType<_iz3t21fy.AlertSnapshot>,
          _isc.getType<_i897ft9c.AlertView>,
          _isc.getType<_i0ehnxud.ConditionTrace>,
          _isc.getType<_i25sduw2.ConsoleAccessDeniedException>,
          _isc.getType<_iywqxrq6.FeedEntry>,
          _isc.getType<_ijrqdfur.FeedPage>,
          _isc.getType<_ivrec9rl.FeedWakeUp>,
          _isc.getType<_i0zg1hdn.Icinga2ConsumerStatus>,
          _isc.getType<_id40rhfu.Icinga2ConsumerSync>,
          _isc.getType<_iil3cq3h.InvalidCursorException>,
          _isc.getType<_ibaui0zg.MappingPreviewDiagnostic>,
          _isc.getType<_i20s3xik.MappingPreviewEvent>,
          _isc.getType<_ines6tzx.MappingPreviewResult>,
          _isc.getType<_i2ozkwub.MappingPreviewValidationError>,
          _isc.getType<_ik186lp1.MatcherFailureView>,
          _isc.getType<_i2oitrdy.RuleSimulationResult>,
          _isc.getType<_ingcfw9t.RuleTrace>,
          _isc.getType<_ieclo1rh.SimulatedLink>,
          _isc.getType<_izi5l5xj.SimulationError>,
          _isc.getType<_iy99nx4o.StoredEnrichmentError>,
          _isc.getType<_ikn0wxo5.ActionTrace?>,
          _isc.getType<_iz3t21fy.AlertSnapshot?>,
          _isc.getType<_i897ft9c.AlertView?>,
          _isc.getType<_i0ehnxud.ConditionTrace?>,
          _isc.getType<_i25sduw2.ConsoleAccessDeniedException?>,
          _isc.getType<_iywqxrq6.FeedEntry?>,
          _isc.getType<_ijrqdfur.FeedPage?>,
          _isc.getType<_ivrec9rl.FeedWakeUp?>,
          _isc.getType<_i0zg1hdn.Icinga2ConsumerStatus?>,
          _isc.getType<_id40rhfu.Icinga2ConsumerSync?>,
          _isc.getType<_iil3cq3h.InvalidCursorException?>,
          _isc.getType<_ibaui0zg.MappingPreviewDiagnostic?>,
          _isc.getType<_i20s3xik.MappingPreviewEvent?>,
          _isc.getType<_ines6tzx.MappingPreviewResult?>,
          _isc.getType<_i2ozkwub.MappingPreviewValidationError?>,
          _isc.getType<_ik186lp1.MatcherFailureView?>,
          _isc.getType<_i2oitrdy.RuleSimulationResult?>,
          _isc.getType<_ingcfw9t.RuleTrace?>,
          _isc.getType<_ieclo1rh.SimulatedLink?>,
          _isc.getType<_izi5l5xj.SimulationError?>,
          _isc.getType<_iy99nx4o.StoredEnrichmentError?>,
          _isc.getType<List<_i897ft9c.AlertView>>,
          _isc.getType<List<_iywqxrq6.FeedEntry>>,
          _isc.getType<Map<String, int>>,
          _isc.getType<List<_i20s3xik.MappingPreviewEvent>>,
          _isc.getType<List<_ibaui0zg.MappingPreviewDiagnostic>>,
          _isc.getType<List<_ingcfw9t.RuleTrace>>,
          _isc.getType<Map<String, String>>,
          _isc.getType<List<_ieclo1rh.SimulatedLink>>,
          _isc.getType<List<String>>,
          _isc.getType<Map<String, String>?>,
          _isc.getType<List<_iy99nx4o.StoredEnrichmentError>>,
          _isc.getType<List<_iy99nx4o.StoredEnrichmentError>?>,
          _isc.getType<List<_i0ehnxud.ConditionTrace>>,
          _isc.getType<List<_ikn0wxo5.ActionTrace>>,
        ],
        modules: const [],
        classNames: const [
          'ActionTrace',
          'AlertSnapshot',
          'AlertView',
          'ConditionTrace',
          'ConsoleAccessDeniedException',
          'FeedEntry',
          'FeedPage',
          'FeedWakeUp',
          'Icinga2ConsumerStatus',
          'Icinga2ConsumerSync',
          'InvalidCursorException',
          'MappingPreviewDiagnostic',
          'MappingPreviewEvent',
          'MappingPreviewResult',
          'MappingPreviewValidationError',
          'MatcherFailureView',
          'RuleSimulationResult',
          'RuleTrace',
          'SimulatedLink',
          'SimulationError',
          'StoredEnrichmentError',
        ],
      );

  static String? getClassNameFromObjectJson(dynamic data) =>
      _isc.ProtocolDeserialization.readClassName(data);

  @override
  T deserialize<T>(
    dynamic data, [
    Type? t,
  ]) {
    t ??= T;
    final rawDataClassName = _isc.ProtocolDeserialization.readClassName(data);
    final dataClassName = rawDataClassName;
    if (dataClassName != null && dataClassName != getClassNameForType(t)) {
      try {
        return deserializeByClassName({
          'className': dataClassName,
          'data': data,
        });
      } on _isc.DeserializationClassNameNotFoundException catch (_) {
        // If the className is not recognized (e.g., older client receiving
        // data with a new subtype), fall back to deserializing without the
        // className, using the expected type T.
      }
    }

    if (t == _ikn0wxo5.ActionTrace) {
      return _ikn0wxo5.ActionTrace.fromJson(data) as T;
    }
    if (t == _iz3t21fy.AlertSnapshot) {
      return _iz3t21fy.AlertSnapshot.fromJson(data) as T;
    }
    if (t == _i897ft9c.AlertView) {
      return _i897ft9c.AlertView.fromJson(data) as T;
    }
    if (t == _i0ehnxud.ConditionTrace) {
      return _i0ehnxud.ConditionTrace.fromJson(data) as T;
    }
    if (t == _i25sduw2.ConsoleAccessDeniedException) {
      return _i25sduw2.ConsoleAccessDeniedException.fromJson(data) as T;
    }
    if (t == _iywqxrq6.FeedEntry) {
      return _iywqxrq6.FeedEntry.fromJson(data) as T;
    }
    if (t == _ijrqdfur.FeedPage) {
      return _ijrqdfur.FeedPage.fromJson(data) as T;
    }
    if (t == _ivrec9rl.FeedWakeUp) {
      return _ivrec9rl.FeedWakeUp.fromJson(data) as T;
    }
    if (t == _i0zg1hdn.Icinga2ConsumerStatus) {
      return _i0zg1hdn.Icinga2ConsumerStatus.fromJson(data) as T;
    }
    if (t == _id40rhfu.Icinga2ConsumerSync) {
      return _id40rhfu.Icinga2ConsumerSync.fromJson(data) as T;
    }
    if (t == _iil3cq3h.InvalidCursorException) {
      return _iil3cq3h.InvalidCursorException.fromJson(data) as T;
    }
    if (t == _ibaui0zg.MappingPreviewDiagnostic) {
      return _ibaui0zg.MappingPreviewDiagnostic.fromJson(data) as T;
    }
    if (t == _i20s3xik.MappingPreviewEvent) {
      return _i20s3xik.MappingPreviewEvent.fromJson(data) as T;
    }
    if (t == _ines6tzx.MappingPreviewResult) {
      return _ines6tzx.MappingPreviewResult.fromJson(data) as T;
    }
    if (t == _i2ozkwub.MappingPreviewValidationError) {
      return _i2ozkwub.MappingPreviewValidationError.fromJson(data) as T;
    }
    if (t == _ik186lp1.MatcherFailureView) {
      return _ik186lp1.MatcherFailureView.fromJson(data) as T;
    }
    if (t == _i2oitrdy.RuleSimulationResult) {
      return _i2oitrdy.RuleSimulationResult.fromJson(data) as T;
    }
    if (t == _ingcfw9t.RuleTrace) {
      return _ingcfw9t.RuleTrace.fromJson(data) as T;
    }
    if (t == _ieclo1rh.SimulatedLink) {
      return _ieclo1rh.SimulatedLink.fromJson(data) as T;
    }
    if (t == _izi5l5xj.SimulationError) {
      return _izi5l5xj.SimulationError.fromJson(data) as T;
    }
    if (t == _iy99nx4o.StoredEnrichmentError) {
      return _iy99nx4o.StoredEnrichmentError.fromJson(data) as T;
    }
    if (t == _isc.getType<_ikn0wxo5.ActionTrace?>()) {
      return (data != null ? _ikn0wxo5.ActionTrace.fromJson(data) : null) as T;
    }
    if (t == _isc.getType<_iz3t21fy.AlertSnapshot?>()) {
      return (data != null ? _iz3t21fy.AlertSnapshot.fromJson(data) : null)
          as T;
    }
    if (t == _isc.getType<_i897ft9c.AlertView?>()) {
      return (data != null ? _i897ft9c.AlertView.fromJson(data) : null) as T;
    }
    if (t == _isc.getType<_i0ehnxud.ConditionTrace?>()) {
      return (data != null ? _i0ehnxud.ConditionTrace.fromJson(data) : null)
          as T;
    }
    if (t == _isc.getType<_i25sduw2.ConsoleAccessDeniedException?>()) {
      return (data != null
              ? _i25sduw2.ConsoleAccessDeniedException.fromJson(data)
              : null)
          as T;
    }
    if (t == _isc.getType<_iywqxrq6.FeedEntry?>()) {
      return (data != null ? _iywqxrq6.FeedEntry.fromJson(data) : null) as T;
    }
    if (t == _isc.getType<_ijrqdfur.FeedPage?>()) {
      return (data != null ? _ijrqdfur.FeedPage.fromJson(data) : null) as T;
    }
    if (t == _isc.getType<_ivrec9rl.FeedWakeUp?>()) {
      return (data != null ? _ivrec9rl.FeedWakeUp.fromJson(data) : null) as T;
    }
    if (t == _isc.getType<_i0zg1hdn.Icinga2ConsumerStatus?>()) {
      return (data != null
              ? _i0zg1hdn.Icinga2ConsumerStatus.fromJson(data)
              : null)
          as T;
    }
    if (t == _isc.getType<_id40rhfu.Icinga2ConsumerSync?>()) {
      return (data != null
              ? _id40rhfu.Icinga2ConsumerSync.fromJson(data)
              : null)
          as T;
    }
    if (t == _isc.getType<_iil3cq3h.InvalidCursorException?>()) {
      return (data != null
              ? _iil3cq3h.InvalidCursorException.fromJson(data)
              : null)
          as T;
    }
    if (t == _isc.getType<_ibaui0zg.MappingPreviewDiagnostic?>()) {
      return (data != null
              ? _ibaui0zg.MappingPreviewDiagnostic.fromJson(data)
              : null)
          as T;
    }
    if (t == _isc.getType<_i20s3xik.MappingPreviewEvent?>()) {
      return (data != null
              ? _i20s3xik.MappingPreviewEvent.fromJson(data)
              : null)
          as T;
    }
    if (t == _isc.getType<_ines6tzx.MappingPreviewResult?>()) {
      return (data != null
              ? _ines6tzx.MappingPreviewResult.fromJson(data)
              : null)
          as T;
    }
    if (t == _isc.getType<_i2ozkwub.MappingPreviewValidationError?>()) {
      return (data != null
              ? _i2ozkwub.MappingPreviewValidationError.fromJson(data)
              : null)
          as T;
    }
    if (t == _isc.getType<_ik186lp1.MatcherFailureView?>()) {
      return (data != null ? _ik186lp1.MatcherFailureView.fromJson(data) : null)
          as T;
    }
    if (t == _isc.getType<_i2oitrdy.RuleSimulationResult?>()) {
      return (data != null
              ? _i2oitrdy.RuleSimulationResult.fromJson(data)
              : null)
          as T;
    }
    if (t == _isc.getType<_ingcfw9t.RuleTrace?>()) {
      return (data != null ? _ingcfw9t.RuleTrace.fromJson(data) : null) as T;
    }
    if (t == _isc.getType<_ieclo1rh.SimulatedLink?>()) {
      return (data != null ? _ieclo1rh.SimulatedLink.fromJson(data) : null)
          as T;
    }
    if (t == _isc.getType<_izi5l5xj.SimulationError?>()) {
      return (data != null ? _izi5l5xj.SimulationError.fromJson(data) : null)
          as T;
    }
    if (t == _isc.getType<_iy99nx4o.StoredEnrichmentError?>()) {
      return (data != null
              ? _iy99nx4o.StoredEnrichmentError.fromJson(data)
              : null)
          as T;
    }
    if (t == List<_i897ft9c.AlertView>) {
      return (data as List)
              .map((e) => deserialize<_i897ft9c.AlertView>(e))
              .toList()
          as T;
    }
    if (t == List<_iywqxrq6.FeedEntry>) {
      return (data as List)
              .map((e) => deserialize<_iywqxrq6.FeedEntry>(e))
              .toList()
          as T;
    }
    if (t == Map<String, int>) {
      return (data as Map).map(
            (k, v) => MapEntry(deserialize<String>(k), deserialize<int>(v)),
          )
          as T;
    }
    if (t == List<_i20s3xik.MappingPreviewEvent>) {
      return (data as List)
              .map((e) => deserialize<_i20s3xik.MappingPreviewEvent>(e))
              .toList()
          as T;
    }
    if (t == List<_ibaui0zg.MappingPreviewDiagnostic>) {
      return (data as List)
              .map((e) => deserialize<_ibaui0zg.MappingPreviewDiagnostic>(e))
              .toList()
          as T;
    }
    if (t == List<_ingcfw9t.RuleTrace>) {
      return (data as List)
              .map((e) => deserialize<_ingcfw9t.RuleTrace>(e))
              .toList()
          as T;
    }
    if (t == Map<String, String>) {
      return (data as Map).map(
            (k, v) => MapEntry(deserialize<String>(k), deserialize<String>(v)),
          )
          as T;
    }
    if (t == List<_ieclo1rh.SimulatedLink>) {
      return (data as List)
              .map((e) => deserialize<_ieclo1rh.SimulatedLink>(e))
              .toList()
          as T;
    }
    if (t == List<String>) {
      return (data as List).map((e) => deserialize<String>(e)).toList() as T;
    }
    if (t == _isc.getType<Map<String, String>?>()) {
      return (data != null
              ? (data as Map).map(
                  (k, v) =>
                      MapEntry(deserialize<String>(k), deserialize<String>(v)),
                )
              : null)
          as T;
    }
    if (t == List<_iy99nx4o.StoredEnrichmentError>) {
      return (data as List)
              .map((e) => deserialize<_iy99nx4o.StoredEnrichmentError>(e))
              .toList()
          as T;
    }
    if (t == _isc.getType<List<_iy99nx4o.StoredEnrichmentError>?>()) {
      return (data != null
              ? (data as List)
                    .map((e) => deserialize<_iy99nx4o.StoredEnrichmentError>(e))
                    .toList()
              : null)
          as T;
    }
    if (t == List<_i0ehnxud.ConditionTrace>) {
      return (data as List)
              .map((e) => deserialize<_i0ehnxud.ConditionTrace>(e))
              .toList()
          as T;
    }
    if (t == List<_ikn0wxo5.ActionTrace>) {
      return (data as List)
              .map((e) => deserialize<_ikn0wxo5.ActionTrace>(e))
              .toList()
          as T;
    }
    return super.deserialize<T>(data, t);
  }

  static String? getClassNameForType(Type type) {
    return switch (type) {
      _ikn0wxo5.ActionTrace => 'ActionTrace',
      _iz3t21fy.AlertSnapshot => 'AlertSnapshot',
      _i897ft9c.AlertView => 'AlertView',
      _i0ehnxud.ConditionTrace => 'ConditionTrace',
      _i25sduw2.ConsoleAccessDeniedException => 'ConsoleAccessDeniedException',
      _iywqxrq6.FeedEntry => 'FeedEntry',
      _ijrqdfur.FeedPage => 'FeedPage',
      _ivrec9rl.FeedWakeUp => 'FeedWakeUp',
      _i0zg1hdn.Icinga2ConsumerStatus => 'Icinga2ConsumerStatus',
      _id40rhfu.Icinga2ConsumerSync => 'Icinga2ConsumerSync',
      _iil3cq3h.InvalidCursorException => 'InvalidCursorException',
      _ibaui0zg.MappingPreviewDiagnostic => 'MappingPreviewDiagnostic',
      _i20s3xik.MappingPreviewEvent => 'MappingPreviewEvent',
      _ines6tzx.MappingPreviewResult => 'MappingPreviewResult',
      _i2ozkwub.MappingPreviewValidationError =>
        'MappingPreviewValidationError',
      _ik186lp1.MatcherFailureView => 'MatcherFailureView',
      _i2oitrdy.RuleSimulationResult => 'RuleSimulationResult',
      _ingcfw9t.RuleTrace => 'RuleTrace',
      _ieclo1rh.SimulatedLink => 'SimulatedLink',
      _izi5l5xj.SimulationError => 'SimulationError',
      _iy99nx4o.StoredEnrichmentError => 'StoredEnrichmentError',
      _ => null,
    };
  }

  @override
  String? getClassNameForObject(Object? data) {
    String? className = super.getClassNameForObject(data);
    if (className != null) return className;

    if (data is Map<String, dynamic> && data['__className__'] is String) {
      return (data['__className__'] as String).replaceFirst('correlia.', '');
    }

    switch (data) {
      case _ikn0wxo5.ActionTrace():
        return 'ActionTrace';
      case _iz3t21fy.AlertSnapshot():
        return 'AlertSnapshot';
      case _i897ft9c.AlertView():
        return 'AlertView';
      case _i0ehnxud.ConditionTrace():
        return 'ConditionTrace';
      case _i25sduw2.ConsoleAccessDeniedException():
        return 'ConsoleAccessDeniedException';
      case _iywqxrq6.FeedEntry():
        return 'FeedEntry';
      case _ijrqdfur.FeedPage():
        return 'FeedPage';
      case _ivrec9rl.FeedWakeUp():
        return 'FeedWakeUp';
      case _i0zg1hdn.Icinga2ConsumerStatus():
        return 'Icinga2ConsumerStatus';
      case _id40rhfu.Icinga2ConsumerSync():
        return 'Icinga2ConsumerSync';
      case _iil3cq3h.InvalidCursorException():
        return 'InvalidCursorException';
      case _ibaui0zg.MappingPreviewDiagnostic():
        return 'MappingPreviewDiagnostic';
      case _i20s3xik.MappingPreviewEvent():
        return 'MappingPreviewEvent';
      case _ines6tzx.MappingPreviewResult():
        return 'MappingPreviewResult';
      case _i2ozkwub.MappingPreviewValidationError():
        return 'MappingPreviewValidationError';
      case _ik186lp1.MatcherFailureView():
        return 'MatcherFailureView';
      case _i2oitrdy.RuleSimulationResult():
        return 'RuleSimulationResult';
      case _ingcfw9t.RuleTrace():
        return 'RuleTrace';
      case _ieclo1rh.SimulatedLink():
        return 'SimulatedLink';
      case _izi5l5xj.SimulationError():
        return 'SimulationError';
      case _iy99nx4o.StoredEnrichmentError():
        return 'StoredEnrichmentError';
    }
    return null;
  }

  @override
  dynamic deserializeByClassName(Map<String, dynamic> data) {
    var dataClassName = data['className'];
    if (dataClassName is! String) {
      return super.deserializeByClassName(data);
    }
    if (dataClassName == 'ActionTrace') {
      return deserialize<_ikn0wxo5.ActionTrace>(data['data']);
    }
    if (dataClassName == 'AlertSnapshot') {
      return deserialize<_iz3t21fy.AlertSnapshot>(data['data']);
    }
    if (dataClassName == 'AlertView') {
      return deserialize<_i897ft9c.AlertView>(data['data']);
    }
    if (dataClassName == 'ConditionTrace') {
      return deserialize<_i0ehnxud.ConditionTrace>(data['data']);
    }
    if (dataClassName == 'ConsoleAccessDeniedException') {
      return deserialize<_i25sduw2.ConsoleAccessDeniedException>(data['data']);
    }
    if (dataClassName == 'FeedEntry') {
      return deserialize<_iywqxrq6.FeedEntry>(data['data']);
    }
    if (dataClassName == 'FeedPage') {
      return deserialize<_ijrqdfur.FeedPage>(data['data']);
    }
    if (dataClassName == 'FeedWakeUp') {
      return deserialize<_ivrec9rl.FeedWakeUp>(data['data']);
    }
    if (dataClassName == 'Icinga2ConsumerStatus') {
      return deserialize<_i0zg1hdn.Icinga2ConsumerStatus>(data['data']);
    }
    if (dataClassName == 'Icinga2ConsumerSync') {
      return deserialize<_id40rhfu.Icinga2ConsumerSync>(data['data']);
    }
    if (dataClassName == 'InvalidCursorException') {
      return deserialize<_iil3cq3h.InvalidCursorException>(data['data']);
    }
    if (dataClassName == 'MappingPreviewDiagnostic') {
      return deserialize<_ibaui0zg.MappingPreviewDiagnostic>(data['data']);
    }
    if (dataClassName == 'MappingPreviewEvent') {
      return deserialize<_i20s3xik.MappingPreviewEvent>(data['data']);
    }
    if (dataClassName == 'MappingPreviewResult') {
      return deserialize<_ines6tzx.MappingPreviewResult>(data['data']);
    }
    if (dataClassName == 'MappingPreviewValidationError') {
      return deserialize<_i2ozkwub.MappingPreviewValidationError>(data['data']);
    }
    if (dataClassName == 'MatcherFailureView') {
      return deserialize<_ik186lp1.MatcherFailureView>(data['data']);
    }
    if (dataClassName == 'RuleSimulationResult') {
      return deserialize<_i2oitrdy.RuleSimulationResult>(data['data']);
    }
    if (dataClassName == 'RuleTrace') {
      return deserialize<_ingcfw9t.RuleTrace>(data['data']);
    }
    if (dataClassName == 'SimulatedLink') {
      return deserialize<_ieclo1rh.SimulatedLink>(data['data']);
    }
    if (dataClassName == 'SimulationError') {
      return deserialize<_izi5l5xj.SimulationError>(data['data']);
    }
    if (dataClassName == 'StoredEnrichmentError') {
      return deserialize<_iy99nx4o.StoredEnrichmentError>(data['data']);
    }
    return super.deserializeByClassName(data);
  }

  @override
  String getModuleName() => 'correlia';

  /// Maps any `Record`s known to this [Protocol] to their JSON representation
  ///
  /// Throws in case the record type is not known.
  ///
  /// This method will return `null` (only) for `null` inputs.
  Map<String, dynamic>? mapRecordToJson(Record? record) {
    if (record == null) {
      return null;
    }
    throw Exception('Unsupported record type ${record.runtimeType}');
  }
}

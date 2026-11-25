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
import 'alert_snapshot.dart' as _iz3t21fy;
import 'alert_view.dart' as _i897ft9c;
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
export 'alert_snapshot.dart';
export 'alert_view.dart';
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
          _isc.getType<_iz3t21fy.AlertSnapshot>,
          _isc.getType<_i897ft9c.AlertView>,
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
          _isc.getType<_iz3t21fy.AlertSnapshot?>,
          _isc.getType<_i897ft9c.AlertView?>,
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
          _isc.getType<List<_i897ft9c.AlertView>>,
          _isc.getType<List<_iywqxrq6.FeedEntry>>,
          _isc.getType<Map<String, int>>,
          _isc.getType<List<_i20s3xik.MappingPreviewEvent>>,
          _isc.getType<List<_ibaui0zg.MappingPreviewDiagnostic>>,
        ],
        modules: const [],
        classNames: const [
          'AlertSnapshot',
          'AlertView',
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

    if (t == _iz3t21fy.AlertSnapshot) {
      return _iz3t21fy.AlertSnapshot.fromJson(data) as T;
    }
    if (t == _i897ft9c.AlertView) {
      return _i897ft9c.AlertView.fromJson(data) as T;
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
    if (t == _isc.getType<_iz3t21fy.AlertSnapshot?>()) {
      return (data != null ? _iz3t21fy.AlertSnapshot.fromJson(data) : null)
          as T;
    }
    if (t == _isc.getType<_i897ft9c.AlertView?>()) {
      return (data != null ? _i897ft9c.AlertView.fromJson(data) : null) as T;
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
    return super.deserialize<T>(data, t);
  }

  static String? getClassNameForType(Type type) {
    return switch (type) {
      _iz3t21fy.AlertSnapshot => 'AlertSnapshot',
      _i897ft9c.AlertView => 'AlertView',
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
      case _iz3t21fy.AlertSnapshot():
        return 'AlertSnapshot';
      case _i897ft9c.AlertView():
        return 'AlertView';
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
    }
    return null;
  }

  @override
  dynamic deserializeByClassName(Map<String, dynamic> data) {
    var dataClassName = data['className'];
    if (dataClassName is! String) {
      return super.deserializeByClassName(data);
    }
    if (dataClassName == 'AlertSnapshot') {
      return deserialize<_iz3t21fy.AlertSnapshot>(data['data']);
    }
    if (dataClassName == 'AlertView') {
      return deserialize<_i897ft9c.AlertView>(data['data']);
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

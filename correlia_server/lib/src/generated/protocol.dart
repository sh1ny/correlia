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
import 'package:serverpod/protocol.dart' as _isp;
import 'package:serverpod/serverpod.dart' as _is;
import 'delivery_attempt.dart' as _ihd6gt0n;
import 'ingest_active_config.dart' as _ibsgqcqa;
import 'ingest_config_snapshot.dart' as _iwupdujg;
import 'ingest_secret_commitment.dart' as _iupiayjd;
import 'ingest_source.dart' as _inhmna33;
import 'observation_key.dart' as _ii70ink4;
import 'pipeline_failure.dart' as _ir1rifdz;
import 'transport_key.dart' as _ix76ovok;
export 'delivery_attempt.dart';
export 'ingest_active_config.dart';
export 'ingest_config_snapshot.dart';
export 'ingest_secret_commitment.dart';
export 'ingest_source.dart';
export 'observation_key.dart';
export 'pipeline_failure.dart';
export 'transport_key.dart';

class Protocol extends _is.DatabaseSerializationManager
    implements _is.DatabaseProtocolDeserializationProvider {
  Protocol._();

  factory Protocol() => _instance;

  static final Protocol _instance = Protocol._();

  @override
  _is.ProtocolDeserialization get deserializationMetadata =>
      _is.ProtocolDeserialization.cached(
        this,
        types: const [
          _is.getType<_ihd6gt0n.DeliveryAttempt>,
          _is.getType<_ibsgqcqa.IngestActiveConfig>,
          _is.getType<_iwupdujg.IngestConfigSnapshot>,
          _is.getType<_iupiayjd.IngestSecretCommitment>,
          _is.getType<_inhmna33.IngestSourceRow>,
          _is.getType<_ii70ink4.ObservationKeyRow>,
          _is.getType<_ir1rifdz.PipelineFailure>,
          _is.getType<_ix76ovok.TransportKey>,
          _is.getType<_ihd6gt0n.DeliveryAttempt?>,
          _is.getType<_ibsgqcqa.IngestActiveConfig?>,
          _is.getType<_iwupdujg.IngestConfigSnapshot?>,
          _is.getType<_iupiayjd.IngestSecretCommitment?>,
          _is.getType<_inhmna33.IngestSourceRow?>,
          _is.getType<_ii70ink4.ObservationKeyRow?>,
          _is.getType<_ir1rifdz.PipelineFailure?>,
          _is.getType<_ix76ovok.TransportKey?>,
        ],
        modules: const [_isp.Protocol.new],
        classNames: const [
          'DeliveryAttempt',
          'IngestActiveConfig',
          'IngestConfigSnapshot',
          'IngestSecretCommitment',
          'IngestSourceRow',
          'ObservationKeyRow',
          'PipelineFailure',
          'TransportKey',
        ],
      );

  static List<_isp.TableDefinition> get targetTableDefinitions => [
    _isp.TableDefinition(
      name: 'delivery_attempts',
      dartName: 'DeliveryAttempt',
      schema: 'public',
      module: 'correlia',
      columns: [
        _isp.ColumnDefinition(
          name: 'id',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int?',
          columnDefault: 'serial',
        ),
        _isp.ColumnDefinition(
          name: 'outboxCreatedAt',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: false,
          dartType: 'DateTime',
        ),
        _isp.ColumnDefinition(
          name: 'deliveryId',
          columnType: _isp.ColumnType.uuid,
          isNullable: false,
          dartType: 'UuidValue',
        ),
        _isp.ColumnDefinition(
          name: 'attemptNumber',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int',
        ),
        _isp.ColumnDefinition(
          name: 'claimId',
          columnType: _isp.ColumnType.uuid,
          isNullable: false,
          dartType: 'UuidValue',
        ),
        _isp.ColumnDefinition(
          name: 'startedAt',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: false,
          dartType: 'DateTime',
        ),
        _isp.ColumnDefinition(
          name: 'finishedAt',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: true,
          dartType: 'DateTime?',
        ),
        _isp.ColumnDefinition(
          name: 'outcome',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'errorClass',
          columnType: _isp.ColumnType.text,
          isNullable: true,
          dartType: 'String?',
        ),
      ],
      foreignKeys: [],
      indexes: [
        _isp.IndexDefinition(
          indexName: 'delivery_attempt_identity_idx',
          tableSpace: null,
          elements: [
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'outboxCreatedAt',
            ),
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'deliveryId',
            ),
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'attemptNumber',
            ),
          ],
          type: 'btree',
          isUnique: true,
          isPrimary: false,
        ),
      ],
      managed: true,
    ),
    _isp.TableDefinition(
      name: 'ingest_active_config',
      dartName: 'IngestActiveConfig',
      schema: 'public',
      module: 'correlia',
      columns: [
        _isp.ColumnDefinition(
          name: 'id',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int?',
          columnDefault: 'serial',
        ),
        _isp.ColumnDefinition(
          name: 'singleton',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int',
        ),
        _isp.ColumnDefinition(
          name: 'snapshotId',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
      ],
      foreignKeys: [],
      indexes: [
        _isp.IndexDefinition(
          indexName: 'ingest_active_config__singleton__unique_idx',
          tableSpace: null,
          elements: [
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'singleton',
            ),
          ],
          type: 'btree',
          isUnique: true,
          isPrimary: false,
        ),
      ],
      managed: true,
    ),
    _isp.TableDefinition(
      name: 'ingest_config_snapshot',
      dartName: 'IngestConfigSnapshot',
      schema: 'public',
      module: 'correlia',
      columns: [
        _isp.ColumnDefinition(
          name: 'id',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int?',
          columnDefault: 'serial',
        ),
        _isp.ColumnDefinition(
          name: 'snapshotId',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'revision',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int',
        ),
        _isp.ColumnDefinition(
          name: 'publicJson',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
      ],
      foreignKeys: [],
      indexes: [
        _isp.IndexDefinition(
          indexName: 'ingest_config_snapshot__snapshotId__unique_idx',
          tableSpace: null,
          elements: [
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'snapshotId',
            ),
          ],
          type: 'btree',
          isUnique: true,
          isPrimary: false,
        ),
        _isp.IndexDefinition(
          indexName: 'ingest_config_snapshot__revision__unique_idx',
          tableSpace: null,
          elements: [
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'revision',
            ),
          ],
          type: 'btree',
          isUnique: true,
          isPrimary: false,
        ),
      ],
      managed: true,
    ),
    _isp.TableDefinition(
      name: 'ingest_secret_commitment',
      dartName: 'IngestSecretCommitment',
      schema: 'public',
      module: 'correlia',
      columns: [
        _isp.ColumnDefinition(
          name: 'id',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int?',
          columnDefault: 'serial',
        ),
        _isp.ColumnDefinition(
          name: 'reference',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'digest',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
      ],
      foreignKeys: [],
      indexes: [
        _isp.IndexDefinition(
          indexName: 'ingest_secret_commitment__reference__unique_idx',
          tableSpace: null,
          elements: [
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'reference',
            ),
          ],
          type: 'btree',
          isUnique: true,
          isPrimary: false,
        ),
      ],
      managed: true,
    ),
    _isp.TableDefinition(
      name: 'ingest_source',
      dartName: 'IngestSourceRow',
      schema: 'public',
      module: 'correlia',
      columns: [
        _isp.ColumnDefinition(
          name: 'id',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int?',
          columnDefault: 'serial',
        ),
        _isp.ColumnDefinition(
          name: 'sourceId',
          columnType: _isp.ColumnType.uuid,
          isNullable: false,
          dartType: 'UuidValue',
        ),
        _isp.ColumnDefinition(
          name: 'tokenDigest',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'enabled',
          columnType: _isp.ColumnType.boolean,
          isNullable: false,
          dartType: 'bool',
        ),
        _isp.ColumnDefinition(
          name: 'allowPathToken',
          columnType: _isp.ColumnType.boolean,
          isNullable: false,
          dartType: 'bool',
        ),
      ],
      foreignKeys: [],
      indexes: [
        _isp.IndexDefinition(
          indexName: 'ingest_source__sourceId__unique_idx',
          tableSpace: null,
          elements: [
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'sourceId',
            ),
          ],
          type: 'btree',
          isUnique: true,
          isPrimary: false,
        ),
      ],
      managed: true,
    ),
    _isp.TableDefinition(
      name: 'observation_keys',
      dartName: 'ObservationKeyRow',
      schema: 'public',
      module: 'correlia',
      columns: [
        _isp.ColumnDefinition(
          name: 'id',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int?',
          columnDefault: 'serial',
        ),
        _isp.ColumnDefinition(
          name: 'eventId',
          columnType: _isp.ColumnType.uuid,
          isNullable: false,
          dartType: 'UuidValue',
        ),
        _isp.ColumnDefinition(
          name: 'fingerprint',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'sourceTime',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: false,
          dartType: 'DateTime',
        ),
        _isp.ColumnDefinition(
          name: 'firstSeenAt',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: false,
          dartType: 'DateTime',
        ),
        _isp.ColumnDefinition(
          name: 'disposition',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
      ],
      foreignKeys: [],
      indexes: [
        _isp.IndexDefinition(
          indexName: 'observation_keys__eventId__unique_idx',
          tableSpace: null,
          elements: [
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'eventId',
            ),
          ],
          type: 'btree',
          isUnique: true,
          isPrimary: false,
        ),
      ],
      managed: true,
    ),
    _isp.TableDefinition(
      name: 'pipeline_failures',
      dartName: 'PipelineFailure',
      schema: 'public',
      module: 'correlia',
      columns: [
        _isp.ColumnDefinition(
          name: 'id',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int?',
          columnDefault: 'serial',
        ),
        _isp.ColumnDefinition(
          name: 'rawObservedAt',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: false,
          dartType: 'DateTime',
        ),
        _isp.ColumnDefinition(
          name: 'rawId',
          columnType: _isp.ColumnType.uuid,
          isNullable: false,
          dartType: 'UuidValue',
        ),
        _isp.ColumnDefinition(
          name: 'configSnapshotId',
          columnType: _isp.ColumnType.text,
          isNullable: true,
          dartType: 'String?',
        ),
        _isp.ColumnDefinition(
          name: 'errorClass',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'fieldPath',
          columnType: _isp.ColumnType.text,
          isNullable: true,
          dartType: 'String?',
        ),
        _isp.ColumnDefinition(
          name: 'createdAt',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: false,
          dartType: 'DateTime',
        ),
      ],
      foreignKeys: [],
      indexes: [],
      managed: true,
    ),
    _isp.TableDefinition(
      name: 'transport_keys',
      dartName: 'TransportKey',
      schema: 'public',
      module: 'correlia',
      columns: [
        _isp.ColumnDefinition(
          name: 'id',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int?',
          columnDefault: 'serial',
        ),
        _isp.ColumnDefinition(
          name: 'sourceId',
          columnType: _isp.ColumnType.uuid,
          isNullable: false,
          dartType: 'UuidValue',
        ),
        _isp.ColumnDefinition(
          name: 'key',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'bodySha256',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'firstSeenAt',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: false,
          dartType: 'DateTime',
        ),
        _isp.ColumnDefinition(
          name: 'expiresAt',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: false,
          dartType: 'DateTime',
        ),
        _isp.ColumnDefinition(
          name: 'rawObservedAt',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: false,
          dartType: 'DateTime',
        ),
        _isp.ColumnDefinition(
          name: 'rawId',
          columnType: _isp.ColumnType.uuid,
          isNullable: false,
          dartType: 'UuidValue',
        ),
      ],
      foreignKeys: [],
      indexes: [
        _isp.IndexDefinition(
          indexName: 'transport_source_key_idx',
          tableSpace: null,
          elements: [
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'sourceId',
            ),
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'key',
            ),
          ],
          type: 'btree',
          isUnique: true,
          isPrimary: false,
        ),
      ],
      managed: true,
    ),
    ..._isp.Protocol.targetTableDefinitions,
  ];

  static String? getClassNameFromObjectJson(dynamic data) =>
      _is.ProtocolDeserialization.readClassName(data);

  @override
  T deserialize<T>(
    dynamic data, [
    Type? t,
  ]) {
    t ??= T;
    final rawDataClassName = _is.ProtocolDeserialization.readClassName(data);
    final dataClassName = rawDataClassName;
    if (dataClassName != null && dataClassName != getClassNameForType(t)) {
      try {
        return deserializeByClassName({
          'className': dataClassName,
          'data': data,
        });
      } on _is.DeserializationClassNameNotFoundException catch (_) {
        // If the className is not recognized (e.g., older client receiving
        // data with a new subtype), fall back to deserializing without the
        // className, using the expected type T.
      }
    }

    if (t == _ihd6gt0n.DeliveryAttempt) {
      return _ihd6gt0n.DeliveryAttempt.fromJson(data) as T;
    }
    if (t == _ibsgqcqa.IngestActiveConfig) {
      return _ibsgqcqa.IngestActiveConfig.fromJson(data) as T;
    }
    if (t == _iwupdujg.IngestConfigSnapshot) {
      return _iwupdujg.IngestConfigSnapshot.fromJson(data) as T;
    }
    if (t == _iupiayjd.IngestSecretCommitment) {
      return _iupiayjd.IngestSecretCommitment.fromJson(data) as T;
    }
    if (t == _inhmna33.IngestSourceRow) {
      return _inhmna33.IngestSourceRow.fromJson(data) as T;
    }
    if (t == _ii70ink4.ObservationKeyRow) {
      return _ii70ink4.ObservationKeyRow.fromJson(data) as T;
    }
    if (t == _ir1rifdz.PipelineFailure) {
      return _ir1rifdz.PipelineFailure.fromJson(data) as T;
    }
    if (t == _ix76ovok.TransportKey) {
      return _ix76ovok.TransportKey.fromJson(data) as T;
    }
    if (t == _is.getType<_ihd6gt0n.DeliveryAttempt?>()) {
      return (data != null ? _ihd6gt0n.DeliveryAttempt.fromJson(data) : null)
          as T;
    }
    if (t == _is.getType<_ibsgqcqa.IngestActiveConfig?>()) {
      return (data != null ? _ibsgqcqa.IngestActiveConfig.fromJson(data) : null)
          as T;
    }
    if (t == _is.getType<_iwupdujg.IngestConfigSnapshot?>()) {
      return (data != null
              ? _iwupdujg.IngestConfigSnapshot.fromJson(data)
              : null)
          as T;
    }
    if (t == _is.getType<_iupiayjd.IngestSecretCommitment?>()) {
      return (data != null
              ? _iupiayjd.IngestSecretCommitment.fromJson(data)
              : null)
          as T;
    }
    if (t == _is.getType<_inhmna33.IngestSourceRow?>()) {
      return (data != null ? _inhmna33.IngestSourceRow.fromJson(data) : null)
          as T;
    }
    if (t == _is.getType<_ii70ink4.ObservationKeyRow?>()) {
      return (data != null ? _ii70ink4.ObservationKeyRow.fromJson(data) : null)
          as T;
    }
    if (t == _is.getType<_ir1rifdz.PipelineFailure?>()) {
      return (data != null ? _ir1rifdz.PipelineFailure.fromJson(data) : null)
          as T;
    }
    if (t == _is.getType<_ix76ovok.TransportKey?>()) {
      return (data != null ? _ix76ovok.TransportKey.fromJson(data) : null) as T;
    }
    final modules = deserializationMetadata.modulesForDeserialization(
      t,
      className: rawDataClassName,
    );
    for (final module in modules) {
      try {
        return module.deserialize<T>(data, t);
      } on _is.DeserializationTypeNotFoundException catch (_) {}
    }

    return super.deserialize<T>(data, t);
  }

  static String? getClassNameForType(Type type) {
    return switch (type) {
      _ihd6gt0n.DeliveryAttempt => 'DeliveryAttempt',
      _ibsgqcqa.IngestActiveConfig => 'IngestActiveConfig',
      _iwupdujg.IngestConfigSnapshot => 'IngestConfigSnapshot',
      _iupiayjd.IngestSecretCommitment => 'IngestSecretCommitment',
      _inhmna33.IngestSourceRow => 'IngestSourceRow',
      _ii70ink4.ObservationKeyRow => 'ObservationKeyRow',
      _ir1rifdz.PipelineFailure => 'PipelineFailure',
      _ix76ovok.TransportKey => 'TransportKey',
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
      case _ihd6gt0n.DeliveryAttempt():
        return 'DeliveryAttempt';
      case _ibsgqcqa.IngestActiveConfig():
        return 'IngestActiveConfig';
      case _iwupdujg.IngestConfigSnapshot():
        return 'IngestConfigSnapshot';
      case _iupiayjd.IngestSecretCommitment():
        return 'IngestSecretCommitment';
      case _inhmna33.IngestSourceRow():
        return 'IngestSourceRow';
      case _ii70ink4.ObservationKeyRow():
        return 'ObservationKeyRow';
      case _ir1rifdz.PipelineFailure():
        return 'PipelineFailure';
      case _ix76ovok.TransportKey():
        return 'TransportKey';
    }
    className = _isp.Protocol().getClassNameForObject(data);
    if (className != null) {
      return className.contains('.') ? className : 'serverpod.$className';
    }
    return null;
  }

  @override
  dynamic deserializeByClassName(Map<String, dynamic> data) {
    var dataClassName = data['className'];
    if (dataClassName is! String) {
      return super.deserializeByClassName(data);
    }
    if (dataClassName == 'DeliveryAttempt') {
      return deserialize<_ihd6gt0n.DeliveryAttempt>(data['data']);
    }
    if (dataClassName == 'IngestActiveConfig') {
      return deserialize<_ibsgqcqa.IngestActiveConfig>(data['data']);
    }
    if (dataClassName == 'IngestConfigSnapshot') {
      return deserialize<_iwupdujg.IngestConfigSnapshot>(data['data']);
    }
    if (dataClassName == 'IngestSecretCommitment') {
      return deserialize<_iupiayjd.IngestSecretCommitment>(data['data']);
    }
    if (dataClassName == 'IngestSourceRow') {
      return deserialize<_inhmna33.IngestSourceRow>(data['data']);
    }
    if (dataClassName == 'ObservationKeyRow') {
      return deserialize<_ii70ink4.ObservationKeyRow>(data['data']);
    }
    if (dataClassName == 'PipelineFailure') {
      return deserialize<_ir1rifdz.PipelineFailure>(data['data']);
    }
    if (dataClassName == 'TransportKey') {
      return deserialize<_ix76ovok.TransportKey>(data['data']);
    }
    if (dataClassName.startsWith('serverpod.')) {
      return _isp.Protocol().deserializeByClassName({
        ...data,
        'className': dataClassName.substring(10),
      });
    }
    return super.deserializeByClassName(data);
  }

  @override
  _is.Table? getTableForType(Type t) {
    {
      var table = _isp.Protocol().getTableForType(t);
      if (table != null) {
        return table;
      }
    }
    switch (t) {
      case _ihd6gt0n.DeliveryAttempt:
        return _ihd6gt0n.DeliveryAttempt.t;
      case _ibsgqcqa.IngestActiveConfig:
        return _ibsgqcqa.IngestActiveConfig.t;
      case _iwupdujg.IngestConfigSnapshot:
        return _iwupdujg.IngestConfigSnapshot.t;
      case _iupiayjd.IngestSecretCommitment:
        return _iupiayjd.IngestSecretCommitment.t;
      case _inhmna33.IngestSourceRow:
        return _inhmna33.IngestSourceRow.t;
      case _ii70ink4.ObservationKeyRow:
        return _ii70ink4.ObservationKeyRow.t;
      case _ir1rifdz.PipelineFailure:
        return _ir1rifdz.PipelineFailure.t;
      case _ix76ovok.TransportKey:
        return _ix76ovok.TransportKey.t;
    }
    return null;
  }

  @override
  List<_isp.TableDefinition> getTargetTableDefinitions() =>
      targetTableDefinitions;

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
    try {
      return _isp.Protocol().mapRecordToJson(record);
    } catch (_) {}
    throw Exception('Unsupported record type ${record.runtimeType}');
  }
}

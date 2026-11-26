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
import 'alert.dart' as _iqmz6gj4;
import 'alert_snapshot.dart' as _iz3t21fy;
import 'alert_view.dart' as _i897ft9c;
import 'console_access_denied_exception.dart' as _i25sduw2;
import 'delivery_attempt.dart' as _ihd6gt0n;
import 'feed_entry.dart' as _iywqxrq6;
import 'feed_page.dart' as _ijrqdfur;
import 'feed_wake_up.dart' as _ivrec9rl;
import 'icinga2_admitted_batch.dart' as _iyvfq7h8;
import 'icinga2_consumer_status.dart' as _i0zg1hdn;
import 'icinga2_consumer_sync.dart' as _id40rhfu;
import 'icinga2_stream_lease.dart' as _iwydjvnk;
import 'icinga2_stream_resync.dart' as _i6orwhmp;
import 'icinga2_stream_status.dart' as _iph5wq9a;
import 'ingest_active_config.dart' as _ibsgqcqa;
import 'ingest_config_snapshot.dart' as _iwupdujg;
import 'ingest_secret_commitment.dart' as _iupiayjd;
import 'ingest_source.dart' as _inhmna33;
import 'ingest_source_credential.dart' as _ib6287mr;
import 'invalid_cursor_exception.dart' as _iil3cq3h;
import 'mapping_preview_diagnostic.dart' as _ibaui0zg;
import 'mapping_preview_event.dart' as _i20s3xik;
import 'mapping_preview_result.dart' as _ines6tzx;
import 'mapping_preview_validation_error.dart' as _i2ozkwub;
import 'matcher_failure_view.dart' as _ik186lp1;
import 'observation_key.dart' as _ii70ink4;
import 'pipeline_failure.dart' as _ir1rifdz;
import 'plugin_definition_health.dart' as _iqfe2rop;
import 'plugin_instance_status.dart' as _i5barlkw;
import 'queue/queue_failure.dart' as _i1399vez;
import 'queue/queue_failure_filter.dart' as _i3paal6y;
import 'queue/queue_failure_kind.dart' as _ijk6hojr;
import 'queue/queue_failure_page.dart' as _io00fnfh;
import 'queue/queue_maintenance_status.dart' as _ip4smbu4;
import 'queue/queue_operator_exception.dart' as _i9vx28ve;
import 'queue/queue_output_status.dart' as _ie72o327;
import 'queue/queue_replay_item.dart' as _i738ir7t;
import 'queue/queue_replay_result.dart' as _ikvpqw3q;
import 'queue/queue_status.dart' as _iylzdl71;
import 'secret_record.dart' as _ibz1p89x;
import 'transport_key.dart' as _ix76ovok;
export 'alert.dart';
export 'alert_snapshot.dart';
export 'alert_view.dart';
export 'console_access_denied_exception.dart';
export 'delivery_attempt.dart';
export 'feed_entry.dart';
export 'feed_page.dart';
export 'feed_wake_up.dart';
export 'icinga2_admitted_batch.dart';
export 'icinga2_consumer_status.dart';
export 'icinga2_consumer_sync.dart';
export 'icinga2_stream_lease.dart';
export 'icinga2_stream_resync.dart';
export 'icinga2_stream_status.dart';
export 'ingest_active_config.dart';
export 'ingest_config_snapshot.dart';
export 'ingest_secret_commitment.dart';
export 'ingest_source.dart';
export 'ingest_source_credential.dart';
export 'invalid_cursor_exception.dart';
export 'mapping_preview_diagnostic.dart';
export 'mapping_preview_event.dart';
export 'mapping_preview_result.dart';
export 'mapping_preview_validation_error.dart';
export 'matcher_failure_view.dart';
export 'observation_key.dart';
export 'pipeline_failure.dart';
export 'plugin_definition_health.dart';
export 'plugin_instance_status.dart';
export 'queue/queue_failure.dart';
export 'queue/queue_failure_filter.dart';
export 'queue/queue_failure_kind.dart';
export 'queue/queue_failure_page.dart';
export 'queue/queue_maintenance_status.dart';
export 'queue/queue_operator_exception.dart';
export 'queue/queue_output_status.dart';
export 'queue/queue_replay_item.dart';
export 'queue/queue_replay_result.dart';
export 'queue/queue_status.dart';
export 'secret_record.dart';
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
          _is.getType<_iqmz6gj4.AlertRow>,
          _is.getType<_iz3t21fy.AlertSnapshot>,
          _is.getType<_i897ft9c.AlertView>,
          _is.getType<_i25sduw2.ConsoleAccessDeniedException>,
          _is.getType<_ihd6gt0n.DeliveryAttempt>,
          _is.getType<_iywqxrq6.FeedEntry>,
          _is.getType<_ijrqdfur.FeedPage>,
          _is.getType<_ivrec9rl.FeedWakeUp>,
          _is.getType<_iyvfq7h8.Icinga2AdmittedBatch>,
          _is.getType<_i0zg1hdn.Icinga2ConsumerStatus>,
          _is.getType<_id40rhfu.Icinga2ConsumerSync>,
          _is.getType<_iwydjvnk.Icinga2StreamLeaseRow>,
          _is.getType<_i6orwhmp.Icinga2StreamResyncRow>,
          _is.getType<_iph5wq9a.Icinga2StreamStatusRow>,
          _is.getType<_ibsgqcqa.IngestActiveConfig>,
          _is.getType<_iwupdujg.IngestConfigSnapshot>,
          _is.getType<_iupiayjd.IngestSecretCommitment>,
          _is.getType<_inhmna33.IngestSourceRow>,
          _is.getType<_ib6287mr.IngestSourceCredential>,
          _is.getType<_iil3cq3h.InvalidCursorException>,
          _is.getType<_ibaui0zg.MappingPreviewDiagnostic>,
          _is.getType<_i20s3xik.MappingPreviewEvent>,
          _is.getType<_ines6tzx.MappingPreviewResult>,
          _is.getType<_i2ozkwub.MappingPreviewValidationError>,
          _is.getType<_ik186lp1.MatcherFailureView>,
          _is.getType<_ii70ink4.ObservationKeyRow>,
          _is.getType<_ir1rifdz.PipelineFailure>,
          _is.getType<_iqfe2rop.PluginDefinitionHealth>,
          _is.getType<_i5barlkw.PluginInstanceStatus>,
          _is.getType<_i1399vez.QueueFailure>,
          _is.getType<_i3paal6y.QueueFailureFilter>,
          _is.getType<_ijk6hojr.QueueFailureKind>,
          _is.getType<_io00fnfh.QueueFailurePage>,
          _is.getType<_ip4smbu4.QueueMaintenanceStatus>,
          _is.getType<_i9vx28ve.QueueOperatorException>,
          _is.getType<_ie72o327.QueueOutputStatus>,
          _is.getType<_i738ir7t.QueueReplayItem>,
          _is.getType<_ikvpqw3q.QueueReplayResult>,
          _is.getType<_iylzdl71.QueueStatus>,
          _is.getType<_ibz1p89x.SecretRecord>,
          _is.getType<_ix76ovok.TransportKey>,
          _is.getType<_iqmz6gj4.AlertRow?>,
          _is.getType<_iz3t21fy.AlertSnapshot?>,
          _is.getType<_i897ft9c.AlertView?>,
          _is.getType<_i25sduw2.ConsoleAccessDeniedException?>,
          _is.getType<_ihd6gt0n.DeliveryAttempt?>,
          _is.getType<_iywqxrq6.FeedEntry?>,
          _is.getType<_ijrqdfur.FeedPage?>,
          _is.getType<_ivrec9rl.FeedWakeUp?>,
          _is.getType<_iyvfq7h8.Icinga2AdmittedBatch?>,
          _is.getType<_i0zg1hdn.Icinga2ConsumerStatus?>,
          _is.getType<_id40rhfu.Icinga2ConsumerSync?>,
          _is.getType<_iwydjvnk.Icinga2StreamLeaseRow?>,
          _is.getType<_i6orwhmp.Icinga2StreamResyncRow?>,
          _is.getType<_iph5wq9a.Icinga2StreamStatusRow?>,
          _is.getType<_ibsgqcqa.IngestActiveConfig?>,
          _is.getType<_iwupdujg.IngestConfigSnapshot?>,
          _is.getType<_iupiayjd.IngestSecretCommitment?>,
          _is.getType<_inhmna33.IngestSourceRow?>,
          _is.getType<_ib6287mr.IngestSourceCredential?>,
          _is.getType<_iil3cq3h.InvalidCursorException?>,
          _is.getType<_ibaui0zg.MappingPreviewDiagnostic?>,
          _is.getType<_i20s3xik.MappingPreviewEvent?>,
          _is.getType<_ines6tzx.MappingPreviewResult?>,
          _is.getType<_i2ozkwub.MappingPreviewValidationError?>,
          _is.getType<_ik186lp1.MatcherFailureView?>,
          _is.getType<_ii70ink4.ObservationKeyRow?>,
          _is.getType<_ir1rifdz.PipelineFailure?>,
          _is.getType<_iqfe2rop.PluginDefinitionHealth?>,
          _is.getType<_i5barlkw.PluginInstanceStatus?>,
          _is.getType<_i1399vez.QueueFailure?>,
          _is.getType<_i3paal6y.QueueFailureFilter?>,
          _is.getType<_ijk6hojr.QueueFailureKind?>,
          _is.getType<_io00fnfh.QueueFailurePage?>,
          _is.getType<_ip4smbu4.QueueMaintenanceStatus?>,
          _is.getType<_i9vx28ve.QueueOperatorException?>,
          _is.getType<_ie72o327.QueueOutputStatus?>,
          _is.getType<_i738ir7t.QueueReplayItem?>,
          _is.getType<_ikvpqw3q.QueueReplayResult?>,
          _is.getType<_iylzdl71.QueueStatus?>,
          _is.getType<_ibz1p89x.SecretRecord?>,
          _is.getType<_ix76ovok.TransportKey?>,
          _is.getType<List<_i897ft9c.AlertView>>,
          _is.getType<List<_iywqxrq6.FeedEntry>>,
          _is.getType<Map<String, int>>,
          _is.getType<List<_i20s3xik.MappingPreviewEvent>>,
          _is.getType<List<_ibaui0zg.MappingPreviewDiagnostic>>,
          _is.getType<List<_i1399vez.QueueFailure>>,
          _is.getType<List<_i738ir7t.QueueReplayItem>>,
          _is.getType<List<_ie72o327.QueueOutputStatus>>,
          _is.getType<List<_ip4smbu4.QueueMaintenanceStatus>>,
        ],
        modules: const [_isp.Protocol.new],
        classNames: const [
          'AlertRow',
          'AlertSnapshot',
          'AlertView',
          'ConsoleAccessDeniedException',
          'DeliveryAttempt',
          'FeedEntry',
          'FeedPage',
          'FeedWakeUp',
          'Icinga2AdmittedBatch',
          'Icinga2ConsumerStatus',
          'Icinga2ConsumerSync',
          'Icinga2StreamLeaseRow',
          'Icinga2StreamResyncRow',
          'Icinga2StreamStatusRow',
          'IngestActiveConfig',
          'IngestConfigSnapshot',
          'IngestSecretCommitment',
          'IngestSourceRow',
          'IngestSourceCredential',
          'InvalidCursorException',
          'MappingPreviewDiagnostic',
          'MappingPreviewEvent',
          'MappingPreviewResult',
          'MappingPreviewValidationError',
          'MatcherFailureView',
          'ObservationKeyRow',
          'PipelineFailure',
          'PluginDefinitionHealth',
          'PluginInstanceStatus',
          'QueueFailure',
          'QueueFailureFilter',
          'QueueFailureKind',
          'QueueFailurePage',
          'QueueMaintenanceStatus',
          'QueueOperatorException',
          'QueueOutputStatus',
          'QueueReplayItem',
          'QueueReplayResult',
          'QueueStatus',
          'SecretRecord',
          'TransportKey',
        ],
      );

  static List<_isp.TableDefinition> get targetTableDefinitions => [
    _isp.TableDefinition(
      name: 'alerts',
      dartName: 'AlertRow',
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
          name: 'tenant',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'fingerprint',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'status',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'severity',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'summary',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'sourceInstance',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'firingSince',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: true,
          dartType: 'DateTime?',
        ),
        _isp.ColumnDefinition(
          name: 'generatorUrl',
          columnType: _isp.ColumnType.text,
          isNullable: true,
          dartType: 'String?',
        ),
        _isp.ColumnDefinition(
          name: 'fenceEffectiveSeconds',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int',
        ),
        _isp.ColumnDefinition(
          name: 'fenceEffectiveNanos',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int',
        ),
        _isp.ColumnDefinition(
          name: 'fenceObservedSeconds',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int',
        ),
        _isp.ColumnDefinition(
          name: 'fenceObservedNanos',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int',
        ),
        _isp.ColumnDefinition(
          name: 'fenceEventId',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'lastObservedAt',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: false,
          dartType: 'DateTime',
        ),
        _isp.ColumnDefinition(
          name: 'version',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int',
        ),
        _isp.ColumnDefinition(
          name: 'createdAt',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: false,
          dartType: 'DateTime',
        ),
        _isp.ColumnDefinition(
          name: 'updatedAt',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: false,
          dartType: 'DateTime',
        ),
      ],
      foreignKeys: [],
      indexes: [
        _isp.IndexDefinition(
          indexName: 'alerts_tenant_fingerprint_idx',
          tableSpace: null,
          elements: [
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'tenant',
            ),
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'fingerprint',
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
      name: 'icinga2_admitted_batch',
      dartName: 'Icinga2AdmittedBatch',
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
          name: 'batchId',
          columnType: _isp.ColumnType.uuid,
          isNullable: false,
          dartType: 'UuidValue',
        ),
        _isp.ColumnDefinition(
          name: 'admittedAt',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: false,
          dartType: 'DateTime',
        ),
      ],
      foreignKeys: [],
      indexes: [
        _isp.IndexDefinition(
          indexName: 'icinga2_admitted_batch_source_id_idx',
          tableSpace: null,
          elements: [
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'sourceId',
            ),
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'batchId',
            ),
          ],
          type: 'btree',
          isUnique: true,
          isPrimary: false,
        ),
        _isp.IndexDefinition(
          indexName: 'icinga2_admitted_batch_expiry_idx',
          tableSpace: null,
          elements: [
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'admittedAt',
            ),
          ],
          type: 'btree',
          isUnique: false,
          isPrimary: false,
        ),
      ],
      managed: true,
    ),
    _isp.TableDefinition(
      name: 'icinga2_stream_lease',
      dartName: 'Icinga2StreamLeaseRow',
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
          name: 'holder',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'generation',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int',
        ),
        _isp.ColumnDefinition(
          name: 'expiresAt',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: false,
          dartType: 'DateTime',
        ),
      ],
      foreignKeys: [],
      indexes: [
        _isp.IndexDefinition(
          indexName: 'icinga2_stream_lease__sourceId__unique_idx',
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
      name: 'icinga2_stream_resync',
      dartName: 'Icinga2StreamResyncRow',
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
          name: 'requestSeq',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int',
          columnDefault: '0',
        ),
      ],
      foreignKeys: [],
      indexes: [
        _isp.IndexDefinition(
          indexName: 'icinga2_stream_resync__sourceId__unique_idx',
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
      name: 'icinga2_stream_status',
      dartName: 'Icinga2StreamStatusRow',
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
          name: 'state',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'connectionId',
          columnType: _isp.ColumnType.text,
          isNullable: true,
          dartType: 'String?',
        ),
        _isp.ColumnDefinition(
          name: 'connectionSeq',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int',
          columnDefault: '0',
        ),
        _isp.ColumnDefinition(
          name: 'connectedAt',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: true,
          dartType: 'DateTime?',
        ),
        _isp.ColumnDefinition(
          name: 'lastEventAt',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: true,
          dartType: 'DateTime?',
        ),
        _isp.ColumnDefinition(
          name: 'gapCount',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int',
          columnDefault: '0',
        ),
        _isp.ColumnDefinition(
          name: 'lastGapSeq',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int',
          columnDefault: '0',
        ),
        _isp.ColumnDefinition(
          name: 'lastGapAt',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: true,
          dartType: 'DateTime?',
        ),
        _isp.ColumnDefinition(
          name: 'oversizeLines',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int',
          columnDefault: '0',
        ),
        _isp.ColumnDefinition(
          name: 'lagMs',
          columnType: _isp.ColumnType.bigint,
          isNullable: true,
          dartType: 'int?',
        ),
        _isp.ColumnDefinition(
          name: 'lastErrorClass',
          columnType: _isp.ColumnType.text,
          isNullable: true,
          dartType: 'String?',
        ),
        _isp.ColumnDefinition(
          name: 'servedResyncSeq',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int',
          columnDefault: '0',
        ),
        _isp.ColumnDefinition(
          name: 'syncTimeoutsInARow',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int',
          columnDefault: '0',
        ),
        _isp.ColumnDefinition(
          name: 'currentSyncId',
          columnType: _isp.ColumnType.uuid,
          isNullable: true,
          dartType: 'UuidValue?',
        ),
        _isp.ColumnDefinition(
          name: 'lastSyncId',
          columnType: _isp.ColumnType.uuid,
          isNullable: true,
          dartType: 'UuidValue?',
        ),
      ],
      foreignKeys: [],
      indexes: [
        _isp.IndexDefinition(
          indexName: 'icinga2_stream_status__sourceId__unique_idx',
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
          name: 'kind',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
          columnDefault: '\'alertmanager\'',
        ),
        _isp.ColumnDefinition(
          name: 'mode',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
          columnDefault: '\'webhook\'',
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
      name: 'ingest_source_credential',
      dartName: 'IngestSourceCredential',
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
          name: 'reference',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'type',
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
        _isp.ColumnDefinition(
          name: 'notBefore',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: true,
          dartType: 'DateTime?',
        ),
        _isp.ColumnDefinition(
          name: 'notAfter',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: true,
          dartType: 'DateTime?',
        ),
      ],
      foreignKeys: [],
      indexes: [
        _isp.IndexDefinition(
          indexName: 'ingest_source_credential_source_ref',
          tableSpace: null,
          elements: [
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'sourceId',
            ),
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
      name: 'plugin_definition_health',
      dartName: 'PluginDefinitionHealth',
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
          name: 'hostInstanceId',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'outputId',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'definitionDigest',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'failureTimes',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'backoffStep',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int',
        ),
        _isp.ColumnDefinition(
          name: 'nextStartAt',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: true,
          dartType: 'DateTime?',
        ),
        _isp.ColumnDefinition(
          name: 'circuit',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'nextProbeAt',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: true,
          dartType: 'DateTime?',
        ),
        _isp.ColumnDefinition(
          name: 'lastErrorClass',
          columnType: _isp.ColumnType.text,
          isNullable: true,
          dartType: 'String?',
        ),
      ],
      foreignKeys: [],
      indexes: [
        _isp.IndexDefinition(
          indexName: 'plugin_definition_health_owner_definition_idx',
          tableSpace: null,
          elements: [
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'hostInstanceId',
            ),
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'outputId',
            ),
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'definitionDigest',
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
      name: 'plugin_instance_status',
      dartName: 'PluginInstanceStatus',
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
          name: 'hostInstanceId',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'outputId',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'definitionDigest',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'state',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'pluginName',
          columnType: _isp.ColumnType.text,
          isNullable: true,
          dartType: 'String?',
        ),
        _isp.ColumnDefinition(
          name: 'pluginVersion',
          columnType: _isp.ColumnType.text,
          isNullable: true,
          dartType: 'String?',
        ),
        _isp.ColumnDefinition(
          name: 'pid',
          columnType: _isp.ColumnType.bigint,
          isNullable: true,
          dartType: 'int?',
        ),
        _isp.ColumnDefinition(
          name: 'restartCount',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int',
        ),
        _isp.ColumnDefinition(
          name: 'crashesInWindow',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int',
        ),
        _isp.ColumnDefinition(
          name: 'lastErrorClass',
          columnType: _isp.ColumnType.text,
          isNullable: true,
          dartType: 'String?',
        ),
        _isp.ColumnDefinition(
          name: 'lastPluginErrorClass',
          columnType: _isp.ColumnType.text,
          isNullable: true,
          dartType: 'String?',
        ),
        _isp.ColumnDefinition(
          name: 'version',
          columnType: _isp.ColumnType.bigint,
          isNullable: false,
          dartType: 'int',
        ),
        _isp.ColumnDefinition(
          name: 'heartbeatAt',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: false,
          dartType: 'DateTime',
        ),
      ],
      foreignKeys: [],
      indexes: [
        _isp.IndexDefinition(
          indexName: 'plugin_instance_status_owner_definition_idx',
          tableSpace: null,
          elements: [
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'hostInstanceId',
            ),
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'outputId',
            ),
            _isp.IndexElementDefinition(
              type: _isp.IndexElementDefinitionType.column,
              definition: 'definitionDigest',
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
      name: 'secret_record',
      dartName: 'SecretRecord',
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
          name: 'algorithm',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'nonce',
          columnType: _isp.ColumnType.bytea,
          isNullable: false,
          dartType: 'dart:typed_data:ByteData',
        ),
        _isp.ColumnDefinition(
          name: 'ciphertext',
          columnType: _isp.ColumnType.bytea,
          isNullable: false,
          dartType: 'dart:typed_data:ByteData',
        ),
        _isp.ColumnDefinition(
          name: 'commitment',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'keyCommitment',
          columnType: _isp.ColumnType.text,
          isNullable: false,
          dartType: 'String',
        ),
        _isp.ColumnDefinition(
          name: 'createdAt',
          columnType: _isp.ColumnType.timestampWithoutTimeZone,
          isNullable: false,
          dartType: 'DateTime',
        ),
      ],
      foreignKeys: [],
      indexes: [
        _isp.IndexDefinition(
          indexName: 'secret_record__reference__unique_idx',
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

    if (t == _iqmz6gj4.AlertRow) {
      return _iqmz6gj4.AlertRow.fromJson(data) as T;
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
    if (t == _ihd6gt0n.DeliveryAttempt) {
      return _ihd6gt0n.DeliveryAttempt.fromJson(data) as T;
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
    if (t == _iyvfq7h8.Icinga2AdmittedBatch) {
      return _iyvfq7h8.Icinga2AdmittedBatch.fromJson(data) as T;
    }
    if (t == _i0zg1hdn.Icinga2ConsumerStatus) {
      return _i0zg1hdn.Icinga2ConsumerStatus.fromJson(data) as T;
    }
    if (t == _id40rhfu.Icinga2ConsumerSync) {
      return _id40rhfu.Icinga2ConsumerSync.fromJson(data) as T;
    }
    if (t == _iwydjvnk.Icinga2StreamLeaseRow) {
      return _iwydjvnk.Icinga2StreamLeaseRow.fromJson(data) as T;
    }
    if (t == _i6orwhmp.Icinga2StreamResyncRow) {
      return _i6orwhmp.Icinga2StreamResyncRow.fromJson(data) as T;
    }
    if (t == _iph5wq9a.Icinga2StreamStatusRow) {
      return _iph5wq9a.Icinga2StreamStatusRow.fromJson(data) as T;
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
    if (t == _ib6287mr.IngestSourceCredential) {
      return _ib6287mr.IngestSourceCredential.fromJson(data) as T;
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
    if (t == _ii70ink4.ObservationKeyRow) {
      return _ii70ink4.ObservationKeyRow.fromJson(data) as T;
    }
    if (t == _ir1rifdz.PipelineFailure) {
      return _ir1rifdz.PipelineFailure.fromJson(data) as T;
    }
    if (t == _iqfe2rop.PluginDefinitionHealth) {
      return _iqfe2rop.PluginDefinitionHealth.fromJson(data) as T;
    }
    if (t == _i5barlkw.PluginInstanceStatus) {
      return _i5barlkw.PluginInstanceStatus.fromJson(data) as T;
    }
    if (t == _i1399vez.QueueFailure) {
      return _i1399vez.QueueFailure.fromJson(data) as T;
    }
    if (t == _i3paal6y.QueueFailureFilter) {
      return _i3paal6y.QueueFailureFilter.fromJson(data) as T;
    }
    if (t == _ijk6hojr.QueueFailureKind) {
      return _ijk6hojr.QueueFailureKind.fromJson(data) as T;
    }
    if (t == _io00fnfh.QueueFailurePage) {
      return _io00fnfh.QueueFailurePage.fromJson(data) as T;
    }
    if (t == _ip4smbu4.QueueMaintenanceStatus) {
      return _ip4smbu4.QueueMaintenanceStatus.fromJson(data) as T;
    }
    if (t == _i9vx28ve.QueueOperatorException) {
      return _i9vx28ve.QueueOperatorException.fromJson(data) as T;
    }
    if (t == _ie72o327.QueueOutputStatus) {
      return _ie72o327.QueueOutputStatus.fromJson(data) as T;
    }
    if (t == _i738ir7t.QueueReplayItem) {
      return _i738ir7t.QueueReplayItem.fromJson(data) as T;
    }
    if (t == _ikvpqw3q.QueueReplayResult) {
      return _ikvpqw3q.QueueReplayResult.fromJson(data) as T;
    }
    if (t == _iylzdl71.QueueStatus) {
      return _iylzdl71.QueueStatus.fromJson(data) as T;
    }
    if (t == _ibz1p89x.SecretRecord) {
      return _ibz1p89x.SecretRecord.fromJson(data) as T;
    }
    if (t == _ix76ovok.TransportKey) {
      return _ix76ovok.TransportKey.fromJson(data) as T;
    }
    if (t == _is.getType<_iqmz6gj4.AlertRow?>()) {
      return (data != null ? _iqmz6gj4.AlertRow.fromJson(data) : null) as T;
    }
    if (t == _is.getType<_iz3t21fy.AlertSnapshot?>()) {
      return (data != null ? _iz3t21fy.AlertSnapshot.fromJson(data) : null)
          as T;
    }
    if (t == _is.getType<_i897ft9c.AlertView?>()) {
      return (data != null ? _i897ft9c.AlertView.fromJson(data) : null) as T;
    }
    if (t == _is.getType<_i25sduw2.ConsoleAccessDeniedException?>()) {
      return (data != null
              ? _i25sduw2.ConsoleAccessDeniedException.fromJson(data)
              : null)
          as T;
    }
    if (t == _is.getType<_ihd6gt0n.DeliveryAttempt?>()) {
      return (data != null ? _ihd6gt0n.DeliveryAttempt.fromJson(data) : null)
          as T;
    }
    if (t == _is.getType<_iywqxrq6.FeedEntry?>()) {
      return (data != null ? _iywqxrq6.FeedEntry.fromJson(data) : null) as T;
    }
    if (t == _is.getType<_ijrqdfur.FeedPage?>()) {
      return (data != null ? _ijrqdfur.FeedPage.fromJson(data) : null) as T;
    }
    if (t == _is.getType<_ivrec9rl.FeedWakeUp?>()) {
      return (data != null ? _ivrec9rl.FeedWakeUp.fromJson(data) : null) as T;
    }
    if (t == _is.getType<_iyvfq7h8.Icinga2AdmittedBatch?>()) {
      return (data != null
              ? _iyvfq7h8.Icinga2AdmittedBatch.fromJson(data)
              : null)
          as T;
    }
    if (t == _is.getType<_i0zg1hdn.Icinga2ConsumerStatus?>()) {
      return (data != null
              ? _i0zg1hdn.Icinga2ConsumerStatus.fromJson(data)
              : null)
          as T;
    }
    if (t == _is.getType<_id40rhfu.Icinga2ConsumerSync?>()) {
      return (data != null
              ? _id40rhfu.Icinga2ConsumerSync.fromJson(data)
              : null)
          as T;
    }
    if (t == _is.getType<_iwydjvnk.Icinga2StreamLeaseRow?>()) {
      return (data != null
              ? _iwydjvnk.Icinga2StreamLeaseRow.fromJson(data)
              : null)
          as T;
    }
    if (t == _is.getType<_i6orwhmp.Icinga2StreamResyncRow?>()) {
      return (data != null
              ? _i6orwhmp.Icinga2StreamResyncRow.fromJson(data)
              : null)
          as T;
    }
    if (t == _is.getType<_iph5wq9a.Icinga2StreamStatusRow?>()) {
      return (data != null
              ? _iph5wq9a.Icinga2StreamStatusRow.fromJson(data)
              : null)
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
    if (t == _is.getType<_ib6287mr.IngestSourceCredential?>()) {
      return (data != null
              ? _ib6287mr.IngestSourceCredential.fromJson(data)
              : null)
          as T;
    }
    if (t == _is.getType<_iil3cq3h.InvalidCursorException?>()) {
      return (data != null
              ? _iil3cq3h.InvalidCursorException.fromJson(data)
              : null)
          as T;
    }
    if (t == _is.getType<_ibaui0zg.MappingPreviewDiagnostic?>()) {
      return (data != null
              ? _ibaui0zg.MappingPreviewDiagnostic.fromJson(data)
              : null)
          as T;
    }
    if (t == _is.getType<_i20s3xik.MappingPreviewEvent?>()) {
      return (data != null
              ? _i20s3xik.MappingPreviewEvent.fromJson(data)
              : null)
          as T;
    }
    if (t == _is.getType<_ines6tzx.MappingPreviewResult?>()) {
      return (data != null
              ? _ines6tzx.MappingPreviewResult.fromJson(data)
              : null)
          as T;
    }
    if (t == _is.getType<_i2ozkwub.MappingPreviewValidationError?>()) {
      return (data != null
              ? _i2ozkwub.MappingPreviewValidationError.fromJson(data)
              : null)
          as T;
    }
    if (t == _is.getType<_ik186lp1.MatcherFailureView?>()) {
      return (data != null ? _ik186lp1.MatcherFailureView.fromJson(data) : null)
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
    if (t == _is.getType<_iqfe2rop.PluginDefinitionHealth?>()) {
      return (data != null
              ? _iqfe2rop.PluginDefinitionHealth.fromJson(data)
              : null)
          as T;
    }
    if (t == _is.getType<_i5barlkw.PluginInstanceStatus?>()) {
      return (data != null
              ? _i5barlkw.PluginInstanceStatus.fromJson(data)
              : null)
          as T;
    }
    if (t == _is.getType<_i1399vez.QueueFailure?>()) {
      return (data != null ? _i1399vez.QueueFailure.fromJson(data) : null) as T;
    }
    if (t == _is.getType<_i3paal6y.QueueFailureFilter?>()) {
      return (data != null ? _i3paal6y.QueueFailureFilter.fromJson(data) : null)
          as T;
    }
    if (t == _is.getType<_ijk6hojr.QueueFailureKind?>()) {
      return (data != null ? _ijk6hojr.QueueFailureKind.fromJson(data) : null)
          as T;
    }
    if (t == _is.getType<_io00fnfh.QueueFailurePage?>()) {
      return (data != null ? _io00fnfh.QueueFailurePage.fromJson(data) : null)
          as T;
    }
    if (t == _is.getType<_ip4smbu4.QueueMaintenanceStatus?>()) {
      return (data != null
              ? _ip4smbu4.QueueMaintenanceStatus.fromJson(data)
              : null)
          as T;
    }
    if (t == _is.getType<_i9vx28ve.QueueOperatorException?>()) {
      return (data != null
              ? _i9vx28ve.QueueOperatorException.fromJson(data)
              : null)
          as T;
    }
    if (t == _is.getType<_ie72o327.QueueOutputStatus?>()) {
      return (data != null ? _ie72o327.QueueOutputStatus.fromJson(data) : null)
          as T;
    }
    if (t == _is.getType<_i738ir7t.QueueReplayItem?>()) {
      return (data != null ? _i738ir7t.QueueReplayItem.fromJson(data) : null)
          as T;
    }
    if (t == _is.getType<_ikvpqw3q.QueueReplayResult?>()) {
      return (data != null ? _ikvpqw3q.QueueReplayResult.fromJson(data) : null)
          as T;
    }
    if (t == _is.getType<_iylzdl71.QueueStatus?>()) {
      return (data != null ? _iylzdl71.QueueStatus.fromJson(data) : null) as T;
    }
    if (t == _is.getType<_ibz1p89x.SecretRecord?>()) {
      return (data != null ? _ibz1p89x.SecretRecord.fromJson(data) : null) as T;
    }
    if (t == _is.getType<_ix76ovok.TransportKey?>()) {
      return (data != null ? _ix76ovok.TransportKey.fromJson(data) : null) as T;
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
    if (t == List<_i1399vez.QueueFailure>) {
      return (data as List)
              .map((e) => deserialize<_i1399vez.QueueFailure>(e))
              .toList()
          as T;
    }
    if (t == List<_i738ir7t.QueueReplayItem>) {
      return (data as List)
              .map((e) => deserialize<_i738ir7t.QueueReplayItem>(e))
              .toList()
          as T;
    }
    if (t == List<_ie72o327.QueueOutputStatus>) {
      return (data as List)
              .map((e) => deserialize<_ie72o327.QueueOutputStatus>(e))
              .toList()
          as T;
    }
    if (t == List<_ip4smbu4.QueueMaintenanceStatus>) {
      return (data as List)
              .map((e) => deserialize<_ip4smbu4.QueueMaintenanceStatus>(e))
              .toList()
          as T;
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
      _iqmz6gj4.AlertRow => 'AlertRow',
      _iz3t21fy.AlertSnapshot => 'AlertSnapshot',
      _i897ft9c.AlertView => 'AlertView',
      _i25sduw2.ConsoleAccessDeniedException => 'ConsoleAccessDeniedException',
      _ihd6gt0n.DeliveryAttempt => 'DeliveryAttempt',
      _iywqxrq6.FeedEntry => 'FeedEntry',
      _ijrqdfur.FeedPage => 'FeedPage',
      _ivrec9rl.FeedWakeUp => 'FeedWakeUp',
      _iyvfq7h8.Icinga2AdmittedBatch => 'Icinga2AdmittedBatch',
      _i0zg1hdn.Icinga2ConsumerStatus => 'Icinga2ConsumerStatus',
      _id40rhfu.Icinga2ConsumerSync => 'Icinga2ConsumerSync',
      _iwydjvnk.Icinga2StreamLeaseRow => 'Icinga2StreamLeaseRow',
      _i6orwhmp.Icinga2StreamResyncRow => 'Icinga2StreamResyncRow',
      _iph5wq9a.Icinga2StreamStatusRow => 'Icinga2StreamStatusRow',
      _ibsgqcqa.IngestActiveConfig => 'IngestActiveConfig',
      _iwupdujg.IngestConfigSnapshot => 'IngestConfigSnapshot',
      _iupiayjd.IngestSecretCommitment => 'IngestSecretCommitment',
      _inhmna33.IngestSourceRow => 'IngestSourceRow',
      _ib6287mr.IngestSourceCredential => 'IngestSourceCredential',
      _iil3cq3h.InvalidCursorException => 'InvalidCursorException',
      _ibaui0zg.MappingPreviewDiagnostic => 'MappingPreviewDiagnostic',
      _i20s3xik.MappingPreviewEvent => 'MappingPreviewEvent',
      _ines6tzx.MappingPreviewResult => 'MappingPreviewResult',
      _i2ozkwub.MappingPreviewValidationError =>
        'MappingPreviewValidationError',
      _ik186lp1.MatcherFailureView => 'MatcherFailureView',
      _ii70ink4.ObservationKeyRow => 'ObservationKeyRow',
      _ir1rifdz.PipelineFailure => 'PipelineFailure',
      _iqfe2rop.PluginDefinitionHealth => 'PluginDefinitionHealth',
      _i5barlkw.PluginInstanceStatus => 'PluginInstanceStatus',
      _i1399vez.QueueFailure => 'QueueFailure',
      _i3paal6y.QueueFailureFilter => 'QueueFailureFilter',
      _ijk6hojr.QueueFailureKind => 'QueueFailureKind',
      _io00fnfh.QueueFailurePage => 'QueueFailurePage',
      _ip4smbu4.QueueMaintenanceStatus => 'QueueMaintenanceStatus',
      _i9vx28ve.QueueOperatorException => 'QueueOperatorException',
      _ie72o327.QueueOutputStatus => 'QueueOutputStatus',
      _i738ir7t.QueueReplayItem => 'QueueReplayItem',
      _ikvpqw3q.QueueReplayResult => 'QueueReplayResult',
      _iylzdl71.QueueStatus => 'QueueStatus',
      _ibz1p89x.SecretRecord => 'SecretRecord',
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
      case _iqmz6gj4.AlertRow():
        return 'AlertRow';
      case _iz3t21fy.AlertSnapshot():
        return 'AlertSnapshot';
      case _i897ft9c.AlertView():
        return 'AlertView';
      case _i25sduw2.ConsoleAccessDeniedException():
        return 'ConsoleAccessDeniedException';
      case _ihd6gt0n.DeliveryAttempt():
        return 'DeliveryAttempt';
      case _iywqxrq6.FeedEntry():
        return 'FeedEntry';
      case _ijrqdfur.FeedPage():
        return 'FeedPage';
      case _ivrec9rl.FeedWakeUp():
        return 'FeedWakeUp';
      case _iyvfq7h8.Icinga2AdmittedBatch():
        return 'Icinga2AdmittedBatch';
      case _i0zg1hdn.Icinga2ConsumerStatus():
        return 'Icinga2ConsumerStatus';
      case _id40rhfu.Icinga2ConsumerSync():
        return 'Icinga2ConsumerSync';
      case _iwydjvnk.Icinga2StreamLeaseRow():
        return 'Icinga2StreamLeaseRow';
      case _i6orwhmp.Icinga2StreamResyncRow():
        return 'Icinga2StreamResyncRow';
      case _iph5wq9a.Icinga2StreamStatusRow():
        return 'Icinga2StreamStatusRow';
      case _ibsgqcqa.IngestActiveConfig():
        return 'IngestActiveConfig';
      case _iwupdujg.IngestConfigSnapshot():
        return 'IngestConfigSnapshot';
      case _iupiayjd.IngestSecretCommitment():
        return 'IngestSecretCommitment';
      case _inhmna33.IngestSourceRow():
        return 'IngestSourceRow';
      case _ib6287mr.IngestSourceCredential():
        return 'IngestSourceCredential';
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
      case _ii70ink4.ObservationKeyRow():
        return 'ObservationKeyRow';
      case _ir1rifdz.PipelineFailure():
        return 'PipelineFailure';
      case _iqfe2rop.PluginDefinitionHealth():
        return 'PluginDefinitionHealth';
      case _i5barlkw.PluginInstanceStatus():
        return 'PluginInstanceStatus';
      case _i1399vez.QueueFailure():
        return 'QueueFailure';
      case _i3paal6y.QueueFailureFilter():
        return 'QueueFailureFilter';
      case _ijk6hojr.QueueFailureKind():
        return 'QueueFailureKind';
      case _io00fnfh.QueueFailurePage():
        return 'QueueFailurePage';
      case _ip4smbu4.QueueMaintenanceStatus():
        return 'QueueMaintenanceStatus';
      case _i9vx28ve.QueueOperatorException():
        return 'QueueOperatorException';
      case _ie72o327.QueueOutputStatus():
        return 'QueueOutputStatus';
      case _i738ir7t.QueueReplayItem():
        return 'QueueReplayItem';
      case _ikvpqw3q.QueueReplayResult():
        return 'QueueReplayResult';
      case _iylzdl71.QueueStatus():
        return 'QueueStatus';
      case _ibz1p89x.SecretRecord():
        return 'SecretRecord';
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
    if (dataClassName == 'AlertRow') {
      return deserialize<_iqmz6gj4.AlertRow>(data['data']);
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
    if (dataClassName == 'DeliveryAttempt') {
      return deserialize<_ihd6gt0n.DeliveryAttempt>(data['data']);
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
    if (dataClassName == 'Icinga2AdmittedBatch') {
      return deserialize<_iyvfq7h8.Icinga2AdmittedBatch>(data['data']);
    }
    if (dataClassName == 'Icinga2ConsumerStatus') {
      return deserialize<_i0zg1hdn.Icinga2ConsumerStatus>(data['data']);
    }
    if (dataClassName == 'Icinga2ConsumerSync') {
      return deserialize<_id40rhfu.Icinga2ConsumerSync>(data['data']);
    }
    if (dataClassName == 'Icinga2StreamLeaseRow') {
      return deserialize<_iwydjvnk.Icinga2StreamLeaseRow>(data['data']);
    }
    if (dataClassName == 'Icinga2StreamResyncRow') {
      return deserialize<_i6orwhmp.Icinga2StreamResyncRow>(data['data']);
    }
    if (dataClassName == 'Icinga2StreamStatusRow') {
      return deserialize<_iph5wq9a.Icinga2StreamStatusRow>(data['data']);
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
    if (dataClassName == 'IngestSourceCredential') {
      return deserialize<_ib6287mr.IngestSourceCredential>(data['data']);
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
    if (dataClassName == 'ObservationKeyRow') {
      return deserialize<_ii70ink4.ObservationKeyRow>(data['data']);
    }
    if (dataClassName == 'PipelineFailure') {
      return deserialize<_ir1rifdz.PipelineFailure>(data['data']);
    }
    if (dataClassName == 'PluginDefinitionHealth') {
      return deserialize<_iqfe2rop.PluginDefinitionHealth>(data['data']);
    }
    if (dataClassName == 'PluginInstanceStatus') {
      return deserialize<_i5barlkw.PluginInstanceStatus>(data['data']);
    }
    if (dataClassName == 'QueueFailure') {
      return deserialize<_i1399vez.QueueFailure>(data['data']);
    }
    if (dataClassName == 'QueueFailureFilter') {
      return deserialize<_i3paal6y.QueueFailureFilter>(data['data']);
    }
    if (dataClassName == 'QueueFailureKind') {
      return deserialize<_ijk6hojr.QueueFailureKind>(data['data']);
    }
    if (dataClassName == 'QueueFailurePage') {
      return deserialize<_io00fnfh.QueueFailurePage>(data['data']);
    }
    if (dataClassName == 'QueueMaintenanceStatus') {
      return deserialize<_ip4smbu4.QueueMaintenanceStatus>(data['data']);
    }
    if (dataClassName == 'QueueOperatorException') {
      return deserialize<_i9vx28ve.QueueOperatorException>(data['data']);
    }
    if (dataClassName == 'QueueOutputStatus') {
      return deserialize<_ie72o327.QueueOutputStatus>(data['data']);
    }
    if (dataClassName == 'QueueReplayItem') {
      return deserialize<_i738ir7t.QueueReplayItem>(data['data']);
    }
    if (dataClassName == 'QueueReplayResult') {
      return deserialize<_ikvpqw3q.QueueReplayResult>(data['data']);
    }
    if (dataClassName == 'QueueStatus') {
      return deserialize<_iylzdl71.QueueStatus>(data['data']);
    }
    if (dataClassName == 'SecretRecord') {
      return deserialize<_ibz1p89x.SecretRecord>(data['data']);
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
      case _iqmz6gj4.AlertRow:
        return _iqmz6gj4.AlertRow.t;
      case _ihd6gt0n.DeliveryAttempt:
        return _ihd6gt0n.DeliveryAttempt.t;
      case _iyvfq7h8.Icinga2AdmittedBatch:
        return _iyvfq7h8.Icinga2AdmittedBatch.t;
      case _iwydjvnk.Icinga2StreamLeaseRow:
        return _iwydjvnk.Icinga2StreamLeaseRow.t;
      case _i6orwhmp.Icinga2StreamResyncRow:
        return _i6orwhmp.Icinga2StreamResyncRow.t;
      case _iph5wq9a.Icinga2StreamStatusRow:
        return _iph5wq9a.Icinga2StreamStatusRow.t;
      case _ibsgqcqa.IngestActiveConfig:
        return _ibsgqcqa.IngestActiveConfig.t;
      case _iwupdujg.IngestConfigSnapshot:
        return _iwupdujg.IngestConfigSnapshot.t;
      case _iupiayjd.IngestSecretCommitment:
        return _iupiayjd.IngestSecretCommitment.t;
      case _inhmna33.IngestSourceRow:
        return _inhmna33.IngestSourceRow.t;
      case _ib6287mr.IngestSourceCredential:
        return _ib6287mr.IngestSourceCredential.t;
      case _ii70ink4.ObservationKeyRow:
        return _ii70ink4.ObservationKeyRow.t;
      case _ir1rifdz.PipelineFailure:
        return _ir1rifdz.PipelineFailure.t;
      case _iqfe2rop.PluginDefinitionHealth:
        return _iqfe2rop.PluginDefinitionHealth.t;
      case _i5barlkw.PluginInstanceStatus:
        return _i5barlkw.PluginInstanceStatus.t;
      case _ibz1p89x.SecretRecord:
        return _ibz1p89x.SecretRecord.t;
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
